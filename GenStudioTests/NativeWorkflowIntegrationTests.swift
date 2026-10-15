import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

private actor FixtureImageEngine: ImageGenerationEngine {
    let result: URL
    private(set) var calls = 0
    private var seeds: [Int] = []
    private var requests: [ImageGenerationRequest] = []
    init(_ result: URL) { self.result = result }
    func generate(_ request: ImageGenerationRequest) async throws -> URL {
        calls += 1
        seeds.append(Int(request.seed))
        requests.append(request)
        return result
    }
    func count() -> Int { calls }
    func capturedSeeds() -> [Int] { seeds }
    func capturedRequests() -> [ImageGenerationRequest] { requests }
}

final class NativeWorkflowIntegrationTests: XCTestCase {
    /// Opt-in visual proof, using an already installed local model and a caller-supplied image.
    /// TEST_RUNNER_RUN_CHARACTER_SHEET_PROOF=1, TEST_RUNNER_CHARACTER_SHEET_REFERENCE=<path>,
    /// TEST_RUNNER_CHARACTER_SHEET_EVIDENCE_DIR=<new directory under .build>.
    func testRealCharacterSheetReferenceProof() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_CHARACTER_SHEET_PROOF"] == "1",
              let source = environment["CHARACTER_SHEET_REFERENCE"],
              let evidence = environment["CHARACTER_SHEET_EVIDENCE_DIR"] else {
            throw XCTSkip("Opt in with a local subject picture and an evidence directory to inspect actual sheet quality.")
        }
        let libraryRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "GenStudio/ModelLibrary")
        let library = ModelLibrary(root: libraryRoot)
        let installed = try await library.installedModels()
        let recipeID = MediaModelCatalog.klein9BRecipeID
        guard installed.contains(where: { $0.id == recipeID && $0.available }) else {
            throw XCTSkip("The local Klein 9B package is required. No download attempted.")
        }
        let root = URL(fileURLWithPath: evidence)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var sheet = StudioNode(kind: .characterSheet, label: "People Sheet", position: .init(x: 0, y: 0))
        sheet.characterSheetPose = CharacterSheetPose(rawValue: environment["CHARACTER_SHEET_POSE"] ?? "original") ?? .original
        let picture = StudioNode(kind: .imageInput, label: "Subject", position: .init(x: 0, y: 1), imagePath: source)
        let size = sheet.characterSheetSubject.recommendedCanvas
        let generator = StudioNode(kind: .imageGenerator, label: "Sheet Render", position: .init(x: 1, y: 0), model: recipeID, width: size.width, height: size.height, imageSeed: 424242)
        let graph = WorkflowProject(name: "Character Sheet visual proof", nodes: [sheet, picture, generator], edges: [
            edge(sheet, "text", generator, "prompt", .text), edge(picture, "image", generator, "referenceImage", .image)
        ])
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root),
                                              imageEngine: NativeImageEngine(library: library, outputRoot: root.appending(path: "scratch")))
            .execute(project: graph, targetID: generator.id, installedModels: Set(installed.map(\.id)), installedGenerationModels: installed)
        guard case .image(let output)? = result.values[.init(nodeID: generator.id, portID: "image")] else {
            return XCTFail("The real adapter did not produce an image")
        }
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, size.width)
        XCTAssertEqual(image.height, size.height)
        try Data(contentsOf: output).write(to: root.appending(path: "sheet.png"), options: .atomic)
        XCTAssertEqual(result.run?.snapshot.imageRequest?.compiledPrompt, sheet.characterSheetBrief)
        // Decoding validates the route. Identity/layout quality requires human visual review.
    }

    func testCharacterSheetReachesImageGeneratorUnchangedThroughARouterWithOriginalPixels() async throws {
        let root = try VideoFixtures.root("sheet-execution")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = try VideoFixtures.solidPNG((110, 50, 180), width: 64, height: 96, in: root, name: "subject")
        let output = try VideoFixtures.solidPNG((80, 120, 100), width: 816, height: 1024, in: root, name: "result")
        var sheet = StudioNode(kind: .characterSheet, label: "Sheet", position: .init(x: 0, y: 0))
        sheet.characterSheetHeightCM = 179
        sheet.prompt = "stale text must not be emitted"
        let router = StudioNode(kind: .textRouter, label: "Route", position: .init(x: 1, y: 0))
        let picture = StudioNode(kind: .imageInput, label: "Identity", position: .init(x: 0, y: 1), imagePath: reference.path)
        let generator = StudioNode(kind: .imageGenerator, label: "Generate", position: .init(x: 2, y: 0), model: MediaModelCatalog.kleinRecipeID, width: 816, height: 1024)
        let graph = WorkflowProject(name: "Sheet", nodes: [sheet, router, picture, generator], edges: [
            edge(sheet, "text", router, "text", .text), edge(router, "b", generator, "prompt", .text),
            edge(picture, "image", generator, "referenceImage", .image)
        ])
        let textEngine = StubEngine(result: "An unwanted LLM rewrite")
        let imageEngine = FixtureImageEngine(output)
        _ = try await ExecutionQueue(engine: textEngine, persistence: StudioPersistence(root: root), imageEngine: imageEngine)
            .execute(project: graph, targetID: generator.id, installedModels: [generator.model, PromptCompilerRegistry.defaultCompilerModelID])
        let calls = await textEngine.capturedPrompts()
        XCTAssertTrue(calls.isEmpty, "A model-ready sheet must never enter semantic expansion")
        let requests = await imageEngine.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.prompt, sheet.characterSheetBrief)
        XCTAssertEqual(request.authoredPrompt, sheet.characterSheetBrief)
        XCTAssertNil(request.promptCompilerModelID)
        let retainedReference = try XCTUnwrap(request.referenceImages.first)
        XCTAssertEqual(try Data(contentsOf: retainedReference), try Data(contentsOf: reference))
        XCTAssertEqual(graph.characterSheetSource(feeding: generator.id)?.id, sheet.id)
    }

    private func edge(_ source: StudioNode, _ output: String, _ target: StudioNode, _ input: String, _ type: PortDataType) -> StudioEdge {
        .init(sourceID: source.id, sourcePortID: output, targetID: target.id, targetPortID: input, type: type)
    }

    func testSheetSourceLookupFollowsPreviewButStopsAtExplicitTextTransformations() {
        let sheet = StudioNode(kind: .characterSheet, label: "Sheet", position: .init(x: 0, y: 0))
        let preview = StudioNode(kind: .textPreview, label: "Preview", position: .init(x: 1, y: 0))
        let generator = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 2, y: 0))
        var graph = WorkflowProject(name: "Sheet source", nodes: [sheet, preview, generator], edges: [
            edge(sheet, "text", preview, "text", .text), edge(preview, "text", generator, "prompt", .text)
        ])
        XCTAssertEqual(graph.characterSheetSource(feeding: generator.id)?.id, sheet.id)
        graph.nodes[1].kind = .promptEnhancer
        XCTAssertNil(graph.characterSheetSource(feeding: generator.id), "An explicitly transformed prompt is no longer the fixed sheet brief")
        graph.nodes[1].kind = .textRouter
        graph.edges[0] = edge(preview, "a", preview, "text", .text)
        XCTAssertNil(graph.characterSheetSource(feeding: generator.id), "Malformed cycles must terminate even before graph validation")
    }

    func testInstalledUserCheckpointAutomaticallySuppliesAdapterAndPromptContract() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "fixture.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let recipe = try UserModelCatalog.recipe(from: .init(
            name: "Imported checkpoint", provider: "test", modelVersionID: nil,
            downloadURL: URL(string: "https://example.com/model.safetensors")!, filename: "model.safetensors",
            sha256: String(repeating: "b", count: 64), byteSize: 1_000_000, license: "test", baseModel: nil,
            runtimeProfile: .stableDiffusionCheckpoint, tasks: [.textToImage]
        ))
        let installed = InstalledGenerationModel(
            id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
            components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: root.appending(path: $0.filename), source: $0) },
            installedAt: Date(), inferenceVerified: false, available: true, recipeSnapshot: recipe,
            verifiedImageTasks: []
        )
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "a paper boat")
        var generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 1, y: 0), model: recipe.id)
        generator.experimentalImageRecipeID = recipe.id
        let project = WorkflowProject(name: "Imported image model", nodes: [prompt, generator], edges: [
            edge(prompt, "text", generator, "prompt", .text)
        ])
        let engine = FixtureImageEngine(image)

        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), imageEngine: engine)
            .execute(project: project, targetID: generator.id, installedModels: [recipe.id], installedGenerationModels: [installed])

        XCTAssertNotNil(result.values[.init(nodeID: generator.id, portID: "image")])
        let requests = await engine.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.prompt, "a paper boat")
        XCTAssertEqual(request.compiledPrompt, "a paper boat")
        XCTAssertEqual(request.promptCompilerVersion, PromptCompilerRegistry.version)
        XCTAssertEqual(result.run?.snapshot.modelRecipe?.id, recipe.id)
        XCTAssertEqual(result.run?.snapshot.promptCompilerDialect, .plainText)
    }

    func testImageEngineResultFlowsToPreviewAndPersistsRecipeAndParameters() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "fixture.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "An apple")
        let generator = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 1, y: 0), model: "sd15-q4", imageSeed: 123)
        let preview = StudioNode(kind: .imagePreview, label: "V", position: .init(x: 2, y: 0))
        let project = WorkflowProject(name: "Native image", nodes: [prompt, generator, preview], edges: [edge(prompt, "text", generator, "prompt", .text), edge(generator, "image", preview, "image", .image)])
        let store = StudioPersistence(root: root)
        let engine = FixtureImageEngine(image)
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store, imageEngine: engine).execute(project: project, targetID: preview.id, installedModels: ["sd15-q4"])
        let calls = await engine.count(); XCTAssertEqual(calls, 1)
        guard case .image(let retained)? = result.values[.init(nodeID: preview.id, portID: "image")] else { return XCTFail("Expected downstream image") }
        XCTAssertNotEqual(retained, image)
        let runs = try await store.loadRuns()
        XCTAssertEqual(runs.first?.status, .succeeded)
        XCTAssertEqual(runs.first?.snapshot.imageSeed, 123)
        XCTAssertEqual(runs.first?.snapshot.imageSteps, 20)
        XCTAssertEqual(runs.first?.snapshot.modelRecipe?.id, "sd15-q4")
        XCTAssertEqual(runs.first?.snapshot.authoredPrompt, "An apple")
        XCTAssertEqual(runs.first?.snapshot.compiledPrompt, "An apple")
        XCTAssertEqual(runs.first?.snapshot.promptCompilerRecipeID, "sd15-q4")
        XCTAssertEqual(runs.first?.snapshot.promptCompilerDialect, .plainText)
        XCTAssertEqual(runs.first?.snapshot.promptCompilerUsedFallback, false)
        XCTAssertEqual(runs.first?.snapshot.imageRequest?.authoredPrompt, "An apple")
        let reopened = try await StudioPersistence(root: root).loadExecutionArtifacts()
        XCTAssertEqual(reopened.first?.values[.init(nodeID: preview.id, portID: "image")], .image(retained))

        // A downstream preview consumes the existing take without sampling again.
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, imageEngine: engine)
        let chosen = try XCTUnwrap(reopened.first)
        _ = try await queue.execute(project: project, targetID: preview.id, installedModels: ["sd15-q4"], selectedTakes: [generator.id: chosen])
        let afterPreview = await engine.count()
        XCTAssertEqual(afterPreview, 1)
        // Clicking play on that same generator always performs another generation.
        _ = try await queue.execute(project: project, targetID: generator.id, installedModels: ["sd15-q4"], selectedTakes: [generator.id: chosen])
        let afterRerender = await engine.count()
        XCTAssertEqual(afterRerender, 2)
        let lockedSeeds = await engine.capturedSeeds()
        XCTAssertEqual(lockedSeeds, [123, 123])
        var variations = project
        let generatorIndex = try XCTUnwrap(variations.nodes.firstIndex { $0.id == generator.id })
        variations.nodes[generatorIndex].seedLocked = false
        _ = try await queue.execute(project: variations, targetID: generator.id, installedModels: ["sd15-q4"])
        _ = try await queue.execute(project: variations, targetID: generator.id, installedModels: ["sd15-q4"])
        let allSeeds = await engine.capturedSeeds()
        XCTAssertNotEqual(allSeeds[2], allSeeds[3], "Repeated play on an unlocked node generates a fresh seed")
        XCTAssertFalse(variations.nodes[generatorIndex].seedLocked)
        let variationRuns = try await store.loadRuns()
        XCTAssertEqual(Set(variationRuns.compactMap { $0.snapshot.imageSeed }), Set(allSeeds))
    }

    func testRunningDownstreamNodeUsesDisplayedUpstreamOutputWithoutRegeneratingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "Do not rerun")
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 1, y: 0), model: "sd15-q4")
        let preview = StudioNode(kind: .imagePreview, label: "Downstream", position: .init(x: 2, y: 0))
        let project = WorkflowProject(name: "Pinned upstream", nodes: [prompt, generator, preview], edges: [
            edge(prompt, "text", generator, "prompt", .text), edge(generator, "image", preview, "image", .image)
        ])
        let engine = FixtureImageEngine(source)
        let existing = PortAddress(nodeID: generator.id, portID: "image")
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), imageEngine: engine)
            .execute(project: project, targetID: preview.id, installedModels: ["sd15-q4"], upstreamValues: [existing: .image(source)])

        let generationCount = await engine.count()
        XCTAssertEqual(generationCount, 0, "Running a downstream node must not invoke its upstream model")
        XCTAssertEqual(result.values[.init(nodeID: preview.id, portID: "image")], .image(source))
        let artifacts = try await StudioPersistence(root: root).loadExecutionArtifacts()
        let artifact = try XCTUnwrap(artifacts.first)
        XCTAssertFalse(artifact.generatedNodeIDs?.contains(generator.id) == true, "Reusing an image must not create a fake generator take")
    }

    func testDisplayedGeneratorCutsOffItsUnavailableAncestorsForDownstreamRun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let staleVision = StudioNode(kind: .imageDescriber, label: "Old Image Description", position: .init(x: 0, y: 0), model: "vision-smolvlm-500m-q8")
        let generator = StudioNode(kind: .imageGenerator, label: "Rendered Image", position: .init(x: 1, y: 0), model: "sd15-q4")
        let preview = StudioNode(kind: .imagePreview, label: "Downstream", position: .init(x: 2, y: 0))
        let project = WorkflowProject(name: "Pinned boundary", nodes: [staleVision, generator, preview], edges: [
            edge(staleVision, "text", generator, "prompt", .text),
            edge(generator, "image", preview, "image", .image)
        ])
        let rendered = PortAddress(nodeID: generator.id, portID: "image")

        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), imageEngine: FixtureImageEngine(source))
            .execute(project: project, targetID: preview.id, installedModels: ["sd15-q4"], installedGenerationModels: [], upstreamValues: [rendered: .image(source)])

        XCTAssertEqual(result.values[.init(nodeID: preview.id, portID: "image")], .image(source))
    }

    func testRerunningImageGeneratorUsesEditedPromptInsteadOfDisplayedOldPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "A completely new scene")
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 1, y: 0), model: "sd15-q4")
        let project = WorkflowProject(name: "Edited prompt", nodes: [prompt, generator], edges: [
            edge(prompt, "text", generator, "prompt", .text)
        ])
        let engine = FixtureImageEngine(source)
        let stalePrompt = PortAddress(nodeID: prompt.id, portID: "text")

        _ = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), imageEngine: engine)
            .execute(project: project, targetID: generator.id, installedModels: ["sd15-q4"], upstreamValues: [stalePrompt: .text("The old prompt")])

        let requests = await engine.capturedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.authoredPrompt, "A completely new scene")
        XCTAssertEqual(request.prompt, "A completely new scene")
    }

    func testUnsupportedReferenceRejectedBeforeUpstreamTextGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "refine")
        let text = StudioNode(kind: .textModel, label: "T", position: .init(x: 1, y: 0), model: "stub")
        let imported = StudioNode(kind: .imageInput, label: "I", position: .init(x: 0, y: 1), imagePath: #filePath)
        let image = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 2, y: 0), model: "sd15-q4")
        let project = WorkflowProject(name: "Reference", nodes: [prompt, text, imported, image], edges: [edge(prompt, "text", text, "prompt", .text), edge(text, "text", image, "prompt", .text), edge(imported, "image", image, "referenceImage", .image)])
        let textEngine = StubEngine()
        // A registry with only the text-to-image adapter: the connected Reference names the missing contract.
        do {
            _ = try await ExecutionQueue(engine: textEngine, persistence: StudioPersistence(root: root), imageCapabilities: [ImageCapabilityRegistry.sd15TextToImage]).execute(project: project, targetID: image.id, installedModels: ["stub", "sd15-q4"])
            XCTFail("Unsupported reference must reject")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Reference"), error.localizedDescription) }
        // An image-to-image adapter that is withdrawn is still not runnable, and says why.
        do {
            _ = try await ExecutionQueue(engine: textEngine, persistence: StudioPersistence(root: root), imageCapabilities: [ImageCapabilityRegistry.sd15TextToImage, ImageCapabilityRegistry.sd15ImageToImage.with(readiness: .unavailable(reason: "This route was withdrawn."))]).execute(project: project, targetID: image.id, installedModels: ["stub", "sd15-q4"])
            XCTFail("Withdrawn image-to-image must reject")
        } catch { XCTAssertTrue(error.localizedDescription.contains("withdrawn"), error.localizedDescription) }
        let prompts = await textEngine.capturedPrompts(); XCTAssertTrue(prompts.isEmpty)
        XCTAssertEqual(project.edges.count, 3)
    }
}
