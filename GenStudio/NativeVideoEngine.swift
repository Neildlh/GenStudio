import Foundation

struct GeneratedVideo: Sendable {
    /// Encoded, decoded-and-validated clip in scratch space; the executor retains it.
    let url: URL
    let probe: VideoProbe
    let elapsedSeconds: Double
    /// Bounded engine log tail retained with the run for diagnosis.
    let logTail: String
}

protocol VideoGenerationEngine: Sendable {
    func generate(_ request: VideoGenerationRequest) async throws -> GeneratedVideo
}

/// LingBot's pinned runtime guide uses a JSON caption contract rather than an unstructured
/// sentence. Keep the node simple for users: wrap ordinary text deterministically, without a
/// network/LLM call, and preserve an explicitly-authored valid LingBot payload unchanged.
enum LingBotPromptFormatter {
    private static func hasRootKey(_ key: String, in text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object[key] != nil
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let value = String(data: data, encoding: .utf8) else {
            throw StudioError.validation("LingBot's structured prompt could not be encoded as UTF-8.")
        }
        return value
    }

    /// Accept a local text model's JSON-only response, tolerating the common fenced-code wrapper.
    static func validatedCaption(from response: String) -> String? {
        var candidate = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            let lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 { candidate = lines.dropFirst().dropLast().joined(separator: "\n") }
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasRootKey("caption", in: candidate) ? candidate : nil
    }

    static func positive(_ text: String, task: VideoTask) throws -> String {
        if hasRootKey("caption", in: text) { return text }
        let description = task == .imageToVideo
            ? "Preserve the supplied first frame's subjects, identity, composition, lighting and style. Animate it naturally: \(text)"
            : text
        return try encode(["caption": [
            "comprehensive_description": description,
            "camera_info": [
                "color": "Natural", "frame_size": "Match source", "shot_type_angle": "Match source",
                "lens_size": "Natural lens", "composition": "Preserve composition",
                "lighting": "Preserve lighting", "lighting_type": "Match source"
            ],
            "world_knowledge": [],
            "prominent_elements": []
        ]])
    }

    static func negative(_ text: String) throws -> String {
        if hasRootKey("universal_negative", in: text) { return text }
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return try encode(["universal_negative": [
            "visual_quality": items,
            "temporal_and_motion_stability": ["flickering", "jittery", "temporal inconsistency", "warping", "morphing", "incoherent motion"]
        ]])
    }
}

/// Exact sd-cli argument mapping for the pinned Wan2.1 T2V 1.3B recipe (kept byte-identical to the proven adapter). Pure, so it can be tested without weights.
enum WanTextToVideoCommand {
    struct Components: Sendable { let diffusion: URL; let textEncoder: URL; let vae: URL }

    static func arguments(_ request: VideoGenerationRequest, components: Components, framePattern: URL) throws -> [String] {
        guard request.task == .textToVideo, request.recipeID == VideoCapabilityRegistry.wanT2VRecipeID else {
            throw StudioError.validation("The Wan2.1 T2V 1.3B adapter only runs text-to-video. It never substitutes for \(request.task.title).")
        }
        guard request.mediaInputs.isEmpty else { throw StudioError.validation("Text to Video does not accept image or video inputs.") }
        var arguments: [String] = ["-M", "vid_gen"]
        arguments += ["--diffusion-model", components.diffusion.path, "--t5xxl", components.textEncoder.path, "--vae", components.vae.path]
        let positivePrompt = request.compiledPrompt ?? request.prompt
        try EnginePromptSyntax.validate(positivePrompt, request.negativePrompt)
        arguments += ["-p", positivePrompt, "-n", request.negativePrompt]
        arguments += ["-W", String(request.width), "-H", String(request.height), "--steps", String(request.steps)]
        arguments += ["--cfg-scale", String(request.cfgScale), "--sampling-method", request.sampler]
        arguments += ["--video-frames", String(request.frameCount), "--fps", String(request.fps), "--flow-shift", String(request.flowShift)]
        arguments += ["--diffusion-fa", "--seed", String(request.seed), "-o", framePattern.path]
        return arguments
    }
}

/// Exact sd-cli argument mapping for each video command profile, from the pinned 7f410a3 guides. Pure and weight-free.
enum VideoAdapterCommand {
    static func arguments(_ request: VideoGenerationRequest, capability: VideoCapability, components: [String: URL], framePattern: URL) throws -> [String] {
        guard request.recipeID == capability.recipeID, request.task == capability.task, request.engineBuild == capability.engineBuild else {
            throw StudioError.validation("Recipe \(capability.recipeID) supports \(capability.task.title), not \(request.task.title). GenStudio never substitutes one video contract for another.")
        }
        let roles = capability.command.componentRoles
        guard roles.allSatisfy({ components[$0] != nil }) else { throw StudioError.validation("The installed recipe is missing a required component (\(roles.joined(separator: ", "))).") }
        let allowed = capability.supportedRoles
        guard request.mediaInputs.allSatisfy({ allowed.contains($0.role) }) else { throw StudioError.validation("\(request.task.title) with \(capability.recipeID) cannot use the supplied media roles.") }
        let starts = request.mediaInputs.filter { $0.role == .startImage }
        let ends = request.mediaInputs.filter { $0.role == .endImage }
        let sourceVideos = request.mediaInputs.filter { $0.role == .sourceVideo }
        if capability.requiredRoles.contains(.sourceVideo) {
            guard sourceVideos.count == 1 else { throw StudioError.validation("\(request.task.title) needs exactly one source video.") }
            guard starts.isEmpty, ends.isEmpty else { throw StudioError.validation("\(request.task.title) accepts a source video, not start or end images.") }
        } else {
            if capability.requiredRoles.contains(.startImage) {
                guard starts.count == 1 else { throw StudioError.validation("\(request.task.title) needs exactly one start image.") }
            } else if !request.mediaInputs.isEmpty {
                throw StudioError.validation("\(request.task.title) does not accept image or video inputs.")
            }
        }
        if capability.requiredRoles.contains(.endImage) {
            guard ends.count == 1 else { throw StudioError.validation("\(request.task.title) needs exactly one end image.") }
        } else if !ends.isEmpty {
            throw StudioError.validation("\(request.task.title) does not accept an end image.")
        }
        if capability.command == .wan21TextToVideo {
            return try WanTextToVideoCommand.arguments(request, components: .init(diffusion: components["diffusion"]!, textEncoder: components["textEncoder"]!, vae: components["vae"]!), framePattern: framePattern)
        }
        var arguments = ["-M", "vid_gen"]
        switch capability.command {
        case .wan21TextToVideo: break
        case .mlxFastMetal5:
            throw StudioError.validation("FastMetal requires GenStudio's managed FastVideo MLX backend, not the stable-diffusion.cpp adapter.")
        case .mlxLTX23:
            throw StudioError.validation("LTX-2.3 requires GenStudio's managed native MLX backend, not the stable-diffusion.cpp adapter.")
        case .ltx25:
            arguments += ["--diffusion-model", components["diffusion"]!.path, "--vae", components["vae"]!.path, "--audio-vae", components["audioVae"]!.path, "--llm", components["textEncoder"]!.path]
            // The installed public LTX-2.5 mirror supplies its Gemma 4 encoder as
            // INT8 SafeTensors. The bundled Metal library intentionally has no
            // i8×i8 matmul pipeline on pre-M5 Apple GPUs, so loading this encoder
            // on Metal exits before diffusion begins. Text encoding is a one-time
            // stage; keep it on CPU while diffusion and VAE work remain on Metal.
            arguments += ["--backend", "te=cpu"]
        case .wan21FirstLastFrame:
            arguments += ["--diffusion-model", components["diffusion"]!.path, "--t5xxl", components["textEncoder"]!.path, "--vae", components["vae"]!.path, "--clip_vision", components["clipVision"]!.path]
        case .animateDiffSD15:
            arguments += ["-m", components["checkpoint"]!.path, "--motion-module", components["motionModule"]!.path]
        case .lingBotVideo:
            arguments += ["--diffusion-model", components["diffusion"]!.path, "--llm", components["textEncoder"]!.path, "--vae", components["vae"]!.path]
        case .wan22TI2V:
            arguments += ["--diffusion-model", components["diffusion"]!.path, "--vae", components["vae"]!.path, "--t5xxl", components["textEncoder"]!.path]
        case .minimaxH3:
            // MiniMax-H3 FL2VA/I2VA uses the H3-specific Qwen3-VL encoder.
            // The audio VAE is optional upstream and intentionally omitted here;
            // GenStudio currently retains and validates video frames only.
            arguments += ["--diffusion-model", components["diffusion"]!.path, "--vae", components["vae"]!.path, "--llm", components["textEncoder"]!.path]
        case .minimaxH3Ref2VA:
            // Ref2VA is a separate H3 transformer checkpoint. Its reference
            // video is a directory of lexicographically ordered PNG frames;
            // unlike FL2VA it must not be combined with --init-img/--end-img.
            arguments += ["--diffusion-model", components["diffusion"]!.path, "--vae", components["vae"]!.path, "--llm", components["textEncoder"]!.path]
        }
        try EnginePromptSyntax.validate(request.prompt, request.negativePrompt)
        let authoredOrCompiled = request.compiledPrompt ?? request.prompt
        guard authoredOrCompiled.utf8.count <= VideoRequestPlanner.promptByteLimit else {
            throw StudioError.validation("The locally compiled video prompt exceeded the 16 KB safety limit; the original prompt was kept unchanged.")
        }
        try EnginePromptSyntax.validate(authoredOrCompiled)
        let positivePrompt: String
        let negativePrompt: String
        if capability.command == .lingBotVideo {
            positivePrompt = try LingBotPromptFormatter.positive(authoredOrCompiled, task: request.task)
            negativePrompt = try LingBotPromptFormatter.negative(request.negativePrompt)
        } else {
            // The execution boundary resolves the exact recipe/task prompt contract. Every
            // adapter must consume that result; falling back to the authored sentence here
            // would silently bypass model-specific compilation for Wan and MiniMax.
            positivePrompt = authoredOrCompiled
            negativePrompt = request.negativePrompt
        }
        arguments += ["-p", positivePrompt, "-n", negativePrompt]
        arguments += ["-W", String(request.width), "-H", String(request.height), "--steps", String(request.steps), "--cfg-scale", String(request.cfgScale)]
        if let sampler = capability.sampler { arguments += ["--sampling-method", sampler] }
        if let scheduler = capability.scheduler { arguments += ["--scheduler", scheduler] }
        arguments += ["--video-frames", String(request.frameCount), "--fps", String(request.fps)]
        if capability.usesFlowShift { arguments += ["--flow-shift", String(request.flowShift)] }
        arguments += ["--diffusion-fa", "--seed", String(request.seed)]
        if capability.command == .lingBotVideo || capability.command == .ltx25 { arguments += ["--offload-to-cpu"] }
        if capability.command == .minimaxH3 || capability.command == .minimaxH3Ref2VA { arguments += ["--offload-to-cpu", "--rng", "cpu"] }
        if let start = starts.first {
            arguments += [capability.command == .wan21FirstLastFrame ? "--init-img" : "-i", start.location.path]
            if let bounds = capability.strength {
                guard let strength = request.strength, bounds.contains(strength) else { throw StudioError.validation("\(request.task.title) needs a strength within \(bounds.summary).") }
                arguments += ["--strength", String(strength)]
            }
        }
        if let end = ends.first { arguments += ["--end-img", end.location.path] }
        if let sourceVideo = sourceVideos.first {
            arguments += ["--ref-video", sourceVideo.location.path]
        }
        if capability.command == .wan22TI2V || capability.command == .wan21FirstLastFrame { arguments += ["--offload-to-cpu"] }
        arguments += ["-o", framePattern.path]
        return arguments
    }
}

/// Advisory stage parsing of sd-cli stdout, based on the pinned build's observed log lines.
final class WanProgressParser: @unchecked Sendable {
    enum Stage: Equatable, Sendable { case loading, sampling, decoding, saving }
    private let lock = NSLock()
    private var buffer = ""
    private(set) var stage = Stage.loading
    private let steps: Int
    init(steps: Int) { self.steps = steps }

    /// Returns a progress update when the stage or step changes.
    func consume(_ chunk: String) -> [EngineProgress] {
        lock.withLock {
            buffer += chunk
            var updates: [EngineProgress] = []
            // Progress bars end in carriage returns; log lines end in newlines.
            while let range = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
                let line = String(buffer[..<range.lowerBound]); buffer.removeSubrange(..<range.upperBound)
                if let update = parse(line) { updates.append(update) }
            }
            if buffer.utf8.count > 8192 { buffer = String(buffer.suffix(2048)) }
            return updates
        }
    }

    private func parse(_ line: String) -> EngineProgress? {
        if line.contains("get_learned_condition completed") || line.contains("generate_video ") && stage == .loading && !line.contains("completed") {
            stage = .sampling; return .init(stage: "Sampling 0/\(steps)", fraction: 0)
        }
        if line.contains("sampling completed") { stage = .decoding; return .init(stage: "Decoding frames (VAE)") }
        if line.contains("generate_video completed") { stage = .saving; return .init(stage: "Writing frames") }
        if stage == .sampling, let match = line.range(of: #"\|\s*(\d+)/(\d+)\s"#, options: .regularExpression) {
            let parts = line[match].filter { $0.isNumber || $0 == "/" }.split(separator: "/")
            if parts.count == 2, let done = Int(parts[0]), let total = Int(parts[1]), total == steps, (0...total).contains(done) {
                return .init(stage: "Sampling \(done)/\(total)", fraction: Double(done) / Double(total))
            }
        }
        return nil
    }
}

actor NativeWanVideoEngine: VideoGenerationEngine {
    private let library: ModelLibrary
    private let scratchRoot: URL
    private let resourceRoot: URL?
    private let executableOverride: URL?
    private let timeout: Duration

    private let capabilities: [VideoCapability]

    init(library: ModelLibrary, scratchRoot: URL, resourceRoot: URL? = Bundle.main.resourceURL, executableOverride: URL? = nil, timeout: Duration = .seconds(3600), capabilities: [VideoCapability] = VideoCapabilityRegistry.shipped) {
        self.library = library; self.scratchRoot = scratchRoot; self.resourceRoot = resourceRoot; self.executableOverride = executableOverride; self.timeout = timeout
        self.capabilities = capabilities
    }

    func generate(_ request: VideoGenerationRequest) async throws -> GeneratedVideo {
        if let rejected = VideoCapabilityRegistry.rejectionReason(for: request.recipeID) {
            throw StudioError.validation(rejected)
        }
        guard let capability = VideoCapabilityRegistry.capability(recipeID: request.recipeID, task: request.task, in: capabilities),
              capability.engineBuild == request.engineBuild, capability.frames.contains(request.frameCount),
              capability.width.contains(request.width), capability.height.contains(request.height),
              capability.fps.contains(request.fps), capability.steps.contains(request.steps) else {
            throw StudioError.validation("This request does not match a supported video recipe and task.")
        }
        if case .unavailable(let reason) = capability.readiness {
            // VideoNodeRunner normally catches this during graph preflight. Keep
            // the engine boundary equally strict so a direct caller cannot revive
            // an explicitly disabled, CPU-offloaded adapter.
            throw StudioError.validation(reason)
        }
        let started = ProcessInfo.processInfo.systemUptime
        GenerationProgressContext.report?(.init(stage: "Validating model files"))
        let installed = try await library.resolveInstalledModel(id: request.recipeID)
        var components: [String: URL] = [:]
        for role in capability.command.componentRoles { components[role] = installed.componentURL(role: role) }
        guard installed.kind == .video, installed.engineID == "stable-diffusion.cpp", components.count == capability.command.componentRoles.count else {
            throw StudioError.validation("The installed \(installed.name) recipe is incomplete. Reinstall or re-import all of its components.")
        }
        if capability.command == .wan21FirstLastFrame,
           let source = components["clipVision"],
           let component = installed.components.first(where: { $0.role == "clipVision" }) {
            GenerationProgressContext.report?(.init(stage: "Preparing Wan vision encoder compatibility"))
            components["clipVision"] = try SafeTensorsCompatibility.prepareWanClipVision(
                source: source,
                verifiedSourceSHA256: component.source.sha256
            )
        }
        for input in request.mediaInputs where try MediaIdentity.of(input.location) != input.identity {
            throw StudioError.validation("The \(input.role.rawValue) input changed on disk after it was prepared. Run the workflow again.")
        }
        let executable: URL
        if let executableOverride { executable = executableOverride } else { executable = try NativeRuntime.executable("sd", resourceRoot: resourceRoot) }
        let work = scratchRoot.appending(path: "video-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let pattern = work.appending(path: "frame_%03d.png")
        let arguments = try VideoAdapterCommand.arguments(request, capability: capability, components: components, framePattern: pattern)

        GenerationProgressContext.report?(.init(stage: "Loading model and encoding prompt"))
        NativeRuntime.state("loading", model: request.recipeID); defer { NativeRuntime.state("unloaded", model: request.recipeID) }
        let parser = WanProgressParser(steps: request.steps)
        let report = GenerationProgressContext.report
        let model = request.recipeID
        let result = try await NativeProcessRunner().run(executable: executable, arguments: arguments, timeout: timeout, onOutput: { chunk in
            let updates = parser.consume(chunk)
            if !updates.isEmpty { NativeRuntime.state("running", model: model) }
            for update in updates { report?(update) }
        })
        try Task.checkCancellation()
        var tail = String((result.stdout + "\n" + result.stderr).suffix(6000))
        // The pinned build logs a nonfatal GGUF tensor-info [ERROR]; exit status plus decoded output decide success.
        guard result.status == 0 else { throw StudioError.validation("Local video generation failed (exit \(result.status)): \(result.stderr.suffix(1500)) \(result.stdout.suffix(600))") }
        let frames = (0..<request.frameCount).map { work.appending(path: String(format: "frame_%03d.png", $0)) }
        guard frames.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }),
              !FileManager.default.fileExists(atPath: work.appending(path: String(format: "frame_%03d.png", request.frameCount)).path) else {
            throw StudioError.validation("The video engine did not write exactly \(request.frameCount) frames.")
        }
        GenerationProgressContext.report?(.init(stage: "Encoding and validating video"))
        let output = work.appending(path: "\(request.task.rawValue).mov")
        try await FrameSequenceEncoder.encode(frames: frames.map { .file($0) }, width: request.width, height: request.height, fps: request.fps, framesPerImage: nil, to: output)
        let probe = try await VideoProbe.inspect(output)
        guard probe.width == request.width, probe.height == request.height, probe.frameCount == request.frameCount,
              abs(probe.duration - request.duration) < 0.5 / Double(request.fps) else {
            throw StudioError.validation("Encoded video failed validation: expected \(request.width)×\(request.height), \(request.frameCount) frames; decoded \(probe.width)×\(probe.height), \(probe.frameCount) frames.")
        }
        guard probe.distinctFrameCount > 1 else { throw StudioError.validation("Generated frames are identical; the output is not accepted as video.") }
        try Task.checkCancellation()
        // Move the validated clip out of the per-run work directory before it is removed, and before the
        // unrelated model-library bookkeeping below runs. A fully decoded-and-validated render must survive
        // even if that bookkeeping write fails (e.g. a component file vanished after this run already used it).
        let final = scratchRoot.appending(path: "\(UUID().uuidString).mov")
        try FileManager.default.moveItem(at: output, to: final)
        do { try await library.markInferenceVerified(id: request.recipeID, for: request.task) }
        catch { tail += "\n[warning] Local render succeeded and was validated, but recording verification status failed: \(error.localizedDescription)" }
        return .init(url: final, probe: probe, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, logTail: tail)
    }
}
