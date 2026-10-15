import AVFoundation
import XCTest
@testable import GenStudio

/// Real inference, explicitly opted in. Uses existing local weights only; never downloads.
/// Run: TEST_RUNNER_RUN_WAN_T2V_INTEGRATION=1 TEST_RUNNER_WAN_MODELS_DIR=<dir> TEST_RUNNER_WAN_EVIDENCE_DIR=<dir> xcodebuild test -only-testing:GenStudioTests/WanTextToVideoIntegrationTests
final class WanTextToVideoIntegrationTests: XCTestCase {
    /// End-to-end proof for the user's installed LTX-2.5 setup. The graph deliberately starts
    /// with a Video Prompt node so this validates structured prompt compilation, graph routing,
    /// native I2V execution, decoded temporal output and persistence in one run.
    func testRealLTX25ImageToVideoViaVideoPromptThroughInstalledLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LTX25_I2V_INTEGRATION"] == "1",
              let libraryPath = environment["GENSTUDIO_MODEL_LIBRARY"] else {
            throw XCTSkip("Opt in with TEST_RUNNER_RUN_LTX25_I2V_INTEGRATION=1 and TEST_RUNNER_GENSTUDIO_MODEL_LIBRARY pointing at GenStudio's existing ModelLibrary directory.")
        }

        let root = try VideoFixtures.root("ltx25-video-prompt-i2v-integration")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: URL(fileURLWithPath: libraryPath))
        let capability = VideoCapabilityRegistry.ltx25ImageToVideo
        let installed: [InstalledGenerationModel]
        do {
            installed = try await library.installedModels()
        } catch {
            XCTFail("LTX proof failed while reading the installed-model registry: \(String(reflecting: error))")
            throw error
        }
        guard installed.contains(where: { $0.id == capability.recipeID && $0.available }) else {
            throw XCTSkip("The exact LTX-2.5 recipe is not completely installed.")
        }
        do {
            _ = try await library.installedRecipe(id: capability.recipeID)
        } catch {
            XCTFail("LTX proof failed while decoding its immutable recipe manifest: \(String(reflecting: error))")
            throw error
        }

        let sourceFile = try VideoFixtures.solidPNG((188, 112, 48), width: 256, height: 256, in: root, name: "start")
        let source = StudioNode(kind: .imageInput, label: "Start frame", position: .init(x: 0, y: 0), imagePath: sourceFile.path)
        var prompt = StudioNode(kind: .videoPrompt, label: "Video Prompt", position: .init(x: 0, y: 1))
        prompt.videoPromptSettings?.mode = .imageToVideo
        prompt.videoPromptSettings?.subjectScene = "a warm amber paper sculpture on a dark studio table"
        prompt.videoPromptSettings?.action = "the sculpture slowly unfolds while catching a soft moving highlight"
        prompt.videoPromptSettings?.cameraMovement = "Gentle push in"
        prompt.videoPromptSettings?.cameraPace = "Slow and controlled"
        prompt.videoPromptSettings?.continuity = "keep the sculpture centered and preserve its amber color"
        prompt.videoPromptSettings?.avoid = "static, frozen, flicker, jitter, distortion"
        var video = StudioNode(kind: .imageToVideo, label: "LTX-2.5 Image to Video", position: .init(x: 1, y: 0), model: capability.recipeID)
        video.video = .init(negativePrompt: prompt.videoPromptSettings?.avoid ?? "", width: 256, height: 256, frameCount: 9, fps: 8, steps: 1, cfgScale: 3, flowShift: 3, seed: 424243)
        let project = WorkflowProject(name: "LTX-2.5 Video Prompt proof", nodes: [source, prompt, video], edges: [
            VideoFixtures.edge(source, "image", video, "startImage", .image),
            VideoFixtures.edge(prompt, "prompt", video, "prompt", .text)
        ])

        let store = StudioPersistence(root: root)
        let engine = NativeWanVideoEngine(library: library, scratchRoot: root.appending(path: "GenerationScratch"), timeout: .seconds(3600), capabilities: [capability])
        let started = Date()
        let result: ExecutionResult
        do {
            result = try await ExecutionQueue(engine: StubEngine(), persistence: store, videoEngine: engine, videoCapabilities: [capability])
                .execute(project: project, targetID: video.id, installedGenerationModels: installed)
        } catch {
            XCTFail("LTX proof failed during graph execution or native generation: \(String(reflecting: error))")
            throw error
        }
        let elapsed = Date().timeIntervalSince(started)

        guard case .video(let output)? = result.values[.init(nodeID: video.id, portID: "video")] else {
            return XCTFail("LTX-2.5 completed without publishing a video output")
        }
        let probe: VideoProbe
        do {
            probe = try await VideoProbe.inspect(output)
        } catch {
            XCTFail("LTX proof failed while decoding and inspecting the rendered movie: \(String(reflecting: error))")
            throw error
        }
        XCTAssertEqual(probe.width, 256)
        XCTAssertEqual(probe.height, 256)
        XCTAssertEqual(probe.frameCount, 9)
        XCTAssertGreaterThan(probe.distinctFrameCount, 1)
        XCTAssertLessThan(elapsed, 3600)
        let runs: [RunRecord]
        do {
            runs = try await store.loadRuns()
        } catch {
            XCTFail("LTX proof failed while reopening persisted run provenance: \(String(reflecting: error))")
            throw error
        }
        let run = try XCTUnwrap(runs.first { $0.snapshot.nodeID == video.id })
        XCTAssertEqual(run.snapshot.videoRequest?.prompt, prompt.videoPromptSettings?.compiledPrompt)
        XCTAssertNil(run.snapshot.videoRequest?.allowsUnverifiedLocalRun)
        let reopened: [ExecutionArtifact]
        do {
            reopened = try await store.loadExecutionArtifacts()
        } catch {
            XCTFail("LTX proof failed while reopening persisted graph outputs: \(String(reflecting: error))")
            throw error
        }
        XCTAssertEqual(reopened.first?.values[.init(nodeID: video.id, portID: "video")], .video(output))

        if let evidencePath = environment["VIDEO_EVIDENCE_DIR"] {
            let evidence = URL(fileURLWithPath: evidencePath)
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            let movie = evidence.appending(path: "ltx25-i2v-video-prompt-256x256-9f.mov")
            try? FileManager.default.removeItem(at: movie)
            try FileManager.default.copyItem(at: output, to: movie)
            struct Report: Encodable {
                let recordedAt: Date
                let elapsedSeconds: Double
                let prompt: String
                let output: VideoProbeSummary
                let sha256: String
            }
            let report = Report(recordedAt: Date(), elapsedSeconds: elapsed, prompt: prompt.videoPromptSettings?.compiledPrompt ?? "", output: .init(probe), sha256: try MediaIdentity.of(movie).sha256)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: evidence.appending(path: "ltx25-i2v-video-prompt-proof.json"), options: .atomic)
        }
    }

    func testRealWanFirstLastFrameThroughInstalledLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_WAN_FLF_INTEGRATION"] == "1",
              let libraryPath = environment["GENSTUDIO_MODEL_LIBRARY"] else {
            throw XCTSkip("Opt in with TEST_RUNNER_RUN_WAN_FLF_INTEGRATION=1 and TEST_RUNNER_GENSTUDIO_MODEL_LIBRARY pointing at GenStudio's existing ModelLibrary directory.")
        }
        let root = try VideoFixtures.root("wan-flf-integration"); defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: URL(fileURLWithPath: libraryPath))
        let installed = try await library.installedModels()
        let capability = VideoCapabilityRegistry.wan21FirstLastFrame.with(readiness: .verified(evidence: "local integration candidate"))
        guard installed.contains(where: { $0.id == capability.recipeID && $0.available }) else { throw XCTSkip("The exact Wan FLF2V recipe is not completely installed.") }
        let engine = NativeWanVideoEngine(library: library, scratchRoot: root.appending(path: "GenerationScratch"), timeout: .seconds(1800), capabilities: [capability])
        let queue = ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), videoEngine: engine, videoCapabilities: [capability])
        let startFile = try VideoFixtures.solidPNG((210, 45, 30), width: 120, height: 208, in: root, name: "start")
        let endFile = try VideoFixtures.solidPNG((30, 70, 210), width: 120, height: 208, in: root, name: "end")
        let start = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: startFile.path)
        let end = StudioNode(kind: .imageInput, label: "End", position: .init(x: 0, y: 1), imagePath: endFile.path)
        let prompt = StudioNode(kind: .prompt, label: "Transition", position: .init(x: 0, y: 2), prompt: "A smooth cinematic transition from the warm red frame to the cool blue frame.")
        var video = StudioNode(kind: .startEndVideo, label: "Wan FLF proof", position: .init(x: 1, y: 0), model: capability.recipeID)
        video.video = .init(negativePrompt: "flicker, distortion", width: 480, height: 832, frameCount: 5, fps: 8, steps: 4, cfgScale: 6, flowShift: 3, seed: 424243)
        let project = WorkflowProject(name: "Wan FLF proof", nodes: [start, end, prompt, video], edges: [
            VideoFixtures.edge(start, "image", video, "startImage", .image), VideoFixtures.edge(end, "image", video, "endImage", .image),
            VideoFixtures.edge(prompt, "text", video, "prompt", .text)
        ])
        let result = try await queue.execute(project: project, targetID: video.id, installedGenerationModels: installed)
        guard case .video(let output)? = result.values[.init(nodeID: video.id, portID: "video")] else { return XCTFail("Wan FLF completed without a video") }
        let probe = try await VideoProbe.inspect(output)
        XCTAssertEqual(probe.width, 480); XCTAssertEqual(probe.height, 832); XCTAssertEqual(probe.frameCount, 5); XCTAssertGreaterThan(probe.distinctFrameCount, 1)
        let refreshed = try await library.installedModels()
        XCTAssertTrue(try XCTUnwrap(refreshed.first { $0.id == capability.recipeID }).hasVerifiedVideoTask(.firstLastFrame))
    }

    func testRealMiniMaxRef2VAThroughInstalledLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_MINIMAX_REF2VA_INTEGRATION"] == "1",
              let libraryPath = environment["GENSTUDIO_MODEL_LIBRARY"] else {
            throw XCTSkip("Opt in with TEST_RUNNER_RUN_MINIMAX_REF2VA_INTEGRATION=1 and TEST_RUNNER_GENSTUDIO_MODEL_LIBRARY pointing at GenStudio's existing ModelLibrary directory.")
        }
        let root = try VideoFixtures.root("minimax-ref2va-integration"); defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: URL(fileURLWithPath: libraryPath))
        let installed = try await library.installedModels()
        let capability = VideoCapabilityRegistry.minimaxH3VideoToVideo.with(readiness: .verified(evidence: "local integration candidate"))
        guard installed.contains(where: { $0.id == capability.recipeID && $0.available }) else { throw XCTSkip("The exact MiniMax-H3 Ref2VA recipe is not completely installed.") }
        let engine = NativeWanVideoEngine(library: library, scratchRoot: root.appending(path: "GenerationScratch"), timeout: .seconds(3600), capabilities: [capability])
        let queue = ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), videoEngine: engine, videoCapabilities: [capability])
        let sourceFile = try await VideoFixtures.colorClip((90, 140, 200), frames: 5, fps: 24, width: 320, height: 320, in: root, name: "source")
        let source = StudioNode(kind: .videoInput, label: "Source", position: .init(x: 0, y: 0), videoPath: sourceFile.path)
        let prompt = StudioNode(kind: .prompt, label: "Edit", position: .init(x: 0, y: 1), prompt: "Restyle the clip with soft cinematic light while preserving its motion and composition.")
        var video = StudioNode(kind: .videoToVideo, label: "MiniMax Ref2VA proof", position: .init(x: 1, y: 0), model: capability.recipeID)
        video.video = .init(negativePrompt: "flicker, distortion", width: 320, height: 320, frameCount: 5, fps: 24, steps: 8, cfgScale: 1, flowShift: 12, seed: 424243)
        let project = WorkflowProject(name: "MiniMax Ref2VA proof", nodes: [source, prompt, video], edges: [
            VideoFixtures.edge(source, "video", video, "sourceVideo", .video), VideoFixtures.edge(prompt, "text", video, "prompt", .text)
        ])
        let result = try await queue.execute(project: project, targetID: video.id, installedGenerationModels: installed)
        guard case .video(let output)? = result.values[.init(nodeID: video.id, portID: "video")] else { return XCTFail("MiniMax Ref2VA completed without a video") }
        let probe = try await VideoProbe.inspect(output)
        XCTAssertEqual(probe.width, 320); XCTAssertEqual(probe.height, 320); XCTAssertEqual(probe.frameCount, 5); XCTAssertGreaterThan(probe.distinctFrameCount, 1)
        let refreshed = try await library.installedModels()
        XCTAssertTrue(try XCTUnwrap(refreshed.first { $0.id == capability.recipeID }).hasVerifiedVideoTask(.videoToVideo))
    }

    /// Real LingBot image-to-video proof against an existing GenStudio model library. It never
    /// downloads or copies model weights. Success records task-specific proof in that library,
    /// exactly as a successful app run does.
    /// Run: TEST_RUNNER_RUN_LINGBOT_I2V_INTEGRATION=1 TEST_RUNNER_GENSTUDIO_MODEL_LIBRARY=<ModelLibrary dir>
    ///      xcodebuild test -only-testing:GenStudioTests/WanTextToVideoIntegrationTests/testRealLingBotImageToVideoThroughInstalledLibrary
    func testRealLingBotImageToVideoThroughInstalledLibrary() async throws {
        let environment = ProcessInfo.processInfo.environment
        // xcodebuild forwards TEST_RUNNER_* variables to the test process with that prefix removed.
        guard environment["RUN_LINGBOT_I2V_INTEGRATION"] == "1",
              let libraryPath = environment["GENSTUDIO_MODEL_LIBRARY"] else {
            throw XCTSkip("Opt in with TEST_RUNNER_RUN_LINGBOT_I2V_INTEGRATION=1 and TEST_RUNNER_GENSTUDIO_MODEL_LIBRARY pointing at GenStudio's existing ModelLibrary directory.")
        }
        let root = try VideoFixtures.root("lingbot-i2v-integration")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: URL(fileURLWithPath: libraryPath))
        let installed = try await library.installedModels()
        let recipeID = MediaModelCatalog.lingBotRecipeID
        guard installed.contains(where: { $0.id == recipeID && $0.available }) else {
            throw XCTSkip("The exact LingBot Dense 1.3B recipe is not completely installed in this library.")
        }

        let candidate = VideoCapabilityRegistry.lingBotImageToVideo.with(readiness: .verified(evidence: "local integration candidate"))
        let registry = [candidate]
        let engine = NativeWanVideoEngine(
            library: library,
            scratchRoot: root.appending(path: "GenerationScratch"),
            timeout: .seconds(1800),
            capabilities: registry
        )
        let store = StudioPersistence(root: root)
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, videoEngine: engine, videoCapabilities: registry)
        let sourceFile = try VideoFixtures.solidPNG((210, 130, 35), width: 160, height: 90, in: root, name: "start")
        let source = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: sourceFile.path)
        let prompt = StudioNode(kind: .prompt, label: "Motion", position: .init(x: 0, y: 1), prompt: "The camera slowly pushes forward while soft light moves across the scene; stable composition, natural motion.")
        var video = StudioNode(kind: .imageToVideo, label: "LingBot I2V", position: .init(x: 1, y: 0), model: recipeID)
        video.video = .init(negativePrompt: "flicker, static, frozen, distorted, low quality", width: 448, height: 256, frameCount: 33, fps: 8, steps: 10, cfgScale: 3, flowShift: 3, seed: 424243)
        let project = WorkflowProject(name: "LingBot I2V proof", nodes: [source, prompt, video], edges: [
            VideoFixtures.edge(source, "image", video, "startImage", .image),
            VideoFixtures.edge(prompt, "text", video, "prompt", .text)
        ])

        let started = Date()
        let result = try await queue.execute(project: project, targetID: video.id, installedGenerationModels: installed)
        guard case .video(let output)? = result.values[.init(nodeID: video.id, portID: "video")] else {
            return XCTFail("LingBot completed without publishing a video output")
        }
        let probe = try await VideoProbe.inspect(output)
        XCTAssertEqual(probe.width, 448); XCTAssertEqual(probe.height, 256)
        XCTAssertEqual(probe.frameCount, 33); XCTAssertGreaterThan(probe.distinctFrameCount, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1800)
        let refreshed = try await library.installedModels()
        XCTAssertTrue(try XCTUnwrap(refreshed.first { $0.id == recipeID }).hasVerifiedVideoTask(.imageToVideo))
    }

    func testRealWanTextToVideoThroughAdapterThenAnimaticAndAssembly() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_WAN_T2V_INTEGRATION"] == "1", let modelsPath = environment["WAN_MODELS_DIR"] else {
            throw XCTSkip("Opt in with RUN_WAN_T2V_INTEGRATION=1 and WAN_MODELS_DIR containing the pinned Wan2.1 T2V components.")
        }
        let models = URL(fileURLWithPath: modelsPath)
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == VideoCapabilityRegistry.wanT2VRecipeID })
        let files = Dictionary(uniqueKeysWithValues: recipe.components.map { ($0.id, models.appending(path: URL(fileURLWithPath: $0.filename).lastPathComponent)) })
        for (id, url) in files where !FileManager.default.isReadableFile(atPath: url.path) { throw XCTSkip("Blocker: missing local component \(id) at \(url.path). No download attempted.") }

        let root = try VideoFixtures.root("wan-t2v-integration")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: root.appending(path: "ModelLibrary"), diskAvailable: { _ in Int64.max })
        let importStart = Date()
        _ = try await library.importFiles(recipe: recipe, filesByComponentID: files)
        let importSeconds = Date().timeIntervalSince(importStart)

        // Candidate registry: the shipped descriptor with proof pending is exercised exactly as the app would once verified.
        let registry = [VideoCapabilityRegistry.wanTextToVideo.with(readiness: .verified(evidence: "integration candidate"))]
        let store = StudioPersistence(root: root)
        let engine = NativeWanVideoEngine(library: library, scratchRoot: root.appending(path: "GenerationScratch"), timeout: .seconds(1500))
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, videoEngine: engine, videoCapabilities: registry)

        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "a red paper pinwheel slowly turning in a gentle breeze, locked camera, dark neutral studio background, soft light")
        var t2v = StudioNode(kind: .textToVideo, label: "Text to Video", position: .init(x: 1, y: 0), model: VideoCapabilityRegistry.wanT2VRecipeID)
        t2v.video = .measuredProbe
        let stills = try [(230, 20, 20), (20, 200, 30), (20, 40, 230), (240, 220, 20), (230, 30, 220)].enumerated().map { try VideoFixtures.solidPNG($0.element, width: 320, height: 192, in: root, name: "still\($0.offset)") }
        var sequence = StudioNode(kind: .shotSequence, label: "Shot Sequence", position: .init(x: 0, y: 1))
        sequence.sequence = .init(anchors: stills.enumerated().map { ShotAnchor(label: "Frame \($0.offset + 1)", holdSeconds: 0.5, transitionNote: "cut to next", imagePath: $0.element.path) }, finalHoldSeconds: 0.5, fps: 8, width: 320, height: 192)
        let animatic = StudioNode(kind: .animatic, label: "Animatic", position: .init(x: 1, y: 1))
        var assemble = StudioNode(kind: .assembleVideo, label: "Assemble", position: .init(x: 2, y: 0))
        assemble.dynamicInputs = [.init(id: "clip-generated", label: "Clip 1", type: .video), .init(id: "clip-animatic", label: "Clip 2", type: .video)]
        assemble.assembly = .init(width: 320, height: 192, fps: 8, audio: .preserve)
        let project = WorkflowProject(name: "Wan proof", nodes: [prompt, t2v, sequence, animatic, assemble], edges: [
            VideoFixtures.edge(prompt, "text", t2v, "prompt", .text), VideoFixtures.edge(sequence, "sequence", animatic, "sequence", .shotSequence),
            VideoFixtures.edge(t2v, "video", assemble, "clip-generated", .video), VideoFixtures.edge(animatic, "video", assemble, "clip-animatic", .video)])

        let stages = StageLog()
        let runStart = Date()
        let result = try await queue.execute(project: project, targetID: assemble.id, onEvent: { event in if case .progress(_, let update) = event { await stages.add(update.stage) } })
        let wallSeconds = Date().timeIntervalSince(runStart)

        guard case .video(let generated)? = result.values[.init(nodeID: t2v.id, portID: "video")],
              case .video(let animaticURL)? = result.values[.init(nodeID: animatic.id, portID: "video")],
              case .video(let assembled)? = result.values[.init(nodeID: assemble.id, portID: "video")] else { return XCTFail("Missing outputs") }
        let probe = try await VideoProbe.inspect(generated)
        XCTAssertEqual(probe.width, 320); XCTAssertEqual(probe.height, 192); XCTAssertEqual(probe.frameCount, 9)
        XCTAssertEqual(probe.duration, 1.125, accuracy: 0.01); XCTAssertEqual(probe.lastFrameTimestamp, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(probe.distinctFrameCount, 1, "Generated frames must vary")
        let runs = try await store.loadRuns()
        let run = try XCTUnwrap(runs.first { $0.snapshot.nodeID == t2v.id })
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.snapshot.videoRequest?.seed, 424243); XCTAssertEqual(run.snapshot.videoRequest?.frameCount, 9); XCTAssertEqual(run.snapshot.videoRequest?.fps, 8)
        let installed = try await library.installedModels()
        XCTAssertEqual(installed.first?.inferenceVerified, true)
        let animaticProbe = try await VideoProbe.inspect(animaticURL)
        // Four 0.5 s holds plus the last frame's 0.5 s final hold: 20 samples, last frame at 2.375 s.
        XCTAssertEqual(animaticProbe.frameCount, 20); XCTAssertEqual(animaticProbe.duration, 2.5, accuracy: 0.01); XCTAssertEqual(animaticProbe.lastFrameTimestamp, 2.375, accuracy: 0.01)
        let assembledProbe = try await VideoProbe.inspect(assembled)
        XCTAssertEqual(assembledProbe.duration, 3.625, accuracy: 0.15)
        XCTAssertFalse(assembledProbe.hasAudio, "Neither input has audio, so no audio track is invented")

        let reopened = try await StudioPersistence(root: root).loadExecutionArtifacts()
        XCTAssertEqual(reopened.first?.values[.init(nodeID: t2v.id, portID: "video")], .video(generated))
        let provenance = try XCTUnwrap(reopened.first?.mediaProvenance?[t2v.id])

        if let evidencePath = environment["WAN_EVIDENCE_DIR"] {
            let evidence = URL(fileURLWithPath: evidencePath)
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            for (url, name) in [(generated, "wan-t2v-320x192-9f-8fps.mov"), (animaticURL, "animatic-5-stills-8fps.mov"), (assembled, "assembled-t2v-plus-animatic.mov")] {
                let target = evidence.appending(path: name); try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: generated)); generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for index in [0, 4, 8] {
                let image = try await generator.image(at: CMTime(value: Int64(index), timescale: 8)).image
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(evidence.appending(path: "wan-frame-\(index).png") as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            struct Report: Encodable {
                let recordedAt: Date; let machine: String; let importSeconds: Double; let wallSecondsForGraph: Double; let adapterSeconds: Double?
                let request: VideoGenerationRequest?; let generated: VideoProbeSummary; let animatic: VideoProbeSummary; let assembled: VideoProbeSummary
                let outputSHA256: String; let stages: [String]
            }
            let hardware = HardwareProfile.current()
            let report = Report(recordedAt: Date(), machine: "\(hardware.chip), \(hardware.memoryBytes / 1_073_741_824) GB, \(hardware.osVersion)", importSeconds: importSeconds, wallSecondsForGraph: wallSeconds, adapterSeconds: provenance.elapsedSeconds, request: run.snapshot.videoRequest,
                                generated: .init(probe), animatic: .init(animaticProbe), assembled: .init(assembledProbe), outputSHA256: provenance.output.sha256, stages: await stages.unique())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: evidence.appending(path: "wan-t2v-integration.json"))
        }
    }
}

struct VideoProbeSummary: Encodable {
    let width: Int; let height: Int; let frameCount: Int; let distinctFrames: Int; let duration: Double; let lastFrameTimestamp: Double; let hasAudio: Bool
    init(_ probe: VideoProbe) { width = probe.width; height = probe.height; frameCount = probe.frameCount; distinctFrames = probe.distinctFrameCount; duration = probe.duration; lastFrameTimestamp = probe.lastFrameTimestamp; hasAudio = probe.hasAudio }
}

actor StageLog {
    private var stages: [String] = []
    func add(_ stage: String) { stages.append(stage) }
    func unique() -> [String] { stages.reduce(into: []) { if $0.last != $1 { $0.append($1) } } }
}
