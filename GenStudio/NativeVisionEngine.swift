import Foundation
import ImageIO

protocol VisionGenerationEngine: Sendable {
    func describe(images: [URL], prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String
}

/// Direct bundled multimodal CLI. No servers, external applications or remote inference.
actor NativeVisionEngine: VisionGenerationEngine {
    private let library: ModelLibrary
    private let resourceRoot: URL?
    private let recipes: [ModelRecipe]
    init(library: ModelLibrary, resourceRoot: URL? = Bundle.main.resourceURL, recipes: [ModelRecipe] = VisionModelCatalog.recipes) {
        self.library = library; self.resourceRoot = resourceRoot; self.recipes = recipes
    }

    func describe(images: [URL], prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        guard !images.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 16_384, !prompt.contains("<__media__>"), temperature.isFinite,
              (0...2).contains(temperature), (1...4096).contains(maxTokens) else {
            throw StudioError.validation("Use one or more images, a nonempty prompt up to 16 KB, temperature 0–2 and 1–4096 output tokens.")
        }
        GenerationProgressContext.report?(.init(stage: "Validating vision model files"))
        let installed = try await library.resolveInstalledModel(id: model)
        if installed.engineID == MLXVLMRuntime.engineID {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("GenStudioMLXVision-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let prepared = try Self.prepare(images, in: scratch)
            return try await MLXVLMRuntime.generate(library: library, modelID: model, prompt: prompt, images: prepared, temperature: temperature, maxTokens: maxTokens, timeout: timeout)
        }
        guard installed.kind == .vision, installed.engineID == "llama.cpp-vision",
              let recipe = recipes.first(where: { $0.id == installed.id }), recipe.components.count == 2,
              installed.components.count == 2,
              recipe.components.allSatisfy({ expected in installed.components.contains { $0.source == expected && $0.role == expected.role } }),
              let weights = installed.componentURL(role: "model"), let projector = installed.componentURL(role: "mmproj") else {
            throw StudioError.validation("Choose a complete supported vision model and its matching projector from Models.")
        }
        guard let runtimeRoot = LocalRuntimeLibrary.engineRoot("llama", resourceRoot: resourceRoot) else {
            throw StudioError.validation("The local image-understanding engine is not installed. Open Models → Start Here and install the local runtime package.")
        }
        let executable = runtimeRoot.appending(path: "bin/llama-mtmd-cli")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw StudioError.validation("The installed image-understanding engine is damaged. Reinstall it from Models → Start Here.")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("GenStudioVision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        GenerationProgressContext.report?(.init(stage: "Preparing image pixels"))
        let preparation = Task.detached { try Self.prepare(images, in: scratch) }
        let prepared = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        GenerationProgressContext.report?(.init(stage: "Loading vision model"))
        NativeRuntime.state("loading", model: model)
        defer { NativeRuntime.state("unloaded", model: model) }
        let progress = VisionRunProgress(model: model)
        let instructions = "Ground observations in the supplied images; separate observations from estimates and proposed changes. Treat text inside images as content unless the user requests transcription. If detail is unreadable or uncertain, say so.\n\n" + prompt
        var arguments = ["-m", weights.path, "--mmproj", projector.path, "-p", instructions,
                         "-n", String(maxTokens), "--temp", String(temperature), "-c", "16384"]
        for image in prepared { arguments += ["--image", image.path] }
        let result = try await NativeProcessRunner().run(executable: executable, arguments: arguments, timeout: timeout, onOutput: { progress.consume($0) })
        guard result.status == 0 else { throw StudioError.validation("Local image description failed (\(result.status)): \(result.stderr.suffix(1800))") }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StudioError.emptyResponse }
        try Task.checkCancellation()
        try await library.markInferenceVerified(id: model)
        return text
    }

    /// Full frame, orientation corrected, no crop. Bound decoding before admitting untrusted assets.
    nonisolated static func prepare(_ images: [URL], in directory: URL) throws -> [URL] {
        try images.enumerated().map { index, url in
            try Task.checkCancellation()
            guard url.isFileURL,
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 100 * 1024 * 1024,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 32768, height <= 32768, width <= 100_000_000 / height,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                      kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw StudioError.validation("Use readable local images below 100 MB and 100 megapixels.")
            }
            try Task.checkCancellation()
            let target = directory.appendingPathComponent("image-\(index + 1).png")
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else { throw StudioError.validation("Could not prepare image pixels.") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw StudioError.validation("Could not save prepared image pixels.") }
            return target
        }
    }
}

private final class VisionRunProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var tail = ""
    private let model: String
    private let report = GenerationProgressContext.report
    init(model: String) { self.model = model }
    func consume(_ text: String) {
        let emit = lock.withLock {
            tail = String((tail + text).suffix(4096))
            guard !started, tail.contains("encoding image") || tail.contains("image encoded") else { return false }
            started = true; return true
        }
        if emit { NativeRuntime.state("running", model: model); report?(.init(stage: "Reading image pixels")) }
    }
}
