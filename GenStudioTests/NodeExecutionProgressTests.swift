import XCTest
@testable import GenStudio

final class NodeExecutionProgressTests: XCTestCase {
    func testStableDiffusionProgressParserIgnoresLoadCountersAndTracksSampling() {
        let parser = StableDiffusionProgressParser()
        XCTAssertTrue(parser.consume("loading tensors 243/242\r").isEmpty)
        XCTAssertEqual(parser.consume("generating image\r").first?.fraction, 0)
        XCTAssertEqual(parser.consume("  | 5/20 - 1.2 it/s\r").first?.fraction, 0.25)
        XCTAssertTrue(parser.consume("  | 5/20 - 1.2 it/s\r").isEmpty)
        XCTAssertEqual(parser.consume("  | 20/20 - 1.2 it/s\r").first?.fraction, 1)
    }

    func testOutputFollowsOnlyItsAncestorsAndTerminalEventsFreezeElapsed() {
        let a = StudioNode(kind: .textModel, label: "A", position: .init(x: 0, y: 0), model: "one")
        let b = StudioNode(kind: .textModel, label: "B", position: .init(x: 0, y: 0), model: "two")
        let output = StudioNode(kind: .textPreview, label: "Output", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Test", nodes: [a, b, output], edges: [.init(sourceID: a.id, sourcePortID: "text", targetID: output.id, targetPortID: "text", type: .text)])
        var progress = WorkflowProgress(runID: UUID(), project: project, target: output.id)
        XCTAssertNil(progress.nodes[b.id])
        progress.receive(.started(a.id))
        progress.receive(.progress(a.id, .init(stage: "Sampling 2/20", fraction: 0.1)))
        XCTAssertEqual(progress.display(for: output)?.fraction, 0.1)
        XCTAssertEqual(progress.display(for: output)?.stage, "A: Sampling 2/20")
        progress.receive(.progress(a.id, .init(stage: "Decoding")))
        XCTAssertNil(progress.display(for: output)?.fraction)
        progress.receive(.completed(a.id))
        progress.receive(.progress(a.id, .init(stage: "Late callback", fraction: 0.9)))
        XCTAssertEqual(progress.nodes[a.id]?.stage, "Done")
        let end = progress.nodes[a.id]!.elapsed(at: .now)
        XCTAssertEqual(end, progress.nodes[a.id]!.elapsed(at: Date().addingTimeInterval(100)))
        progress.failActive(error: CancellationError())
        XCTAssertEqual(progress.nodes[a.id]?.status, .completed)
        XCTAssertEqual(progress.nodes[output.id]?.status, .cancelled)
        XCTAssertFalse(progress.nodes[output.id]!.active)
    }

    func testFailureBlocksWaitingOutputAndRejectsFabricatedFraction() {
        let a = StudioNode(kind: .textModel, label: "A", position: .init(x: 0, y: 0))
        let output = StudioNode(kind: .textPreview, label: "Output", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Test", nodes: [a, output], edges: [.init(sourceID: a.id, sourcePortID: "text", targetID: output.id, targetPortID: "text", type: .text)])
        var progress = WorkflowProgress(runID: UUID(), project: project, target: output.id)
        progress.receive(.started(a.id))
        progress.receive(.progress(a.id, .init(stage: "Loading", fraction: .nan)))
        XCTAssertNil(progress.nodes[a.id]?.fraction)
        progress.failActive(error: StudioError.emptyResponse)
        XCTAssertEqual(progress.nodes[a.id]?.status, .failed)
        XCTAssertEqual(progress.nodes[output.id]?.status, .blocked)
        progress.receive(.started(output.id))
        XCTAssertEqual(progress.nodes[output.id]?.status, .blocked)
    }

    func testReusedUpstreamNodeHasNoActiveProgressPresentation() {
        let image = StudioNode(kind: .imageGenerator, label: "Existing image", position: .init(x: 0, y: 0))
        let video = StudioNode(kind: .imageToVideo, label: "Video", position: .init(x: 1, y: 0))
        let project = WorkflowProject(name: "Reuse", nodes: [image, video], edges: [
            .init(sourceID: image.id, sourcePortID: "image", targetID: video.id, targetPortID: "startImage", type: .image)
        ])
        var progress = WorkflowProgress(runID: UUID(), project: project, target: video.id)

        progress.receive(.skipped(image.id))
        progress.receive(.started(video.id))

        XCTAssertNil(progress.display(for: image), "A reused image must not look queued or active")
        XCTAssertEqual(progress.display(for: video)?.status, .running)
    }

    func testDistinctPersistedModelsExecuteSequentiallyWithLifecycleEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "start")
        let a = StudioNode(kind: .textModel, label: "A", position: .init(x: 0, y: 0), model: "model-one")
        let b = StudioNode(kind: .textModel, label: "B", position: .init(x: 0, y: 0), model: "model-two")
        let output = StudioNode(kind: .textPreview, label: "Output", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Models", nodes: [prompt, a, b, output], edges: [
            .init(sourceID: prompt.id, sourcePortID: "text", targetID: a.id, targetPortID: "prompt", type: .text),
            .init(sourceID: a.id, sourcePortID: "text", targetID: b.id, targetPortID: "prompt", type: .text),
            .init(sourceID: b.id, sourcePortID: "text", targetID: output.id, targetPortID: "text", type: .text)])
        let store = StudioPersistence(root: root)
        try await store.saveProject(project)
        let reopened = try await store.loadProjects()[0]
        let engine = ProgressRecordingEngine(), events = ProgressEventRecorder()
        let result = try await ExecutionQueue(engine: engine, persistence: store).execute(project: reopened, targetID: output.id, installedModels: ["model-one", "model-two"], onEvent: { await events.receive($0) })
        let calls = await engine.models
        XCTAssertEqual(calls, ["model-one", "model-two"])
        XCTAssertEqual(result.values[.init(nodeID: output.id, portID: "text")], .text("model-two:model-one:start"))
        let lifecycle = await events.events
        XCTAssertEqual(lifecycle, ["start:\(prompt.id)", "done:\(prompt.id)", "start:\(a.id)", "done:\(a.id)", "start:\(b.id)", "done:\(b.id)", "start:\(output.id)", "done:\(output.id)"])
    }
}

private actor ProgressRecordingEngine: TextGenerationEngine {
    var models: [String] = []
    func listModels() async throws -> [InstalledModel] { [] }
    func generate(prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        models.append(model)
        return "\(model):\(prompt)"
    }
}
private actor ProgressEventRecorder {
    var events: [String] = []
    func receive(_ event: NodeExecutionEvent) {
        switch event {
        case .started(let id): events.append("start:\(id)")
        case .completed(let id): events.append("done:\(id)")
        case .skipped: break
        case .progress: break
        }
    }
}
