import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

/// Copies a fixed-size PNG in place of real inference — mirrors FixtureUpscaleEngine, no weights needed.
actor FixtureVideoUpscaleEngine: ImageUpscaleEngine {
    let scale: Int
    private(set) var requests: [UpscaleRequest] = []
    init(scale: Int) { self.scale = scale }
    func captured() -> [UpscaleRequest] { requests }
    func upscale(_ request: UpscaleRequest) async throws -> URL {
        requests.append(request)
        guard let source = CGImageSourceCreateWithURL(request.sourceImage as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StudioError.validation("fixture: cannot decode input")
        }
        let width = image.width * scale, height = image.height * scale
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let output = request.sourceImage.deletingLastPathComponent().appending(path: "\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output
    }
}

final class VideoUpscaleTests: XCTestCase {
    private func clip(_ rgb: (Int, Int, Int), frames: Int, fps: Int, width: Int = 64, height: Int = 36, audio: Bool, in root: URL, name: String) async throws -> URL {
        let plain = try await VideoFixtures.colorClip(rgb, frames: frames, fps: fps, width: width, height: height, in: root, name: name)
        guard audio else { return plain }
        return try await VideoFixtures.withTone(plain, seconds: Double(frames) / Double(fps), in: root, name: "\(name)-toned")
    }

    func testNodeContractAndTakesSupport() {
        let node = StudioNode(kind: .videoUpscale, label: "Upscale", position: .init(x: 0, y: 0))
        XCTAssertEqual(node.inputPorts.map { "\($0.id):\($0.type.rawValue):\($0.required)" }, ["video:video:true"])
        XCTAssertEqual(node.outputPorts.map(\.type), [.video])
        XCTAssertTrue(node.supportsTakes)
        XCTAssertNil(node.kind.videoTask, "Video Upscale is not a VideoCapability-gated generative task")
        XCTAssertEqual(NodeModelCompatibility.requiredKind(for: .videoUpscale), .upscaler)
    }

    func testExactTimestampsDurationFrameOrderAndAudioArePreserved() async throws {
        let root = try VideoFixtures.root("video-upscale-e2e"); defer { try? FileManager.default.removeItem(at: root) }
        let colors = [(210, 20, 20), (20, 210, 20), (20, 20, 210), (180, 120, 20)]
        let stills = try colors.enumerated().map { index, color in
            try VideoFixtures.solidPNG(color, width: 64, height: 36, in: root, name: "frame-\(index)")
        }
        let silent = root.appending(path: "src-silent.mov")
        try await FrameSequenceEncoder.encode(
            frames: stills.map { .file($0) }, width: 64, height: 36, fps: 8,
            framesPerImage: Array(repeating: 1, count: stills.count), to: silent
        )
        let source = try await VideoFixtures.withTone(silent, seconds: Double(stills.count) / 8.0, in: root, name: "src-toned")
        let sourceProbe = try await VideoProbe.inspect(source)
        let runner = VideoUpscaleRunner(engine: FixtureVideoUpscaleEngine(scale: 2), capabilities: [UpscaleCapabilityRegistry.x4Plus], scratchRoot: root.appending(path: "Scratch"))
        let result = try await runner.run(recipeID: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, scale: 2, tileSize: 128, allowsUnverifiedLocalRun: true, sourceVideo: source)
        XCTAssertEqual(result.probe.width, 128); XCTAssertEqual(result.probe.height, 72)
        XCTAssertEqual(result.probe.frameCount, sourceProbe.frameCount)
        XCTAssertEqual(result.probe.hasAudio, true)
        XCTAssertLessThan(abs(result.probe.duration - sourceProbe.duration), 0.05)
        XCTAssertEqual(result.probe.frames.count, sourceProbe.frames.count)
        for (sourceFrame, outputFrame) in zip(sourceProbe.frames, result.probe.frames) {
            XCTAssertLessThan(abs(sourceFrame.time - outputFrame.time), 0.001, "Every original presentation timestamp must survive the round trip")
            XCTAssertTrue(
                zip(sourceFrame.centerRGB, outputFrame.centerRGB).allSatisfy { abs($0 - $1) <= 18 },
                "Frame identity/order must survive independent upscaling and re-encoding"
            )
        }
        // No staging left behind; only the final retained-scratch file remains.
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Scratch").path)
        XCTAssertEqual(leftover.count, 1)
    }

    func testMultipleAudioTracksAreRejectedNotSilentlyDropped() async throws {
        let root = try VideoFixtures.root("video-upscale-multi-audio"); defer { try? FileManager.default.removeItem(at: root) }
        let plain = try await VideoFixtures.colorClip((10, 10, 10), frames: 4, fps: 4, in: root, name: "src")
        let source = try await VideoFixtures.withMultipleAudioTracks(plain, secondsPerTrack: 1, in: root, name: "multi")
        let runner = VideoUpscaleRunner(engine: FixtureVideoUpscaleEngine(scale: 4), capabilities: [UpscaleCapabilityRegistry.x4Plus], scratchRoot: root.appending(path: "Scratch"))
        do {
            _ = try await runner.run(recipeID: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, scale: 4, tileSize: 128, allowsUnverifiedLocalRun: true, sourceVideo: source)
            XCTFail("Multiple audio tracks must be rejected, not silently dropped")
        } catch { XCTAssertTrue(error.localizedDescription.contains("audio track")) }
    }

    func testFrameCountBoundRejectsBeforeExtractionWithARemedy() async throws {
        let root = try VideoFixtures.root("video-upscale-bound"); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await VideoFixtures.colorClip((1, 2, 3), frames: VideoUpscaleBounds.maximumFrames + 1, fps: 30, in: root, name: "long")
        let runner = VideoUpscaleRunner(engine: FixtureVideoUpscaleEngine(scale: 4), capabilities: [UpscaleCapabilityRegistry.x4Plus], scratchRoot: root.appending(path: "Scratch"))
        do {
            _ = try await runner.run(recipeID: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, scale: 4, tileSize: 128, allowsUnverifiedLocalRun: true, sourceVideo: source)
            XCTFail("Over-limit clips must be rejected before extraction")
        } catch { XCTAssertTrue(error.localizedDescription.contains("shorten"), error.localizedDescription) }
        // Nothing left behind: rejection happens during the bounded extraction pass itself.
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Scratch").path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "\(leftover)")
    }

    func testCancellationLeavesNoStagingOrOutput() async throws {
        let root = try VideoFixtures.root("video-upscale-cancel"); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await VideoFixtures.colorClip((5, 5, 5), frames: 10, fps: 5, in: root, name: "src")
        actor SlowEngine: ImageUpscaleEngine {
            func upscale(_ request: UpscaleRequest) async throws -> URL { try await Task.sleep(for: .seconds(30)); throw StudioError.timedOut }
        }
        let runner = VideoUpscaleRunner(engine: SlowEngine(), capabilities: [UpscaleCapabilityRegistry.x4Plus], scratchRoot: root.appending(path: "Scratch"))
        let task = Task { try await runner.run(recipeID: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, scale: 4, tileSize: 128, allowsUnverifiedLocalRun: true, sourceVideo: source) }
        try await Task.sleep(for: .milliseconds(300)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Scratch").path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "\(leftover)")
    }

    @MainActor
    func testExecutionQueueNodeRunPersistenceProvenanceAndTakes() async throws {
        let root = try VideoFixtures.root("video-upscale-node"); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await VideoFixtures.colorClip((20, 40, 60), frames: 4, fps: 4, in: root, name: "src")
        let input = StudioNode(kind: .videoInput, label: "Source", position: .init(x: 0, y: 0), videoPath: source.path)
        var upscale = StudioNode(kind: .videoUpscale, label: "Upscale", position: .init(x: 1, y: 0), model: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID)
        upscale.upscaleScale = 4; upscale.upscaleTileSize = 128; upscale.experimentalUpscaleRecipeID = UpscaleCapabilityRegistry.realesrganX4PlusRecipeID
        let unverified = UpscaleCapabilityRegistry.x4Plus.with(readiness: .awaitingProof)
        let graph = WorkflowProject(name: "VideoUpscale", nodes: [input, upscale], edges: [VideoFixtures.edge(input, "video", upscale, "video", .video)])
        let store = StudioPersistence(root: root)
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, upscaleEngine: FixtureVideoUpscaleEngine(scale: 4), upscaleCapabilities: [unverified])
        let result = try await queue.execute(project: graph, targetID: upscale.id)
        guard case .video(let retained)? = result.values[.init(nodeID: upscale.id, portID: "video")] else { return XCTFail("Expected upscaled video") }
        XCTAssertTrue(retained.path.contains("/Artifacts/"))
        let runs = try await store.loadRuns()
        let run = try XCTUnwrap(runs.first { $0.snapshot.nodeID == upscale.id })
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.snapshot.upscaleVideoScale, 4); XCTAssertEqual(run.snapshot.upscaleVideoTileSize, 128)

        // Take history: a second run accumulates a second take, like every other generation node.
        let model = StudioModel(persistence: store, engine: StubEngine(), upscaleEngine: FixtureVideoUpscaleEngine(scale: 4))
        model.projects = [graph]; model.currentProjectID = graph.id
        model.libraryStore.installed = [.init(id: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, name: "x", kind: .upscaler, engineID: "stable-diffusion.cpp", components: [], installedAt: Date(), inferenceVerified: true, available: true)]
        model.executionArtifacts = try await store.loadExecutionArtifacts()
        model.selectedNodeID = upscale.id
        model.runSelected()
        if model.pendingRun != nil { model.confirmPendingRun() }
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.takes(for: upscale).count, 2, "Two successful runs must accumulate two takes")
    }
}
