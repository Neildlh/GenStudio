import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

final class PromptEnhancerTests: XCTestCase {
    private let rough = "The Cat looks towards the camera, then yawns while stretching, then goes back to initial pose."

    func testNodeShapeQuickAddAndSavedTarget() async throws {
        let node = StudioNode(kind: .promptEnhancer, label: "Prompt Enhancer", position: .init(x: 0, y: 0))
        XCTAssertEqual(node.inputPorts.map(\.id), ["prompt", "image"])
        XCTAssertEqual(node.inputPorts.map(\.required), [true, false])
        XCTAssertEqual(node.outputPorts.map(\.type), [.text])
        XCTAssertEqual(node.maxTokens, PromptEnhancer.defaultMaxTokens)
        XCTAssertEqual(node.temperature, PromptEnhancer.defaultTemperature)
        XCTAssertEqual(StudioNode(kind: .textModel, label: "Text", position: .init(x: 0, y: 0)).temperature, 0.7)
        XCTAssertEqual(NodeKind.promptEnhancer.category, "Inputs & Prompts")
        XCTAssertEqual(Array(NodeKind.quickAddOrder.prefix(2)), [.prompt, .promptEnhancer])
        XCTAssertEqual(NodeModelCompatibility.requiredKind(for: .promptEnhancer), .text)
        XCTAssertTrue(NodeKind.promptEnhancer.usesModel)
        XCTAssertFalse(NodeKind.promptEnhancer.hidesCanvasRunControl)
        XCTAssertNil(node.promptEnhancerTarget, "New nodes follow the connected destination")

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var manual = node; manual.promptEnhancerTarget = .voiceover
        let store = StudioPersistence(root: root)
        try await store.saveProject(.init(name: "Saved", nodes: [manual], edges: []))
        let reopened = try await store.loadProjects()[0].nodes[0]
        XCTAssertEqual(reopened.promptEnhancerTarget, .voiceover)
        XCTAssertEqual(reopened.temperature, manual.temperature)
    }

    func testFindsDestinationThroughRoutersAndReadsItsShotSettings() {
        let graph = catGraph(router: true)
        let destination = PromptEnhancer.destinations(of: graph.enhancer.id, in: graph.project).first
        XCTAssertEqual(destination?.kind, .imageToVideo)
        XCTAssertEqual(destination?.target, .imageToVideo)
        XCTAssertEqual(destination?.width, 512)
        XCTAssertEqual(destination?.height, 768)
        XCTAssertEqual(destination?.durationSeconds, 5)
        XCTAssertEqual(PromptEnhancer.target(for: graph.enhancer, in: graph.project), .imageToVideo)
        XCTAssertEqual(PromptEnhancer.summary(for: graph.enhancer, in: graph.project, modelName: { _ in "LTX-2.3" }), "For animate an image · LTX-2.3 · 5 s · 512×768")

        let sources = PromptEnhancer.contextSources(of: graph.enhancer.id, in: graph.project)
        XCTAssertEqual(sources.map(\.sourceID), [graph.image.id])
        XCTAssertEqual(sources.first?.role, "the start frame the video begins from")

        var lone = graph.enhancer; lone.promptEnhancerTarget = nil
        let unconnected = WorkflowProject(name: "Lone", nodes: [lone], edges: [])
        XCTAssertTrue(PromptEnhancer.destinations(of: lone.id, in: unconnected).isEmpty)
        XCTAssertEqual(PromptEnhancer.target(for: lone, in: unconnected), .general)
        XCTAssertTrue(PromptEnhancer.summary(for: lone, in: unconnected, modelName: { $0 }).hasPrefix("Connect"))
    }

    func testIgnoresNegativePromptAndLeavesOutPicturesThatDependOnTheEnhancer() {
        let enhancer = StudioNode(kind: .promptEnhancer, label: "Enhance", position: .init(x: 0, y: 0))
        let still = StudioNode(kind: .imageGenerator, label: "Still", position: .init(x: 1, y: 0))
        let clip = StudioNode(kind: .imageToVideo, label: "Clip", position: .init(x: 2, y: 0))
        let text = StudioNode(kind: .textToVideo, label: "Text", position: .init(x: 2, y: 1))
        // The enhancer writes both the still's prompt and the clip's motion; the still feeds the clip.
        // Looking at the still would need the still first, which needs the enhancer: a cycle.
        let project = WorkflowProject(name: "Loop", nodes: [enhancer, still, clip, text], edges: [
            .init(sourceID: enhancer.id, sourcePortID: "text", targetID: text.id, targetPortID: "negativePrompt", type: .text),
            .init(sourceID: enhancer.id, sourcePortID: "text", targetID: clip.id, targetPortID: "prompt", type: .text),
            .init(sourceID: enhancer.id, sourcePortID: "text", targetID: still.id, targetPortID: "prompt", type: .text),
            .init(sourceID: still.id, sourcePortID: "image", targetID: clip.id, targetPortID: "startImage", type: .image)
        ])
        XCTAssertEqual(PromptEnhancer.destinations(of: enhancer.id, in: project).map(\.kind), [.imageToVideo, .imageGenerator])
        XCTAssertTrue(PromptEnhancer.contextSources(of: enhancer.id, in: project).isEmpty)
        XCTAssertTrue(PromptEnhancer.orderingDependencies(in: project).isEmpty)
    }

    func testOrderingDependencyRunsThePictureBeforeTheEnhancer() throws {
        let image = StudioNode(kind: .number, label: "Picture", position: .init(x: 0, y: 0))
        let enhancer = StudioNode(kind: .number, label: "Enhancer", position: .init(x: 1, y: 0))
        let project = WorkflowProject(name: "Order", nodes: [enhancer, image], edges: [])
        for _ in 0..<20 {
            let order = try GraphValidator().validate(project, requireRunnableInputs: false, orderingDependencies: [(before: image.id, after: enhancer.id)])
            XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: image.id)), try XCTUnwrap(order.firstIndex(of: enhancer.id)))
        }
    }

    func testInstructionCarriesDestinationRulesPicturesAndTheRequest() {
        let destination = PromptEnhancerDestination(nodeID: UUID(), kind: .imageToVideo, label: "Clip", target: .imageToVideo, modelID: "ltx", width: 512, height: 768, durationSeconds: 5, fps: 24)
        let instruction = PromptEnhancer.instruction(roughPrompt: rough, target: .imageToVideo, destination: destination, modelName: "LTX-2.3", imageRoles: ["the start frame the video begins from"])
        XCTAssertTrue(instruction.contains("Destination: Animate an image, model LTX-2.3, 5 seconds, 512×768 portrait."))
        XCTAssertTrue(instruction.contains("Image 1 is the start frame the video begins from."))
        XCTAssertTrue(instruction.contains("Pace the action to fit 5 seconds"))
        XCTAssertTrue(instruction.contains("the camera stays static"))
        XCTAssertTrue(instruction.contains("Never contradict the image"))
        XCTAssertTrue(instruction.contains("Correct spelling mistakes"))
        XCTAssertTrue(instruction.hasSuffix(rough))

        let still = PromptEnhancer.instruction(roughPrompt: "a cat", target: .image, destination: .init(nodeID: UUID(), kind: .imageGenerator, label: "Still", target: .image, modelID: "klein", width: 1024, height: 576, referenceCount: 2), modelName: nil, imageRoles: [])
        XCTAssertTrue(still.contains("1024×576 landscape"))
        XCTAssertTrue(still.contains("2 reference images"))
        XCTAssertFalse(still.contains("Image 1 is"))

        let voice = PromptEnhancer.instruction(roughPrompt: "say we open at 9", target: .voiceover, destination: .init(nodeID: UUID(), kind: .voiceover, label: "VO", target: .voiceover, modelID: "", durationSeconds: 10), modelName: nil, imageRoles: [])
        XCTAssertTrue(voice.contains("about 25 words"))
        XCTAssertTrue(voice.contains("finished script"))
    }

    func testCleanRemovesThinkingLabelsMarkdownAndWrappingQuotes() {
        XCTAssertEqual(PromptEnhancer.clean("<think>plan the shot</think>\n\nEnhanced prompt: \"The cat turns.\""), "The cat turns.")
        XCTAssertEqual(PromptEnhancer.clean("reasoning only</think>The cat yawns."), "The cat yawns.")
        XCTAssertEqual(PromptEnhancer.clean("```\n**The cat** stretches.\n```"), "The cat stretches.")
        XCTAssertEqual(PromptEnhancer.clean("A sign reads \"OPEN\" above the door."), "A sign reads \"OPEN\" above the door.")
    }

    func testRunLooksAtTheDestinationPictureAndReusesUntilTheRoughPromptChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cat = try makeImage(root.appending(path: "cat.png"))
        var graph = catGraph(router: false, imagePath: cat.path)
        let store = StudioPersistence(root: root.appending(path: "Store"))
        let vision = RecordingEnhancerVision(reply: "<think>ok</think>Prompt: The cat slowly turns its head towards the camera.")
        let text = StubEngine()
        let queue = ExecutionQueue(engine: text, persistence: store, visionEngine: vision)

        let first = try await queue.execute(project: graph.project, targetID: graph.enhancer.id)
        XCTAssertEqual(first.values[.init(nodeID: graph.enhancer.id, portID: "text")], .text("The cat slowly turns its head towards the camera."))
        let call = await vision.calls.first
        XCTAssertEqual(call?.images, [try Data(contentsOf: cat)], "The enhancer sees the clip's start image without its own Image wire")
        XCTAssertTrue(call?.prompt.contains("Animate an image") == true)
        XCTAssertTrue(call?.prompt.hasSuffix(rough) == true)
        let runs = try await store.loadRuns(recoverInterrupted: false)
        XCTAssertEqual(runs.first?.snapshot.authoredPrompt, rough)
        XCTAssertNotNil(runs.first?.snapshot.promptEnhancerFingerprint)

        // Something downstream of the enhancer reuses the prompt it already wrote.
        let reused = try await queue.execute(project: graph.project, targetID: graph.preview.id)
        let afterReuse = await vision.calls.count
        XCTAssertEqual(afterReuse, 1)
        XCTAssertEqual(reused.values[.init(nodeID: graph.preview.id, portID: "text")], .text("The cat slowly turns its head towards the camera."))

        // A new rough prompt is a new enhancement, even when only a downstream node is run.
        let promptIndex = try XCTUnwrap(graph.project.nodes.firstIndex { $0.id == graph.prompt.id })
        graph.project.nodes[promptIndex].prompt = "The cat blinks slowly."
        _ = try await queue.execute(project: graph.project, targetID: graph.preview.id)
        let afterEdit = await vision.calls.count
        XCTAssertEqual(afterEdit, 2)

        // Running the enhancer itself always writes a fresh version.
        _ = try await queue.execute(project: graph.project, targetID: graph.enhancer.id)
        let afterRerun = await vision.calls.count
        XCTAssertEqual(afterRerun, 3)
        let textCalls = await text.capturedPrompts()
        XCTAssertTrue(textCalls.isEmpty)
    }

    func testTextOnlyModelWritesWithoutThePicture() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cat = try makeImage(root.appending(path: "cat.png"))
        var graph = catGraph(router: false, imagePath: cat.path)
        let index = try XCTUnwrap(graph.project.nodes.firstIndex { $0.id == graph.enhancer.id })
        graph.project.nodes[index].model = "qwen25-05b-q4km"
        let vision = RecordingEnhancerVision(reply: "unused"), text = StubEngine(result: "The cat yawns widely.")
        let result = try await ExecutionQueue(engine: text, persistence: StudioPersistence(root: root.appending(path: "Store")), visionEngine: vision)
            .execute(project: graph.project, targetID: graph.enhancer.id)
        XCTAssertEqual(result.values[.init(nodeID: graph.enhancer.id, portID: "text")], .text("The cat yawns widely."))
        let visionCalls = await vision.calls.count
        XCTAssertEqual(visionCalls, 0)
        let prompt = await text.capturedPrompts().first
        XCTAssertEqual(prompt?.contains("Image 1 is"), false)
        XCTAssertEqual(prompt?.contains("Animate an image"), true)
    }

    func testEmptyRoughPromptFailsWithAnActionableMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var graph = catGraph(router: false)
        let index = try XCTUnwrap(graph.project.nodes.firstIndex { $0.id == graph.prompt.id })
        graph.project.nodes[index].prompt = "   "
        do {
            _ = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: graph.project, targetID: graph.enhancer.id)
            XCTFail("An empty rough prompt must not run the model")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("needs a prompt"), error.localizedDescription)
        }
    }

    // MARK: - Support

    private struct CatGraph {
        var project: WorkflowProject
        let prompt: StudioNode, enhancer: StudioNode, preview: StudioNode, image: StudioNode, clip: StudioNode
    }

    /// Prompt → Prompt Enhancer → Text Preview → Image to Video, with an Image Input as the start frame.
    private func catGraph(router: Bool, imagePath: String? = nil) -> CatGraph {
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: rough)
        let enhancer = StudioNode(kind: .promptEnhancer, label: "Prompt Enhancer", position: .init(x: 1, y: 0), model: MLXVLMModelCatalog.qwen38RecipeID)
        let preview = StudioNode(kind: router ? .textRouter : .textPreview, label: "Pass", position: .init(x: 2, y: 0))
        let image = StudioNode(kind: .imageInput, label: "Cat", position: .init(x: 1, y: 1), imagePath: imagePath)
        var clip = StudioNode(kind: .imageToVideo, label: "Image to Video", position: .init(x: 3, y: 0), model: "ltx")
        clip.video.width = 512; clip.video.height = 768; clip.video.fps = 24; clip.video.requestedDurationSeconds = 5
        let project = WorkflowProject(name: "Cat", nodes: [prompt, enhancer, preview, image, clip], edges: [
            .init(sourceID: prompt.id, sourcePortID: "text", targetID: enhancer.id, targetPortID: "prompt", type: .text),
            .init(sourceID: enhancer.id, sourcePortID: "text", targetID: preview.id, targetPortID: "text", type: .text),
            .init(sourceID: preview.id, sourcePortID: router ? "a" : "text", targetID: clip.id, targetPortID: "prompt", type: .text),
            .init(sourceID: image.id, sourcePortID: "image", targetID: clip.id, targetPortID: "startImage", type: .image)
        ])
        return .init(project: project, prompt: prompt, enhancer: enhancer, preview: preview, image: image, clip: clip)
    }

    private func makeImage(_ url: URL) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 6, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.6, green: 0.5, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }
}

private actor RecordingEnhancerVision: VisionGenerationEngine {
    struct Call: Sendable { let images: [Data]; let prompt: String }
    private(set) var calls: [Call] = []
    let reply: String
    init(reply: String) { self.reply = reply }
    func describe(images: [URL], prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        calls.append(.init(images: try images.map { try Data(contentsOf: $0) }, prompt: prompt))
        return reply
    }
}
