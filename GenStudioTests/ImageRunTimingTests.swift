import XCTest
@testable import GenStudio

/// Image run history records the engine's own time, its log and the Mac's thermal state, so a slow take
/// can be told apart from model loading, file checks or a hot, throttled Mac.
private actor TimedImageEngine: ImageGenerationEngine {
    let result: URL
    init(_ result: URL) { self.result = result }
    func generate(_ request: ImageGenerationRequest) async throws -> URL {
        EngineRunLog.record?(12.5, "sampling completed, taking 9.80s\ndecode_first_stage completed, taking 2.10s")
        return result
    }
}

final class ImageRunTimingTests: XCTestCase {
    func testAnImageRunKeepsEngineTimeLogAndThermalState() async throws {
        let root = try VideoFixtures.root("image-timing"); defer { try? FileManager.default.removeItem(at: root) }
        let output = try VideoFixtures.solidPNG((0, 0, 0), width: 512, height: 512, in: root, name: "result")
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "a red bicycle")
        let generator = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 1, y: 0), model: "sd15-q4")
        let project = WorkflowProject(name: "timing", nodes: [prompt, generator], edges: [VideoFixtures.edge(prompt, "text", generator, "prompt", .text)])
        let persistence = StudioPersistence(root: root)
        _ = try await ExecutionQueue(engine: StubEngine(), persistence: persistence, imageEngine: TimedImageEngine(output), imageCapabilities: [ImageCapabilityRegistry.sd15TextToImage])
            .execute(project: project, targetID: generator.id)

        let runs = try await persistence.loadRuns(recoverInterrupted: false)
        let run = try XCTUnwrap(runs.first { $0.snapshot.nodeID == generator.id })
        XCTAssertEqual(run.snapshot.engineSeconds ?? 0, 12.5, accuracy: 0.001)
        XCTAssertTrue(run.snapshot.engineLogTail?.contains("sampling completed") == true)
        XCTAssertNotNil(run.snapshot.thermalStateAtStart)
        XCTAssertNotNil(run.snapshot.thermalStateAtEnd)
    }

    func testThermalStatesReadPlainly() {
        XCTAssertEqual(EngineRunLog.label(.nominal), "nominal")
        XCTAssertEqual(EngineRunLog.label(.serious), "serious (throttling)")
    }
}
