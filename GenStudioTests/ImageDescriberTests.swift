import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

final class ImageDescriberTests: XCTestCase {
    func testOrderedImagesPersonaInstructionsAndSelectedModelSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let red = try makeImage(root.appending(path: "red.png"), red: 1), blue = try makeImage(root.appending(path: "blue.png"), red: 0)
        let a = StudioNode(kind: .imageInput, label: "Red", position: .init(x: 0, y: 0), imagePath: red.path)
        let b = StudioNode(kind: .imageInput, label: "Blue", position: .init(x: 0, y: 0), imagePath: blue.path)
        let node = StudioNode(kind: .imageDescriber, label: "Describe", position: .init(x: 0, y: 0), model: "vision-selected", maxTokens: 1024, dynamicInputs: [.init(id: "second", label: "Image 1", type: .image), .init(id: "first", label: "Image 2", type: .image)], imageDescriberPersona: .colorist)
        let graph = WorkflowProject(name: "Vision", nodes: [a, b, node], edges: [
            .init(sourceID: a.id, sourcePortID: "image", targetID: node.id, targetPortID: "first", type: .image),
            .init(sourceID: b.id, sourcePortID: "image", targetID: node.id, targetPortID: "second", type: .image)])
        let store = StudioPersistence(root: root.appending(path: "Store"))
        try await store.saveProject(graph)
        let reopened = try await store.loadProjects()[0]
        XCTAssertEqual(reopened.nodes.last?.dynamicInputs.map(\.id), ["second", "first"])
        XCTAssertEqual(reopened.nodes.last?.model, "vision-selected")
        XCTAssertEqual(reopened.nodes.last?.imageDescriberPersona, .colorist)
        let vision = RecordingVisionEngine()
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store, visionEngine: vision).execute(project: reopened, targetID: node.id, installedModels: ["vision-selected"])
        let captured = await vision.lastCall()
        let call = try XCTUnwrap(captured)
        XCTAssertEqual(call.images, [try Data(contentsOf: blue), try Data(contentsOf: red)])
        XCTAssertEqual(call.prompt, node.prompt)
        XCTAssertTrue(call.prompt.contains("senior colorist"))
        XCTAssertEqual(call.model, "vision-selected")
        XCTAssertEqual(call.maxTokens, 1024)
        XCTAssertEqual(result.values[.init(nodeID: node.id, portID: "text")], .text("Observed blue then red."))
        XCTAssertEqual(result.textOutput?.prompt, node.prompt)
        let artifacts = try await store.loadExecutionArtifacts()
        XCTAssertEqual(artifacts.first?.graphSnapshot.nodes.last?.dynamicInputs.map(\.id), ["second", "first"])
        let history = try await store.loadRuns(recoverInterrupted: false)
        XCTAssertEqual(history.first?.status, .succeeded)
    }

    func testInlineInstructionsAndUnavailableEngineModelAndImageErrors() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = try makeImage(root.appending(path: "image.png"), red: 1)
        let image = StudioNode(kind: .imageInput, label: "Image", position: .init(x: 0, y: 0), imagePath: path.path)
        let node = StudioNode(kind: .imageDescriber, label: "Describe", position: .init(x: 0, y: 0), prompt: "Describe condensation.", model: "vision")
        var graph = WorkflowProject(name: "Test", nodes: [image, node], edges: [.init(sourceID: image.id, sourcePortID: "image", targetID: node.id, targetPortID: "image", type: .image)])
        let store = StudioPersistence(root: root.appending(path: "Store")), vision = RecordingVisionEngine()
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, visionEngine: vision)
        _ = try await queue.execute(project: graph, targetID: node.id)
        let call = await vision.lastCall()
        XCTAssertEqual(call?.prompt, node.prompt)
        do { _ = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: graph, targetID: node.id); XCTFail("Missing vision engine must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("vision engine")) }
        do { _ = try await queue.execute(project: graph, targetID: node.id, installedModels: ["other"]); XCTFail("Missing model must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("not installed")) }
        graph.edges = []
        do { _ = try await queue.execute(project: graph, targetID: node.id); XCTFail("Missing image must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("input connected")) }
    }

    func testDownstreamRunReusesCompletedImageDescription() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try makeImage(root.appending(path: "source.png"), red: 0.4)
        let generated = try makeImage(root.appending(path: "generated.png"), red: 0.8)
        let input = StudioNode(kind: .imageInput, label: "Source", position: .init(x: 0, y: 0), imagePath: source.path)
        let describer = StudioNode(kind: .imageDescriber, label: "Describe", position: .init(x: 1, y: 0), model: "vision-selected")
        let generator = StudioNode(kind: .imageGenerator, label: "Generate", position: .init(x: 2, y: 0), model: "sd15-q4")
        let graph = WorkflowProject(name: "Reuse", nodes: [input, describer, generator], edges: [
            .init(sourceID: input.id, sourcePortID: "image", targetID: describer.id, targetPortID: "image", type: .image),
            .init(sourceID: describer.id, sourcePortID: "text", targetID: generator.id, targetPortID: "prompt", type: .text)
        ])
        let store = StudioPersistence(root: root.appending(path: "Store"))
        let vision = RecordingVisionEngine()
        let image = CountingImageEngine(result: generated)
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, imageEngine: image, visionEngine: vision)

        _ = try await queue.execute(project: graph, targetID: describer.id, installedModels: ["vision-selected", "sd15-q4"])
        let firstVisionCalls = await vision.callCount()
        XCTAssertEqual(firstVisionCalls, 1)
        _ = try await queue.execute(project: graph, targetID: generator.id, installedModels: ["vision-selected", "sd15-q4"])

        let secondVisionCalls = await vision.callCount()
        let imageCalls = await image.callCount()
        XCTAssertEqual(secondVisionCalls, 1, "Running the generator must not rerun the completed Image Describer")
        XCTAssertEqual(imageCalls, 1)
    }

    func testUnboundedDynamicSocketsAndDefaultImageAnalystInstructions() throws {
        var node = StudioNode(kind: .imageDescriber, label: "Describe", position: .init(x: 0, y: 0))
        XCTAssertEqual(node.maxTokens, 1024)
        XCTAssertEqual(StudioNode(kind: .imageDescriber, label: "Explicit", position: .init(x: 0, y: 0), maxTokens: 64).maxTokens, 64)
        XCTAssertEqual(NodeLayout.cardWidth(node), 360)
        XCTAssertEqual(NodeLayout.previewHeight(node), 300)
        XCTAssertEqual(node.inputPorts.map(\.type), [.image])
        XCTAssertEqual(node.inputPorts.map(\.required), [true])
        XCTAssertTrue(node.prompt.contains("expert image analyst"))
        XCTAssertTrue(node.prompt.contains("500 characters"))
        XCTAssertEqual(node.outputPorts.first?.type, .text)
        node.dynamicInputs = (0..<12).map { DynamicInputPort(id: "img\($0)", label: "Image \($0 + 1)", type: .image) }
        XCTAssertNoThrow(try GraphValidator().validate(.init(name: "Many", nodes: [node], edges: []), requireRunnableInputs: false))
        let invalidPorts: [[DynamicInputPort]] = [[], [.init(id: "wrong", label: "Wrong", type: .text)]]
        for ports in invalidPorts {
            node.dynamicInputs = ports
            XCTAssertThrowsError(try GraphValidator().validate(.init(name: "Invalid", nodes: [node], edges: []), requireRunnableInputs: false))
        }
    }

    func testPersonaPromptUsesSpecialistLensAndKeepsGeneralLimit() {
        let prompt = StudioNode.imageDescriberInstructions(for: .advertisingPhotographer)
        XCTAssertTrue(prompt.contains("expert image analyst"))
        XCTAssertTrue(prompt.contains("senior commercial photographer"))
        XCTAssertTrue(prompt.contains("500-character limit"))
        XCTAssertEqual(StudioNode.imageDescriberInstructions(for: nil), StudioNode.imageDescriberInstructions)
    }

    func testCharacterSheetWritesADeterministicProductionPrompt() throws {
        var node = StudioNode(kind: .characterSheet, label: "Character Sheet", position: .init(x: 0, y: 0))
        XCTAssertEqual(node.characterSheetSubject, .person)
        XCTAssertEqual(CharacterSheetSubject.allCases, [.person, .animatedCharacter, .animal, .product])
        XCTAssertTrue(node.inputPorts.isEmpty)
        XCTAssertEqual(node.outputPorts.map(\.type), [.text])
        XCTAssertNil(NodeModelCompatibility.requiredKind(for: .characterSheet))
        XCTAssertFalse(node.kind.usesModel)
        XCTAssertTrue(node.kind.hidesCanvasRunControl)
        XCTAssertTrue(node.prompt.contains("professional person reference sheet"))
        XCTAssertFalse(node.prompt.localizedCaseInsensitiveContains("reference image"))

        XCTAssertTrue(CharacterSheetSubject.animatedCharacter.generationLayoutInstructions.contains("three rows"))
        XCTAssertTrue(CharacterSheetSubject.animal.generationLayoutInstructions.contains("complete ears, legs or wings, paws or hooves, and tail"))
        XCTAssertTrue(CharacterSheetSubject.product.generationLayoutInstructions.contains("macro study"))
        XCTAssertTrue(CharacterSheetSubject.product.generationLayoutInstructions.contains("label placement"))

        let generated = StudioNode.characterSheetPrompt(for: .person)
        XCTAssertTrue(generated.contains("Keep the subject's existing body pose and age unchanged"))
        XCTAssertTrue(generated.contains("same head-to-body ratio, limb lengths"))
        XCTAssertTrue(generated.contains("one hand with its sleeve"))
        XCTAssertFalse(generated.contains("A-pose"))
        XCTAssertTrue(generated.contains("same body scale and baseline"))
        XCTAssertFalse(generated.contains(" cm"), "Unknown physical dimensions must never be invented")

        node.characterSheetSubject = .product
        node.prompt = StudioNode.characterSheetPrompt(for: .product)
        let reopened = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(reopened.characterSheetSubject, .product)
        XCTAssertEqual(reopened.prompt, node.prompt)
    }

    func testCharacterSheetEmitsItsBuiltInPromptWithoutRunningVision() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sheet = StudioNode(kind: .characterSheet, label: "Sheet", position: .init(x: 0, y: 0), characterSheetSubject: .person)
        let graph = WorkflowProject(name: "Character Sheet", nodes: [sheet], edges: [])
        let vision = RecordingVisionEngine()
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root.appending(path: "Store")), visionEngine: vision)
            .execute(project: graph, targetID: sheet.id, installedModels: [])
        let call = await vision.lastCall()
        XCTAssertNil(call)
        let emitted = try XCTUnwrap(result.values[.init(nodeID: sheet.id, portID: "text")])
        guard case .text(let prompt) = emitted else {
            return XCTFail("Expected a text prompt.")
        }
        XCTAssertEqual(prompt, sheet.prompt)
        XCTAssertEqual(prompt, sheet.characterSheetBrief)
    }

    func testCharacterSheetHeightAndCurrentBriefSurviveReopeningAnOlderTemplate() throws {
        var sheet = StudioNode(kind: .characterSheet, label: "Sheet", position: .init(x: 0, y: 0))
        sheet.prompt = "A stale template that forces a standing pose."
        sheet.characterSheetHeightCM = 179.5
        sheet.characterSheetPose = .standing
        let reopened = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(sheet))
        XCTAssertEqual(reopened.characterSheetHeightCM, 179.5)
        XCTAssertEqual(reopened.characterSheetPose, .standing)
        XCTAssertTrue(reopened.prompt.contains("subject standing in one relaxed natural pose"))
        XCTAssertEqual(reopened.prompt, reopened.characterSheetBrief)
        XCTAssertTrue(reopened.prompt.contains("179.5 cm"))
        XCTAssertFalse(reopened.prompt.contains("stale template"))
        XCTAssertFalse(StudioNode.characterSheetPrompt(for: .person, heightCM: .nan).contains(" cm"))
        XCTAssertFalse(StudioNode.characterSheetPrompt(for: .person, heightCM: -1).contains(" cm"))
        XCTAssertTrue(StudioNode.characterSheetPrompt(for: .animal, heightCM: 55).contains("Shoulder height: 55 cm"))
        let seated = StudioNode.characterSheetPrompt(for: .person, pose: .seated)
        XCTAssertTrue(seated.contains("subject seated on the same surface"))
        XCTAssertFalse(seated.contains("standing"), "Only the selected pose should be offered to the model")
        XCTAssertEqual(StudioNode.characterSheetPrompt(for: .product, pose: .seated), StudioNode.characterSheetPrompt(for: .product))
    }

    func testLegacyInstructionsEdgeIsRemovedWhenWorkflowReopens() throws {
        let prompt = StudioNode(kind: .prompt, label: "Old Instructions", position: .init(x: 0, y: 0), prompt: "Old wired instructions")
        let describer = StudioNode(kind: .imageDescriber, label: "Describe", position: .init(x: 1, y: 0))
        let graph = WorkflowProject(name: "Legacy", nodes: [prompt, describer], edges: [
            .init(sourceID: prompt.id, sourcePortID: "text", targetID: describer.id, targetPortID: "prompt", type: .text)
        ])
        let reopened = try JSONDecoder().decode(WorkflowProject.self, from: JSONEncoder().encode(graph))
        XCTAssertTrue(reopened.edges.isEmpty)
        XCTAssertEqual(reopened.nodes.last?.inputPorts.map(\.type), [.image])
    }

    @MainActor
    func testReferencePreviewUsesWiredComparePortAndImageRemovalPreservesIDs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let compare = StudioNode(kind: .imageCompare, label: "Compare", position: .init(x: 0, y: 0))
        let node = StudioNode(kind: .imageDescriber, label: "Describe", position: .init(x: 0, y: 0), dynamicInputs: [.init(id: "first", label: "Image 1", type: .image), .init(id: "second", label: "Image 2", type: .image)])
        let graph = WorkflowProject(name: "Preview", nodes: [compare, node], edges: [.init(sourceID: compare.id, sourcePortID: "b", targetID: node.id, targetPortID: "second", type: .image)])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [graph]; model.currentProjectID = graph.id
        let a = root.appending(path: "a.png"), b = root.appending(path: "b.png")
        model.runtimeValues = [.init(nodeID: compare.id, portID: "selected"): .image(a), .init(nodeID: compare.id, portID: "b"): .image(b)]
        XCTAssertEqual(model.referenceImages(for: node), [b])
        model.removeDynamicInput(nodeID: node.id, portID: "first")
        let remaining = try XCTUnwrap(model.currentProject?.nodes.last)
        XCTAssertEqual(remaining.dynamicInputs.map(\.id), ["second"])
        XCTAssertEqual(remaining.dynamicInputs.map(\.label), ["Image 1"])
        XCTAssertEqual(model.currentProject?.edges.first?.targetPortID, "second")
        model.addDynamicInput(to: node.id)
        XCTAssertEqual(model.currentProject?.nodes.last?.dynamicInputs.map(\.label), ["Image 1", "Image 2"])
        for _ in 0..<5 { model.addDynamicInput(to: node.id) }
        XCTAssertEqual(model.currentProject?.nodes.last?.dynamicInputs.count, 7)
    }

    @MainActor
    func testOffscreenImageDescriberCardEvidence() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["GENSTUDIO_NODE_CARD_EVIDENCE"] else { throw XCTSkip("Set GENSTUDIO_NODE_CARD_EVIDENCE to write an offscreen node image.") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = try (0..<4).map { try makeImage(root.appending(path: "reference-\($0).png"), red: CGFloat($0) / 3) }
        let node = StudioNode(kind: .imageDescriber, label: "Image Describer", position: .init(x: 0, y: 0), model: "vision-fixture", dynamicInputs: (0..<4).map { .init(id: "image-\($0)", label: "Image \($0 + 1)", type: .image) })
        var progress = NodeExecutionProgress()
        progress.status = .completed; progress.stage = "Done"; progress.queuedAt = Date().addingTimeInterval(-83); progress.finishedAt = Date()
        let card = NodeCard(node: node, output: .text("Observed: warm sidelight, condensation on the bottle, fruit in the foreground. Estimated: a short telephoto lens; distance is uncertain."), progress: progress, referenceImages: urls, modelName: "Qwen 2.5 VL 7B · detailed vision", addImageInput: {}, runModel: {}, selected: true, activeWire: nil, move: { _, _ in }, wire: { _, _, _, _ in })
            .frame(width: NodeLayout.cardWidth(node), height: NodeLayout.cardHeight(node)).padding(24).background(Color(white: 0.08))
        let host = NSHostingView(rootView: card)
        let size = NSSize(width: NodeLayout.cardWidth(node) + 48, height: NodeLayout.cardHeight(node) + 48)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 300)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 400)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath))
    }

    private func makeImage(_ url: URL, red: CGFloat) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: 1 - red, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }
}

private actor RecordingVisionEngine: VisionGenerationEngine {
    struct Call: Sendable { let images: [Data]; let prompt: String; let model: String; let maxTokens: Int }
    private var call: Call?
    func describe(images: [URL], prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        call = .init(images: try images.map { try Data(contentsOf: $0) }, prompt: prompt, model: model, maxTokens: maxTokens)
        return "Observed blue then red."
    }
    func lastCall() -> Call? { call }
    func callCount() -> Int { call == nil ? 0 : 1 }
}

private actor CountingImageEngine: ImageGenerationEngine {
    private let result: URL
    private var calls = 0
    init(result: URL) { self.result = result }
    func generate(_ request: ImageGenerationRequest) async throws -> URL { calls += 1; return result }
    func callCount() -> Int { calls }
}
