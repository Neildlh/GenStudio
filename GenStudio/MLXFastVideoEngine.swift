import Foundation
import CryptoKit

/// App-owned FastVideo MLX backend. It accepts only the exact, pinned
/// FastMetal-5B T2V package and its matching launcher; no model-family or
/// user-Python fallback is permitted at this boundary.
actor MLXFastVideoEngine: VideoGenerationEngine {
    private let library: ModelLibrary
    private let scratchRoot: URL
    private let resourceRoot: URL?
    private let launcherOverride: URL?
    private let timeout: Duration
    private let capabilities: [VideoCapability]

    init(library: ModelLibrary, scratchRoot: URL, resourceRoot: URL? = Bundle.main.resourceURL, launcherOverride: URL? = nil, timeout: Duration = .seconds(900), capabilities: [VideoCapability] = VideoCapabilityRegistry.shipped) {
        self.library = library; self.scratchRoot = scratchRoot; self.resourceRoot = resourceRoot
        self.launcherOverride = launcherOverride; self.timeout = timeout; self.capabilities = capabilities
    }

    func generate(_ request: VideoGenerationRequest) async throws -> GeneratedVideo {
        guard let capability = VideoCapabilityRegistry.capability(recipeID: request.recipeID, task: request.task, in: capabilities),
              capability.engineID == "mlx-fastvideo", capability.engineBuild == request.engineBuild,
              capability.command == .mlxFastMetal5, capability.width.contains(request.width), capability.height.contains(request.height),
              capability.frames.contains(request.frameCount), capability.fps.contains(request.fps), capability.steps.contains(request.steps) else {
            throw StudioError.validation("This request does not match a supported FastVideo MLX recipe and task.")
        }
        if case .unavailable(let reason) = capability.readiness { throw StudioError.validation(reason) }
        guard request.task == .textToVideo, request.mediaInputs.isEmpty else {
            throw StudioError.validation("FastMetal 5B is text-to-video only in this GenStudio build. It does not accept image or video inputs.")
        }
        try await ManagedMLXRuntime.checkEnvironment(family: .fastVideo, resourceRoot: resourceRoot)
        let started = ProcessInfo.processInfo.systemUptime
        GenerationProgressContext.report?(.init(stage: "Validating FastMetal model files"))
        let installed = try await library.resolveInstalledModel(id: request.recipeID)
        guard installed.kind == .video, installed.engineID == "mlx-fastvideo", installed.recipeSnapshot?.runtimeProfile == "mlx-fastvideo",
              Set(installed.components.map(\.source.filename)).isSuperset(of: ["mlx_dit.json", "mlx_dit.safetensors", "text_encoder/config.json", "vae/config.json"]) else {
            throw StudioError.validation("The installed FastMetal package is incomplete. Reinstall the complete pinned package from Model Library.")
        }
        let modelRoot = installed.components[0].fileURL.deletingLastPathComponent()
        let launcher = try launcherOverride ?? ManagedMLXRuntime.launcher(named: "genstudio-fastmetal-5b", family: .fastVideo, resourceRoot: resourceRoot)
        let work = scratchRoot.appending(path: "fastmetal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let output = work.appending(path: "generated.mp4")
        let metrics = work.appending(path: "metrics.json")
        let cacheRoot = library.root.deletingLastPathComponent().appending(path: "RuntimeCache/FastVideo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try EnginePromptSyntax.validate(request.compiledPrompt ?? request.prompt, request.negativePrompt)
        let arguments = Self.arguments(request, modelRoot: modelRoot, output: output, metrics: metrics, cacheRoot: cacheRoot)
        NativeRuntime.state("loading", model: request.recipeID)
        defer { NativeRuntime.state("unloaded", model: request.recipeID) }
        let estimate = VideoCapabilityRegistry.capability(recipeID: request.recipeID, task: request.task)
            .flatMap { capability -> String? in
                var settings = capability.recommended
                settings.width = request.width; settings.height = request.height
                settings.frameCount = request.frameCount; settings.fastDraft = request.fastDraft
                return VideoTimeEstimate.seconds(settings, capability: capability).map(VideoTimeEstimate.label)
            }
        let parser = FastMetalProgressParser(fastDraft: request.fastDraft == true, estimate: estimate)
        let report = GenerationProgressContext.report
        report?(.init(stage: "Encoding the prompt and loading FastMetal"))
        let model = request.recipeID
        let (result, retried) = try await MLXGPUWatchdog.run {
            try? FileManager.default.removeItem(at: output)
            return try await NativeProcessRunner().run(executable: launcher, arguments: arguments, timeout: timeout, onOutput: { chunk in
                NativeRuntime.state("running", model: model)
                for update in parser.consume(chunk) { report?(update) }
            })
        }
        try Task.checkCancellation()
        var tail = String((result.stdout + "\n" + result.stderr).suffix(6_000))
        if retried { tail += "\n" + MLXGPUWatchdog.retryNote }
        guard result.status == 0 else {
            throw StudioError.validation("FastMetal local generation failed (exit \(result.status)): \(result.stderr.suffix(1_500))")
        }
        guard FileManager.default.isReadableFile(atPath: output.path) else {
            throw StudioError.validation("FastMetal completed without writing its declared MP4 output.")
        }
        GenerationProgressContext.report?(.init(stage: "Decoding and validating FastMetal video"))
        let probe = try await VideoProbe.inspect(output)
        guard probe.width == request.width, probe.height == request.height, probe.frameCount == request.frameCount,
              abs(probe.duration - request.duration) < 0.5 / Double(request.fps), probe.distinctFrameCount > 1 else {
            throw StudioError.validation("FastMetal output failed decode validation: expected \(request.width)×\(request.height), \(request.frameCount) distinct frames; decoded \(probe.width)×\(probe.height), \(probe.frameCount) frames.")
        }
        let final = scratchRoot.appending(path: "\(UUID().uuidString).mp4")
        try FileManager.default.moveItem(at: output, to: final)
        do { try await library.markInferenceVerified(id: request.recipeID, for: request.task) }
        catch { tail += "\n[warning] Render was validated but verification metadata could not be recorded: \(error.localizedDescription)" }
        return .init(url: final, probe: probe, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, logTail: tail)
    }
}

/// Dispatches by exact engine id. Adding an engine does not make its models
/// compatible with an existing engine, and saved workflows retain that check.
struct LocalVideoEngineRouter: VideoGenerationEngine {
    let stableDiffusion: any VideoGenerationEngine
    let fastVideo: any VideoGenerationEngine
    let ltx: any VideoGenerationEngine

    func generate(_ request: VideoGenerationRequest) async throws -> GeneratedVideo {
        guard let capability = VideoCapabilityRegistry.capability(recipeID: request.recipeID, task: request.task) else {
            throw StudioError.validation("No local video backend is registered for this exact recipe and task.")
        }
        switch capability.engineID {
        case "stable-diffusion.cpp": return try await stableDiffusion.generate(request)
        case "mlx-fastvideo": return try await fastVideo.generate(request)
        case "mlx-ltx": return try await ltx.generate(request)
        default: throw StudioError.validation("The \(capability.engineID) video backend is not installed in this GenStudio build.")
        }
    }
}

extension MLXFastVideoEngine {
    /// The UMT5 prompt embedding depends only on the recipe and the prompt text, not on the seed,
    /// so every fresh-seed take of the same prompt reuses it instead of re-encoding (about 37 s
    /// of CPU time per take at 1280×704 on the M1 Max reference machine).
    static func promptCache(recipeID: String, prompt: String, cacheRoot: URL) -> URL {
        let digest = SHA256.hash(data: Data((recipeID + "\u{0}" + prompt).utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheRoot.appending(path: "prompt-\(digest.prefix(32)).npy")
    }

    /// Exact upstream FastMetal-5B arguments. `--fast` (fast draft) denoises every second frame and
    /// RIFE-interpolates the rest with the runtime's bundled RIFE 4.25 weights: about 2× faster,
    /// slightly softer, and still exactly `frameCount` frames at `fps`.
    static func arguments(_ request: VideoGenerationRequest, modelRoot: URL, output: URL, metrics: URL, cacheRoot: URL) -> [String] {
        let positive = request.compiledPrompt ?? request.prompt
        var arguments = [
            "--prompt", positive, "--output-path", output.path,
            "--mlx-checkpoint", modelRoot.path, "--text-encoder-root", modelRoot.path,
            "--vae-root", modelRoot.appending(path: "vae").path,
            "--height", String(request.height), "--width", String(request.width),
            "--num-frames", String(request.frameCount), "--fps", String(request.fps),
            "--seed", String(request.seed), "--dmd-denoising-steps", "1000,757,522",
            "--text-encoder-device", "cpu", "--decode-backend", "taehv",
            "--prompt-embeds-cache", promptCache(recipeID: request.recipeID, prompt: positive, cacheRoot: cacheRoot).path,
            "--metrics-json", metrics.path
        ]
        if request.fastDraft == true { arguments.append("--fast") }
        return arguments
    }
}

/// Stage reporting for FastMetal's own status lines. The script prints nothing while it denoises, so the
/// stage names the work in progress and, where this Mac has measurements, how long the take should take.
/// No fraction is invented from elapsed time.
final class FastMetalProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let fastDraft: Bool
    private let estimate: String?

    init(fastDraft: Bool, estimate: String?) { self.fastDraft = fastDraft; self.estimate = estimate }

    func consume(_ chunk: String) -> [EngineProgress] {
        lock.withLock {
            buffer += chunk
            var updates: [EngineProgress] = []
            while let range = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
                let line = String(buffer[..<range.lowerBound]); buffer.removeSubrange(..<range.upperBound)
                if let stage = stage(for: line) { updates.append(.init(stage: stage)) }
            }
            if buffer.utf8.count > 8192 { buffer = String(buffer.suffix(2048)) }
            return updates
        }
    }

    private func stage(for line: String) -> String? {
        if line.hasPrefix("[5B] prompt encoded") {
            if fastDraft { return "Denoising 3 steps (fast draft)" + (estimate.map { " · this take \($0) on this Mac" } ?? "") }
            return "Denoising 3 steps" + (estimate.map { " · this take \($0) on this Mac" } ?? "")
        }
        if line.hasPrefix("[5B] denoise ") { return fastDraft ? "Decoding and interpolating frames" : "Decoding frames" }
        if line.hasPrefix("[5B] decoded via") { return "Writing video" }
        return nil
    }
}
