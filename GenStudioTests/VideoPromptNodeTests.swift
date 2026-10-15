import XCTest
@testable import GenStudio

final class VideoPromptNodeTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioVideoPromptTests-\(UUID().uuidString)") }

    func testImageLedPromptPreservesSourceAndContainsCameraDirection() {
        var settings = VideoPromptSettings()
        settings.mode = .imageToVideo
        settings.action = "the subject takes two calm steps forward and looks toward camera"
        settings.cameraMovement = "Lateral tracking"
        settings.cameraPace = "Slow and controlled"

        let prompt = settings.compiledPrompt
        XCTAssertTrue(prompt.contains("stay exactly as in the starting image"), prompt)
        XCTAssertTrue(prompt.hasPrefix("The subject takes two calm steps forward"), "The action leads, capitalised: \(prompt)")
        XCTAssertTrue(prompt.contains("The camera tracks sideways alongside the subject"), prompt)
    }

    func testVideoPromptPersistsAndEmitsPromptAndAvoidOutputs() async throws {
        let temp = root()
        defer { try? FileManager.default.removeItem(at: temp) }
        var node = StudioNode(kind: .videoPrompt, label: "Motion brief", position: .init(x: 0, y: 0))
        node.videoPromptSettings?.mode = .textToVideo
        node.videoPromptSettings?.subjectScene = "a cyclist on a coastal road"
        node.videoPromptSettings?.action = "rides through a pool of late afternoon light"
        node.videoPromptSettings?.avoid = "flickering, jittery motion"
        let project = WorkflowProject(name: "video prompt", nodes: [node], edges: [])
        let store = StudioPersistence(root: temp)
        try await store.saveProject(project)

        let reopenedProjects = try await store.loadProjects()
        let reopened = try XCTUnwrap(reopenedProjects.first)
        XCTAssertEqual(reopened.nodes[0].videoPromptSettings?.avoid, "flickering, jittery motion")
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: reopened, targetID: reopened.nodes[0].id)
        guard case .text(let prompt)? = result.values[.init(nodeID: reopened.nodes[0].id, portID: "prompt")],
              case .text(let avoid)? = result.values[.init(nodeID: reopened.nodes[0].id, portID: "avoid")] else {
            return XCTFail("Video Prompt should emit both text outputs")
        }
        XCTAssertTrue(prompt.contains("cyclist"))
        XCTAssertEqual(avoid, "flickering, jittery motion")
    }

    func testVideoPromptFeedsImageToVideoWithoutFirstRunAuthorizationAndPersistsOutput() async throws {
        let temp = root()
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let capability = VideoCapabilityRegistry.lingBotImageToVideo
        let startFile = try VideoFixtures.solidPNG((190, 120, 55), width: 256, height: 256, in: temp, name: "start")
        let changedFile = try VideoFixtures.solidPNG((55, 120, 190), width: 256, height: 256, in: temp, name: "changed")
        let generated = temp.appending(path: "generated.mov")
        try await FrameSequenceEncoder.encode(
            frames: [.file(startFile), .file(changedFile)],
            width: 256,
            height: 256,
            fps: 8,
            framesPerImage: [16, 17],
            to: generated
        )

        let image = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: startFile.path)
        var prompt = StudioNode(kind: .videoPrompt, label: "Motion brief", position: .init(x: 0, y: 1))
        prompt.videoPromptSettings?.mode = .imageToVideo
        prompt.videoPromptSettings?.subjectScene = "a performer in warm studio light"
        prompt.videoPromptSettings?.action = "smiles gently and turns toward the camera"
        prompt.videoPromptSettings?.cameraMovement = "Gentle push in"
        var video = StudioNode(kind: .imageToVideo, label: "Image to Video", position: .init(x: 1, y: 0), model: capability.recipeID)
        video.video = .init(negativePrompt: "flicker", width: 256, height: 256, frameCount: 33, fps: 8, steps: 10, cfgScale: 3, flowShift: 3, seed: 424243)

        let project = WorkflowProject(name: "Video Prompt to I2V", nodes: [image, prompt, video], edges: [
            VideoFixtures.edge(image, "image", video, "startImage", .image),
            VideoFixtures.edge(prompt, "prompt", video, "prompt", .text)
        ])
        let store = StudioPersistence(root: temp)
        let engine = FixtureVideoEngine(.succeed(generated))
        var installed = FitFixtures.installed(capability.recipeID)
        installed.inferenceVerified = false
        installed.verifiedVideoTasks = []

        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store, videoEngine: engine, videoCapabilities: [capability])
            .execute(project: project, targetID: video.id, installedGenerationModels: [installed])

        let captured = await engine.captured()
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.prompt, prompt.videoPromptSettings?.compiledPrompt)
        XCTAssertTrue(request.prompt.localizedCaseInsensitiveContains("smiles gently"), request.prompt)
        XCTAssertNil(request.allowsUnverifiedLocalRun)
        guard case .video(let output)? = result.values[.init(nodeID: video.id, portID: "video")] else {
            return XCTFail("Image to Video should emit a retained movie")
        }
        let probe = try await VideoProbe.inspect(output)
        XCTAssertEqual(probe.width, 256)
        XCTAssertEqual(probe.height, 256)
        XCTAssertEqual(probe.frameCount, 33)
        let reopened = try await store.loadExecutionArtifacts()
        XCTAssertEqual(reopened.first?.values[.init(nodeID: video.id, portID: "video")], .video(output))
    }
}
