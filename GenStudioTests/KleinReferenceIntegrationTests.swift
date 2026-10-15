import CoreGraphics
import ImageIO
import XCTest
@testable import GenStudio

/// Real inference, explicitly opted in. Uses existing local FLUX.2 Klein component files only; never downloads.
/// Exercises the three-ordered-reference editing path the shipped `kleinReference` capability describes but
/// (before this proof) had never rendered through GenStudio on this Mac.
/// Run: TEST_RUNNER_RUN_KLEIN_REFERENCE_INTEGRATION=1 TEST_RUNNER_KLEIN_DIFFUSION=<gguf> TEST_RUNNER_KLEIN_TEXT_ENCODER=<gguf> TEST_RUNNER_KLEIN_VAE=<safetensors> TEST_RUNNER_KLEIN_EVIDENCE_DIR=<dir> xcodebuild test -only-testing:GenStudioTests/KleinReferenceIntegrationTests
final class KleinReferenceIntegrationTests: XCTestCase {
    func testRealKleinTextToImageThenThreeReferenceEditThroughGenStudioAdapter() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_KLEIN_REFERENCE_INTEGRATION"] == "1",
              let diffusionPath = environment["KLEIN_DIFFUSION"], let textEncoderPath = environment["KLEIN_TEXT_ENCODER"], let vaePath = environment["KLEIN_VAE"] else {
            throw XCTSkip("Opt in with RUN_KLEIN_REFERENCE_INTEGRATION=1 and KLEIN_DIFFUSION/KLEIN_TEXT_ENCODER/KLEIN_VAE pointing at the pinned FLUX.2 Klein 4B Q4_0 components.")
        }
        let files: [String: URL] = ["diffusion": URL(fileURLWithPath: diffusionPath), "textEncoder": URL(fileURLWithPath: textEncoderPath), "vae": URL(fileURLWithPath: vaePath)]
        for (id, url) in files where !FileManager.default.isReadableFile(atPath: url.path) { throw XCTSkip("Blocker: missing local component \(id) at \(url.path). No download attempted.") }

        let root = try VideoFixtures.root("klein-reference-integration"); defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: root.appending(path: "ModelLibrary"), diskAvailable: { _ in Int64.max })
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID })
        let importStart = Date()
        _ = try await library.importFiles(recipe: recipe, filesByComponentID: files)
        let importSeconds = Date().timeIntervalSince(importStart)

        // Candidate registry: exactly the shipped descriptors, with both Klein tasks admitted for this proof run only.
        let registry = [ImageCapabilityRegistry.kleinTextToImage.with(readiness: .verified(evidence: "integration candidate")),
                         ImageCapabilityRegistry.kleinReference.with(readiness: .verified(evidence: "integration candidate"))]
        let store = StudioPersistence(root: root)
        let engine = NativeImageEngine(library: library, outputRoot: root.appending(path: "GenerationScratch"), capabilities: registry)
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, imageEngine: engine, imageCapabilities: registry)

        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "a small red toy robot standing on a wooden desk, studio lighting, plain background")
        let t2i = StudioNode(kind: .imageGenerator, label: "Text to image", position: .init(x: 1, y: 0), model: recipe.id, width: 512, height: 512, imageSeed: 424242)
        let t2iStart = Date()
        let first = try await queue.execute(project: .init(name: "Klein T2I", nodes: [prompt, t2i], edges: [VideoFixtures.edge(prompt, "text", t2i, "prompt", .text)]), targetID: t2i.id)
        let t2iSeconds = Date().timeIntervalSince(t2iStart)
        guard case .image(let base)? = first.values[.init(nodeID: t2i.id, portID: "image")] else { return XCTFail("Missing text-to-image output") }

        // Three ordered references: a "character sheet", a "portrait" and a "scene", distinct solid colours so a
        // real edit is distinguishable from a flat/failed render.
        let characterSheet = try VideoFixtures.solidPNG((210, 40, 40), width: 256, height: 256, in: root, name: "character-sheet")
        let portrait = try VideoFixtures.solidPNG((40, 210, 90), width: 256, height: 256, in: root, name: "portrait")
        let scene = try VideoFixtures.solidPNG((40, 90, 210), width: 256, height: 256, in: root, name: "scene")
        let editPrompt = StudioNode(kind: .prompt, label: "Edit prompt", position: .init(x: 0, y: 1), prompt: "Combine the character sheet identity and portrait framing into the scene background, small red toy robot, studio lighting")
        let characterNode = StudioNode(kind: .imageInput, label: "Character Sheet", position: .init(x: 0, y: 2), imagePath: characterSheet.path)
        let portraitNode = StudioNode(kind: .imageInput, label: "Portrait", position: .init(x: 0, y: 3), imagePath: portrait.path)
        let sceneNode = StudioNode(kind: .imageInput, label: "Scene", position: .init(x: 0, y: 4), imagePath: scene.path)
        let edit = StudioNode(kind: .imageGenerator, label: "Reference edit", position: .init(x: 1, y: 1), model: recipe.id, width: 512, height: 512, imageSeed: 7)
        let editStart = Date()
        let second = try await queue.execute(project: .init(name: "Klein Reference Edit", nodes: [editPrompt, characterNode, portraitNode, sceneNode, edit], edges: [
            VideoFixtures.edge(editPrompt, "text", edit, "prompt", .text),
            VideoFixtures.edge(characterNode, "image", edit, "referenceImage", .image),
            VideoFixtures.edge(portraitNode, "image", edit, "referenceImage2", .image),
            VideoFixtures.edge(sceneNode, "image", edit, "referenceImage3", .image)
        ]), targetID: edit.id)
        let editSeconds = Date().timeIntervalSince(editStart)
        guard case .image(let edited)? = second.values[.init(nodeID: edit.id, portID: "image")] else { return XCTFail("Missing three-reference edit output") }

        let runs = try await store.loadRuns()
        let editRun = try XCTUnwrap(runs.first { $0.snapshot.nodeID == edit.id })
        XCTAssertEqual(editRun.status, .succeeded)
        XCTAssertEqual(editRun.snapshot.imageRequest?.task, .imageToImage)
        XCTAssertEqual(editRun.snapshot.imageRequest?.referenceImages.count, 3, "All three ordered references must reach the adapter")
        for url in [base, edited] {
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(image.width, 512); XCTAssertEqual(image.height, 512)
        }
        let reopened = try await ModelLibrary(root: root.appending(path: "ModelLibrary")).installedModels()
        let installed = try XCTUnwrap(reopened.first { $0.id == recipe.id })
        XCTAssertEqual(installed.verifiedImageTasks, [.textToImage, .imageToImage])

        if let evidence = environment["KLEIN_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: evidence)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: directory.appending(path: "klein-t2i-512.png")); try FileManager.default.copyItem(at: base, to: directory.appending(path: "klein-t2i-512.png"))
            try? FileManager.default.removeItem(at: directory.appending(path: "klein-reference-edit-512.png")); try FileManager.default.copyItem(at: edited, to: directory.appending(path: "klein-reference-edit-512.png"))
            struct Record: Encodable {
                let date: Date; let engineBuild: String; let recipeID: String
                let diffusionSHA256: String; let textEncoderSHA256: String; let vaeSHA256: String
                let importSeconds: Double; let textToImageWallSeconds: Double; let referenceEditWallSeconds: Double
                let textToImageOutput: MediaIdentity; let referenceEditOutput: MediaIdentity
                let referenceEditRequest: ImageGenerationRequest?; let textToImageRequest: ImageGenerationRequest?
                let note: String
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let record = Record(date: Date(), engineBuild: VideoCapabilityRegistry.sdCppBuild, recipeID: recipe.id,
                                 diffusionSHA256: recipe.components.first { $0.id == "diffusion" }!.sha256, textEncoderSHA256: recipe.components.first { $0.id == "textEncoder" }!.sha256, vaeSHA256: recipe.components.first { $0.id == "vae" }!.sha256,
                                 importSeconds: importSeconds, textToImageWallSeconds: t2iSeconds, referenceEditWallSeconds: editSeconds,
                                 textToImageOutput: try MediaIdentity.of(base), referenceEditOutput: try MediaIdentity.of(edited),
                                 referenceEditRequest: editRun.snapshot.imageRequest, textToImageRequest: runs.first { $0.snapshot.nodeID == t2i.id }?.snapshot.imageRequest,
                                 note: "Wall seconds include component SHA-256 validation, model load, sampling, decode and artifact retention through ExecutionQueue. Reference inputs are synthetic solid-colour fixtures, so this proof establishes that the three-ordered-reference command path decodes a valid image end to end; it is not a quality claim about subject fidelity. Paths in requests point at a deleted temporary library.")
            try encoder.encode(record).write(to: directory.appending(path: "klein-reference-integration.json"), options: .atomic)
        }
    }
}
