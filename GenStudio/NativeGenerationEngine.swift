import Foundation
import ImageIO
import Darwin

// Swift 6.2's Darwin overlay resolves `Darwin.flock` to the `flock` struct on
// newer SDKs. Bind the POSIX function explicitly so the cross-process inference
// lease keeps compiling without changing its behavior.
@_silgen_name("flock")
private func systemFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

protocol ImageGenerationEngine: Sendable {
    func generate(_ request: ImageGenerationRequest) async throws -> URL
}

protocol TextGenerationEngine: Sendable {
    func listModels() async throws -> [InstalledModel]
    func generate(prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String
}

extension Notification.Name {
    static let nativeGenerationState = Notification.Name("GenStudio.nativeGenerationState")
}

/// Each invocation owns its process and releases all model/GPU resources on exit.
/// There is deliberately no background server or external application dependency.
enum NativeRuntime {
    static func executable(_ engine: String, resourceRoot: URL? = Bundle.main.resourceURL) throws -> URL {
        guard let engineRoot = LocalRuntimeLibrary.engineRoot(engine, resourceRoot: resourceRoot) else {
            throw StudioError.validation("The local \(engine) engine is not installed. Open Models → Start Here and install the local runtime package.")
        }
        let name = engine == "llama" ? "llama-cli" : "sd-cli"
        let url = engineRoot.appending(path: "bin/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw StudioError.validation("The installed \(engine) engine is damaged. Reinstall the local runtime package from Models → Start Here.")
        }
        return url
    }

    static func state(_ state: String, model: String) {
        NotificationCenter.default.post(name: .nativeGenerationState, object: nil, userInfo: ["modelID": model, "state": state])
    }
}

struct NativeProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let status: Int32
}

/// All blocking process and pipe operations run on worker queues. Cancellation is
/// checked before launch and throughout execution; SIGTERM escalates to SIGKILL.
final class NativeProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// The child sees only the minimal base environment below. `environment` may add named,
    /// engine-specific switches (for example `LTX2_COMPUTE_DTYPE`) but never replaces a base value,
    /// so a caller cannot widen PATH or re-enable the Python user site.
    func run(executable: URL, arguments: [String], timeout: Duration, environment: [String: String] = [:],
             onOutput: @escaping @Sendable (String) -> Void = { _ in }) async throws -> NativeProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        if isCancelled { throw CancellationError() }
                        // The in-process ExecutionQueue prevents overlap in one window, but a user
                        // can have a Debug and packaged GenStudio open simultaneously. Coordinate
                        // only the app-owned inference engines: ffmpeg/utility work is safe to run in
                        // parallel and NativeProcessRunner's unit tests use ordinary system tools.
                        var inferenceLease: Int32?
                        let bundledEngineNames = Set(["sd-cli", "llama-cli", "llama-mtmd-cli", "genstudio-mlx-vlm", "genstudio-fastmetal-5b", "genstudio-ltx-23"])
                        let isAppOwnedInferenceEngine = (executable.path.contains("/LocalRuntimes/")
                            || executable.path.contains("/GenStudio/RuntimeLibrary/Installed/"))
                            && bundledEngineNames.contains(executable.lastPathComponent)
                        if isAppOwnedInferenceEngine {
                            let leasePath = NSTemporaryDirectory() + "genstudio-local-inference-\(getuid()).lock"
                            let lease = Darwin.open(leasePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                            guard lease >= 0 else { throw StudioError.validation("Could not create the local-generation coordination lock.") }
                            guard systemFlock(lease, LOCK_EX | LOCK_NB) == 0 else {
                                _ = Darwin.close(lease)
                                throw StudioError.validation("Another GenStudio process is already using the local CPU/Metal generation engine. Let that render finish or cancel it before starting another local generation.")
                            }
                            inferenceLease = lease
                        }
                        defer {
                            if let inferenceLease {
                                _ = systemFlock(inferenceLease, LOCK_UN)
                                _ = Darwin.close(inferenceLease)
                            }
                        }
                        let process = Process(), stdout = Pipe(), stderr = Pipe()
                        process.executableURL = executable; process.arguments = arguments
                        process.standardInput = FileHandle.nullDevice
                        process.standardOutput = stdout; process.standardError = stderr
                        // No inherited loader overrides, proxy credentials, or model-hub tokens.
                        let base = [
                            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
                            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"
                        ]
                        process.environment = base.merging(environment) { baseValue, _ in baseValue }
                        let out = NativeOutputBuffer(), err = NativeOutputBuffer(), drains = DispatchGroup()
                        try process.run()
                        for (pipe, buffer) in [(stdout, out), (stderr, err)] {
                            drains.enter()
                            DispatchQueue.global(qos: .utility).async {
                                defer { try? pipe.fileHandleForReading.close(); drains.leave() }
                                while true {
                                    let chunk = pipe.fileHandleForReading.availableData
                                    if chunk.isEmpty { break }
                                    buffer.append(chunk)
                                    onOutput(String(decoding: chunk, as: UTF8.self))
                                }
                            }
                        }
                        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                        let deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds)
                        var interruptedAt: Double?, timedOut = false
                        while process.isRunning {
                            let now = ProcessInfo.processInfo.systemUptime
                            if interruptedAt == nil && (isCancelled || now >= deadline) {
                                timedOut = !isCancelled; interruptedAt = now; process.terminate()
                            }
                            if let interruptedAt, now - interruptedAt >= 2, process.isRunning {
                                Darwin.kill(process.processIdentifier, SIGKILL)
                            }
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        process.waitUntilExit()
                        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
                        drains.wait()
                        if isCancelled { throw CancellationError() }
                        if timedOut { throw StudioError.timedOut }
                        continuation.resume(returning: .init(stdout: out.string, stderr: err.string, status: process.terminationStatus))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }
}

private final class NativeOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 512 * 1024
    func append(_ chunk: Data) { lock.withLock { data.append(chunk); if data.count > limit { data.removeFirst(data.count - limit) } } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

private final class NativeRunProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = false
    private var tail = ""
    let model: String
    let report = GenerationProgressContext.report
    let marker: String
    init(model: String, marker: String) { self.model = model; self.marker = marker }
    func consume(_ text: String) {
        let send = lock.withLock {
            tail = String((tail + text).suffix(2048))
            if !emitted && tail.contains(marker) { emitted = true; return true }
            return false
        }
        if send { NativeRuntime.state("running", model: model); report?(.init(stage: "Generating")) }
    }
}

/// stable-diffusion.cpp writes its sampling status as carriage-returned
/// terminal progress lines. Process output arrives in arbitrary chunks, so
/// retain a small tail and parse complete lines only after the generation
/// marker. This prevents model-loading counters such as 243/242 from being
/// shown as sampling progress.
final class StableDiffusionProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private var generating = false
    private var lastStep: Int?
    private var lastTotal: Int?

    func consume(_ chunk: String) -> [EngineProgress] {
        lock.withLock {
            tail.append(chunk)
            let parts = tail.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
            guard !parts.isEmpty else { return [] }
            tail = String(parts.last ?? "")
            return parts.dropLast().compactMap { parse(String($0)) }
        }
    }

    private func parse(_ line: String) -> EngineProgress? {
        if !generating && line.localizedCaseInsensitiveContains("generating image") {
            generating = true
            lastStep = nil
            lastTotal = nil
            return .init(stage: "Sampling", fraction: 0)
        }
        guard generating else { return nil }
        if line.localizedCaseInsensitiveContains("decode") || line.localizedCaseInsensitiveContains("vae") {
            return .init(stage: "Decoding")
        }
        let pattern = #"(?<!\d)(\d+)\s*/\s*(\d+)(?!\d)"#
        guard let match = line.range(of: pattern, options: .regularExpression),
              let values = parsePair(String(line[match])) else { return nil }
        let (step, total) = values
        guard total > 0, step >= 0, step <= total,
              step != lastStep || total != lastTotal else { return nil }
        lastStep = step
        lastTotal = total
        return .init(stage: "Sampling \(step)/\(total)", fraction: Double(step) / Double(total))
    }

    private func parsePair(_ text: String) -> (Int, Int)? {
        let values = text.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 2 else { return nil }
        return (values[0], values[1])
    }
}

actor NativeTextEngine: TextGenerationEngine {
    private let library: ModelLibrary
    private let resourceRoot: URL?
    init(library: ModelLibrary, resourceRoot: URL? = Bundle.main.resourceURL) { self.library = library; self.resourceRoot = resourceRoot }

    func listModels() async throws -> [InstalledModel] {
        try await library.installedModels().filter { $0.kind == .text && $0.available && $0.canAttemptGeneration }.map {
            InstalledModel(name: $0.id, size: nil, digest: nil)
        }
    }

    func generate(prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 32_768,
              temperature.isFinite, (0...2).contains(temperature), (1...4096).contains(maxTokens) else {
            throw StudioError.validation("Use a nonempty prompt up to 32 KB, temperature 0–2 and 1–4096 output tokens.")
        }
        GenerationProgressContext.report?(.init(stage: "Validating model files"))
        let installed = try await library.resolveInstalledModel(id: model)
        if installed.engineID == MLXVLMRuntime.engineID {
            return try await MLXVLMRuntime.generate(library: library, modelID: model, prompt: prompt, images: [], temperature: temperature, maxTokens: maxTokens, timeout: timeout)
        }
        let experimental = installed.id.hasPrefix("text-gguf-") || installed.recipeSnapshot?.baseRecipeID == "qwen25-05b-q4km"
        guard (installed.id == "qwen25-05b-q4km" || experimental), installed.kind == .text, installed.engineID == "llama.cpp",
              let weights = installed.componentURL(role: "model") else {
            throw StudioError.validation("This text model has no verified runtime recipe in GenStudio.")
        }
        let executable = try NativeRuntime.executable("llama", resourceRoot: resourceRoot)
        GenerationProgressContext.report?(.init(stage: "Loading model"))
        NativeRuntime.state("loading", model: model); defer { NativeRuntime.state("unloaded", model: model) }
        let progress = NativeRunProgress(model: model, marker: "generate: n_ctx")
        if experimental { try GGUFTextInspector.validate(weights) }
        let formatted = experimental ? prompt : "<|im_start|>user\n\(prompt)\n<|im_end|>\n<|im_start|>assistant\n"
        let mode = experimental ? ["--jinja", "--conversation", "--single-turn", "--simple-io"] : ["--no-conversation"]
        let result = try await NativeProcessRunner().run(executable: executable, arguments: ["-m", weights.path, "-p", formatted,
            "-n", String(maxTokens), "--temp", String(temperature), "-c", "8192", "--no-display-prompt", "--no-warmup"] + mode, timeout: timeout, onOutput: { progress.consume($0) })
        guard result.status == 0 else { throw StudioError.validation("Local text generation failed (\(result.status)): \(result.stderr.suffix(1800))") }
        var text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("[end of text]") { text = String(text.dropLast("[end of text]".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !text.isEmpty else { throw StudioError.emptyResponse }
        try await library.markInferenceVerified(id: model)
        return text
    }
}

actor NativeImageEngine: ImageGenerationEngine {
    private let library: ModelLibrary
    private let outputRoot: URL
    private let resourceRoot: URL?
    private let capabilities: [ImageCapability]
    init(library: ModelLibrary, outputRoot: URL, resourceRoot: URL? = Bundle.main.resourceURL, capabilities: [ImageCapability] = ImageCapabilityRegistry.shipped) {
        self.library = library; self.outputRoot = outputRoot; self.resourceRoot = resourceRoot; self.capabilities = capabilities
    }

    func generate(_ request: ImageGenerationRequest) async throws -> URL {
        if request.task == .textToImage, !request.referenceImages.isEmpty {
            throw StudioError.validation("Text to image does not accept reference images. Disconnect the reference image(s) to run it, or choose a recipe with an image-to-image adapter.")
        }
        let installedForProfile = try? await library.installedModels().first(where: { $0.id == request.recipeID })?.recipeSnapshot
        guard let capability = ImageCapabilityRegistry.capability(recipeID: request.recipeID, task: request.task, in: capabilities)
                ?? installedForProfile.flatMap({ ImageCapabilityRegistry.userCapability(recipe: $0, task: request.task) }) else {
            throw StudioError.validation("Recipe \(request.recipeID) has no \(request.task.title.lowercased()) adapter in GenStudio.")
        }
        // Proof is a label, not a permission: an adapter-backed route runs on first use and
        // records its own proof from the decoded result. Only a withdrawn route is blocked.
        if case .unavailable(let reason) = capability.readiness {
            throw StudioError.validation(reason)
        }
        guard capability.engineBuild == request.engineBuild, capability.width.contains(request.width), capability.height.contains(request.height),
              !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.prompt.utf8.count <= 32_768,
              request.seed >= 0, request.seed <= Int(UInt32.max), request.steps == capability.steps, request.cfgScale == capability.cfgScale, request.sampler == capability.sampler else {
            throw StudioError.validation("Use a nonempty prompt up to 32 KB, dimensions \(capability.width.summary) × \(capability.height.summary), and a seed from 0 to 4294967295.")
        }
        try ImageRequestPlanner.validateReferenceCount(request.referenceImages.count, capability: capability)
        let references = request.referenceImages, identities = request.referenceIdentities
        guard references.count == identities.count else {
            throw StudioError.validation("Reference image provenance is incomplete. Run the workflow again.")
        }
        for (reference, identity) in zip(references, identities) {
            guard try MediaIdentity.of(reference) == identity else {
                throw StudioError.validation("A reference image changed on disk after it was prepared. Run the workflow again.")
            }
        }
        GenerationProgressContext.report?(.init(stage: "Validating model files"))
        let installed = try await library.resolveInstalledModel(id: request.recipeID)
        var components: [String: URL] = [:]
        for role in capability.command.componentRoles { components[role] = installed.componentURL(role: role) }
        guard installed.kind == .image, installed.engineID == "stable-diffusion.cpp", components.count == capability.command.componentRoles.count else {
            throw StudioError.validation("The installed \(installed.name) recipe is incomplete. Reinstall or re-import all of its components.")
        }
        let executable = try NativeRuntime.executable("sd", resourceRoot: resourceRoot)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let output = outputRoot.appending(path: "\(UUID().uuidString).png")
        let arguments = try ImageAdapterCommand.arguments(request, capability: capability, components: components, output: output)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: output) } }
        GenerationProgressContext.report?(.init(stage: "Loading model"))
        NativeRuntime.state("loading", model: request.recipeID); defer { NativeRuntime.state("unloaded", model: request.recipeID) }
        let progress = StableDiffusionProgressParser()
        let report = GenerationProgressContext.report
        let engineStarted = ProcessInfo.processInfo.systemUptime
        let result = try await NativeProcessRunner().run(executable: executable, arguments: arguments, timeout: .seconds(3600), onOutput: { chunk in
            for update in progress.consume(chunk) { report?(update) }
        })
        EngineRunLog.record?(ProcessInfo.processInfo.systemUptime - engineStarted, String((result.stdout + "\n" + result.stderr).suffix(4_000)))
        guard result.status == 0 else { throw StudioError.validation("Local image generation failed (\(result.status)): \(result.stderr.suffix(1800)) \(result.stdout.suffix(800))") }
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == request.width, image.height == request.height else {
            throw StudioError.validation("The image engine did not return a valid PNG at the requested dimensions.")
        }
        try Task.checkCancellation()
        // A decoded render is the proof for this exact recipe/task. Do not turn
        // a successful image into a failed run merely because registry
        // bookkeeping could not be written after the output was validated.
        try? await library.markImageInferenceVerified(id: request.recipeID, for: request.task)
        success = true
        return output
    }
}
