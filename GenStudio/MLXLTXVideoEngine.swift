import Foundation

/// Native Apple-Silicon LTX-2.3 backend. This boundary accepts only the exact
/// Q4 recipe (with or without its pinned sound decoder) and the pinned app-owned MLX launcher. It never resolves
/// a Hub model id and therefore cannot silently download or fall back to CPU.
actor MLXLTXVideoEngine: VideoGenerationEngine {
    /// Runs the DiT's attention and feed-forward in float16 (ltx-2-mlx ≥ 0.16.0). The M1
    /// generation has no native bfloat16; upstream measured an M1 Max distilled render at
    /// 701 s → 563 s, and the residual stream and AdaLN modulation stay in float32.
    static let processEnvironment = ["LTX2_COMPUTE_DTYPE": "float16"]

    private let library: ModelLibrary
    private let scratchRoot: URL
    private let resourceRoot: URL?
    private let launcherOverride: URL?
    private let timeout: Duration
    private let capabilities: [VideoCapability]

    init(library: ModelLibrary, scratchRoot: URL, resourceRoot: URL? = Bundle.main.resourceURL,
         launcherOverride: URL? = nil, timeout: Duration = .seconds(7_200),
         capabilities: [VideoCapability] = VideoCapabilityRegistry.shipped) {
        self.library = library
        self.scratchRoot = scratchRoot
        self.resourceRoot = resourceRoot
        self.launcherOverride = launcherOverride
        self.timeout = timeout
        self.capabilities = capabilities
    }

    func generate(_ request: VideoGenerationRequest) async throws -> GeneratedVideo {
        guard let capability = VideoCapabilityRegistry.capability(recipeID: request.recipeID, task: request.task, in: capabilities),
              capability.engineID == "mlx-ltx", capability.engineBuild == request.engineBuild,
              capability.command == .mlxLTX23, capability.width.contains(request.width),
              capability.height.contains(request.height), capability.frames.contains(request.frameCount),
              capability.fps.contains(request.fps), capability.steps.contains(request.steps) else {
            throw StudioError.validation("This request does not match a supported native LTX MLX recipe and task.")
        }
        if case .unavailable(let reason) = capability.readiness { throw StudioError.validation(reason) }

        let startImages = request.mediaInputs.filter { $0.role == .startImage }
        switch request.task {
        case .textToVideo:
            guard request.mediaInputs.isEmpty else { throw StudioError.validation("LTX text-to-video does not accept media inputs.") }
        case .imageToVideo:
            guard startImages.count == 1, request.mediaInputs.count == 1 else {
                throw StudioError.validation("LTX image-to-video requires exactly one connected start image.")
            }
            guard FileManager.default.isReadableFile(atPath: startImages[0].location.path) else {
                throw StudioError.validation("The connected LTX start image is no longer readable.")
            }
        case .firstLastFrame:
            let endImages = request.mediaInputs.filter { $0.role == .endImage }
            guard startImages.count == 1, endImages.count == 1, request.mediaInputs.count == 2 else {
                throw StudioError.validation("LTX start/end video needs exactly one connected start image and one end image.")
            }
            guard (startImages + endImages).allSatisfy({ FileManager.default.isReadableFile(atPath: $0.location.path) }) else {
                throw StudioError.validation("A connected LTX start or end image is no longer readable.")
            }
        default:
            throw StudioError.validation("This LTX build supports text-to-video, image-to-video and start/end-frame video.")
        }

        try await ManagedMLXRuntime.checkEnvironment(family: .ltx, resourceRoot: resourceRoot)
        GenerationProgressContext.report?(.init(stage: "Validating LTX model files"))
        let installed = try await library.resolveInstalledModel(id: request.recipeID)
        guard installed.kind == .video, installed.engineID == "mlx-ltx",
              let package = installed.recipeSnapshot, MLXVideoModelCatalog.isLTX23Package(package),
              Set(installed.components.map(\.source.filename)) == Set(package.components.map(\.filename)),
              let rootComponent = installed.components.first(where: { $0.source.filename == "config.json" }) else {
            throw StudioError.validation("The installed LTX package is incomplete or does not match the pinned Q4 recipe. Reinstall it from Model Library.")
        }
        let modelRoot = rootComponent.fileURL.deletingLastPathComponent()
        let gemmaRoot = modelRoot.appending(path: "gemma", directoryHint: .isDirectory)
        guard FileManager.default.isReadableFile(atPath: gemmaRoot.appending(path: "config.json").path) else {
            throw StudioError.validation("The installed LTX package is missing its pinned Gemma text encoder.")
        }

        let launcher: URL
        if let launcherOverride { launcher = launcherOverride }
        else { launcher = try ManagedMLXRuntime.launcher(named: "genstudio-ltx-23", family: .ltx, resourceRoot: resourceRoot) }
        let work = scratchRoot.appending(path: "ltx-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let output = work.appending(path: "generated.mp4")
        let positive = request.compiledPrompt ?? request.prompt
        try EnginePromptSyntax.validate(positive, "")

        let packageHasSound = MLXVideoModelCatalog.hasSound(package)
        let makesSound = Self.audioArguments(soundRequested: request.sound == true, packageHasSound: packageHasSound).isEmpty
        var arguments = ["generate", "--distilled"] + Self.audioArguments(soundRequested: request.sound == true, packageHasSound: packageHasSound) + [
            "--prompt", positive, "--output", output.path,
            "--model", modelRoot.path, "--gemma", gemmaRoot.path,
            "--height", String(request.height), "--width", String(request.width),
            "--frames", String(request.frameCount), "--frame-rate", String(request.fps),
            "--seed", String(request.seed), "--stage1-steps", String(request.steps), "--stage2-steps", "3"
        ]
        arguments += Self.imageArguments(task: request.task, mediaInputs: request.mediaInputs)

        let started = ProcessInfo.processInfo.systemUptime
        NativeRuntime.state("loading", model: request.recipeID)
        defer { NativeRuntime.state("unloaded", model: request.recipeID) }
        let progress = LTXProgressReporter(model: request.recipeID)
        let (result, retried) = try await MLXGPUWatchdog.run {
            try? FileManager.default.removeItem(at: output)
            return try await NativeProcessRunner().run(executable: launcher, arguments: arguments, timeout: timeout,
                                                       environment: Self.processEnvironment) { chunk in
                progress.consume(chunk)
            }
        }
        try Task.checkCancellation()
        var tail = String((result.stdout + "\n" + result.stderr).suffix(12_000))
        if retried { tail += "\n" + MLXGPUWatchdog.retryNote }
        if request.sound == true, !packageHasSound {
            tail += "\n[note] Rendered without sound: this LTX-2.3 package has no sound decoder yet. Add Sound Files in Models (365 MB) to keep LTX sound."
        }
        guard result.status == 0 else {
            throw StudioError.validation("Native LTX MLX generation failed (exit \(result.status)): \(result.stderr.suffix(2_000))")
        }
        guard FileManager.default.isReadableFile(atPath: output.path) else {
            throw StudioError.validation("Native LTX MLX completed without writing its declared MP4 output.")
        }

        GenerationProgressContext.report?(.init(stage: "Decoding and validating LTX video"))
        let probe = try await VideoProbe.inspect(output)
        guard probe.width == request.width, probe.height == request.height,
              probe.frameCount == request.frameCount, abs(probe.nominalFPS - Double(request.fps)) < 0.1,
              probe.distinctFrameCount > 1 else {
            throw StudioError.validation("LTX output failed decode validation: expected \(request.width)×\(request.height), \(request.frameCount) moving frames at \(request.fps) fps; decoded \(probe.width)×\(probe.height), \(probe.frameCount) frames with \(probe.distinctFrameCount) distinct frames.")
        }
        guard probe.hasAudio == makesSound else {
            throw StudioError.validation(makesSound ? "LTX finished without the sound track it was asked to make." : "LTX wrote a sound track to a clip that was set to silent.")
        }
        let final = scratchRoot.appending(path: "\(UUID().uuidString).mp4")
        try FileManager.default.moveItem(at: output, to: final)
        do { try await library.markInferenceVerified(id: request.recipeID, for: request.task) }
        catch { tail += "\n[warning] Render was validated but verification metadata could not be recorded: \(error.localizedDescription)" }
        return .init(url: final, probe: probe,
                     elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, logTail: tail)
    }
}

private final class LTXProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private let model: String
    init(model: String) { self.model = model }

    func consume(_ chunk: String) {
        let stage = lock.withLock { () -> String? in
            tail = String((tail + chunk).suffix(2_000))
            if tail.contains("[Encoding prompt]") { return "Encoding LTX prompt" }
            if tail.contains("[Loading transformer") { return "Loading LTX transformer" }
            if tail.contains("Decoding video + audio") { return "Decoding LTX video and sound" }
            if tail.contains("[Loading decoders") { return "Decoding LTX video" }
            if tail.contains("Stage 2") { return "Refining LTX video" }
            return nil
        }
        if let stage {
            NativeRuntime.state("running", model: model)
            GenerationProgressContext.report?(.init(stage: stage))
        }
    }
}

extension MLXLTXVideoEngine {
    /// LTX-2.3's transformer always denoises sound jointly with the picture; `--no-audio` only skips loading the
    /// 365 MB sound decoder and muxing the track. Sound is decoded when the clip asks for it and the package has it.
    static func audioArguments(soundRequested: Bool, packageHasSound: Bool) -> [String] {
        soundRequested && packageHasSound ? [] : ["--no-audio"]
    }

    /// Image conditioning for the distilled pipeline. Image-to-video keeps its single start image (frame 0,
    /// full strength). Start/end video pins the start image to frame 0 and the end image to the last frame
    /// (`last`, ltx-2-mlx ≥ 0.16), both at full strength.
    static func imageArguments(task: VideoTask, mediaInputs: [VideoMediaInput]) -> [String] {
        let start = mediaInputs.first { $0.role == .startImage }?.location.path
        let end = mediaInputs.first { $0.role == .endImage }?.location.path
        switch task {
        case .imageToVideo:
            return start.map { ["--image", $0] } ?? []
        case .firstLastFrame:
            guard let start, let end else { return [] }
            return ["--image", start, "0", "1.0", "--image", end, "last", "1.0"]
        default:
            return []
        }
    }
}
