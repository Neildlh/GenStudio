import Foundation

enum GenerationModelKind: String, Codable, Sendable, CaseIterable { case text, image, video, vision, upscaler, speech }

/// A model may expose more than one workflow surface.  This deliberately lives
/// beside the install manifest (rather than in a view) so new runtimes can add
/// capabilities without hard-coding model names throughout the canvas.
enum ModelWorkflowCapability: String, Codable, Sendable, Hashable {
    case textGeneration
    case imageUnderstanding
}

struct ModelComponent: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let role: String
    let repository: String
    let revision: String
    let filename: String
    let byteSize: Int64
    let sha256: String
    let license: String
    /// Optional remote path when the installed package deliberately nests a
    /// component below a different local path (for example `gemma/config.json`).
    /// Existing manifests omit it and keep their published path unchanged.
    var sourceFilename: String? = nil
    var downloadURL: URL {
        if let sourceURL { return sourceURL }
        let remote = sourceFilename ?? filename
        let escaped = remote.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(escaped)")!
    }
    /// Non-Hugging-Face sources (for example a Civitai model-version download).
    /// Optional so old pinned manifests decode unchanged.
    var sourceURL: URL? = nil
}

struct ModelRecipe: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: GenerationModelKind
    let engineID: String
    let components: [ModelComponent]
    /// An integrated adapter handles this recipe; per-install inference and quality verification are separate.
    let runtimeReady: Bool
    let minimumMemoryBytes: UInt64
    /// Logical predecessor; an updated snapshot keeps its own immutable id.
    var baseRecipeID: String? = nil
    /// Data-driven runtime contract. Curated recipes leave this nil; imported
    /// recipes use values such as `sd-checkpoint` without adding a new adapter.
    var runtimeProfile: String? = nil
    var provider: String? = nil
    var sourceURL: URL? = nil
    var supportedImageTasks: [ImageTask]? = nil
    /// Nil preserves the historical single-kind behaviour.  Runtime adapters
    /// such as MLX VLM can explicitly opt into text and image-understanding
    /// nodes with the same installed package.
    var workflowCapabilities: Set<ModelWorkflowCapability>? = nil
    var totalBytes: Int64 { components.reduce(0) { partial, component in
        let next = partial.addingReportingOverflow(component.byteSize)
        return next.overflow ? Int64.max : next.partialValue
    } }
}

struct InstalledModelComponent: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let role: String
    let fileURL: URL
    let source: ModelComponent
}

struct InstalledGenerationModel: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: GenerationModelKind
    let engineID: String
    let components: [InstalledModelComponent]
    let installedAt: Date
    var inferenceVerified: Bool
    var available: Bool
    var recipeSnapshot: ModelRecipe? = nil
    /// Recipe/task-level proof flags used by image and video runners. Existing installs can safely omit this field.
    var verifiedVideoTasks: Set<VideoTask>? = nil
    /// Image-task proof flags. Existing installs can safely omit this field; in
    /// that legacy shape `inferenceVerified` remains the compatibility fallback.
    var verifiedImageTasks: Set<ImageTask>? = nil
    /// Upscale proof flag. There is exactly one task (upscale), unlike image/video's
    /// per-task sets, so a single optional bool is enough. Existing installs (which
    /// predate upscaling) omit this field; `inferenceVerified` is the legacy fallback.
    var verifiedUpscale: Bool? = nil
    /// Adapter eligibility is separate from a successful real generation.
    var canAttemptGeneration: Bool {
        if engineID == "mlx-vlm", recipeSnapshot?.runtimeProfile == "mlx-vlm" {
            return !components.isEmpty
        }
        if engineID == "mlx-fastvideo", recipeSnapshot?.runtimeProfile == "mlx-fastvideo" {
            return !components.isEmpty
        }
        if engineID == "mlx-ltx", recipeSnapshot?.runtimeProfile == "mlx-ltx" {
            return !components.isEmpty
        }
        if engineID == "mlx-audio", recipeSnapshot?.runtimeProfile == "mlx-audio" {
            return !components.isEmpty
        }
        return switch kind {
        case .text: engineID == "llama.cpp" && (id == "qwen25-05b-q4km" || id.hasPrefix("text-gguf-") || recipeSnapshot?.baseRecipeID == "qwen25-05b-q4km")
        case .image: engineID == "stable-diffusion.cpp" && (ImageCapabilityRegistry.hasUsableAdapter(id) || recipeSnapshot.map(UserModelCatalog.isSupported) == true)
        case .video: engineID == "stable-diffusion.cpp" && VideoCapabilityRegistry.hasUsableAdapter(id)
        case .vision: engineID == "llama.cpp-vision" && VisionModelCatalog.recipes.contains(where: { $0.id == id && $0.runtimeReady })
        case .upscaler: engineID == "stable-diffusion.cpp" && UpscaleCapabilityRegistry.supportsRecipe(id)
        case .speech: false
        }
    }
    /// Returns task-level proof while keeping older registries usable. Before
    /// task-specific proof flags were persisted, `inferenceVerified` was the
    /// only recorded signal. Treat that legacy value as proof for the selected
    /// task only when the newer set is absent; an explicit empty set means that
    /// no task has been verified yet.
    func hasVerifiedVideoTask(_ task: VideoTask) -> Bool {
        if let verifiedVideoTasks { return verifiedVideoTasks.contains(task) }
        return inferenceVerified
    }
    func hasVerifiedImageTask(_ task: ImageTask) -> Bool {
        if let verifiedImageTasks { return verifiedImageTasks.contains(task) }
        return inferenceVerified
    }
    var hasVerifiedUpscale: Bool { verifiedUpscale ?? inferenceVerified }
    func componentURL(role: String) -> URL? { components.first { $0.role == role }?.fileURL }
}

struct ModelDownloadProgress: Sendable, Equatable {
    let completedBytes: Int64
    let totalBytes: Int64
    var phase: String = "Downloading"
    var fraction: Double { totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0 }
}

struct HubModelSummary: Sendable, Identifiable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let pipelineTag: String?
    let recipeID: String?
}

enum ModelCatalog {
    // Provenance: docs/evidence/lead-llama-offline.json and .vendor/sd/MANIFEST.md.
    static let recipes: [ModelRecipe] = legacyRecipes + VisionModelCatalog.recipes + MLXVLMModelCatalog.recipes + MediaModelCatalog.recipes + MLXVideoModelCatalog.recipes + UpscalerModelCatalog.recipes + SpeechModelCatalog.recipes
    /// Preserve released manifests for offline migration; never edit existing entries.
    static let legacyRecipes: [ModelRecipe] = [
        .init(id: "qwen25-05b-q4km", name: "Qwen 2.5 0.5B Instruct · Q4_K_M", kind: .text, engineID: "llama.cpp", components: [
            .init(id: "model", role: "model", repository: "Qwen/Qwen2.5-0.5B-Instruct-GGUF", revision: "9217f5db79a29953eb74d5343926648285ec7e67", filename: "qwen2.5-0.5b-instruct-q4_k_m.gguf", byteSize: 491400032, sha256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db", license: "Apache-2.0")
        ], runtimeReady: true, minimumMemoryBytes: 4 * 1024 * 1024 * 1024),
        .init(id: "sd15-q4", name: "Stable Diffusion 1.5 · Q4_0", kind: .image, engineID: "stable-diffusion.cpp", components: [
            .init(id: "checkpoint", role: "checkpoint", repository: "second-state/stable-diffusion-v1-5-GGUF", revision: "031b5f5df991f511b3f5fa8fed6d99048ababb69", filename: "stable-diffusion-v1-5-pruned-emaonly-Q4_0.gguf", byteSize: 1566768416, sha256: "b8944e9fe0b69b36ae1b5bb0185b3a7b8ef14347fe0fa9af6c64c4829022261f", license: "CreativeML Open RAIL-M")
        ], runtimeReady: true, minimumMemoryBytes: 8 * 1024 * 1024 * 1024),
        .init(id: "wan21-13b-q4", name: "Wan 2.1 T2V 1.3B · Q4", kind: .video, engineID: "stable-diffusion.cpp", components: [
            .init(id: "diffusion", role: "diffusion", repository: "calcuis/wan-1.3b-gguf", revision: "0652f175f44055eb60cca26dd7cd89c14abe22ce", filename: "wan2.1_t2v_1.3b-q4_0.gguf", byteSize: 916895968, sha256: "da5e578d3ca7ef377f8258a1dc9a6ab176c4d2de7595c5f78d62a234e2cf13ef", license: "Apache-2.0"),
            .init(id: "textEncoder", role: "textEncoder", repository: "city96/umt5-xxl-encoder-gguf", revision: "b535255bee98c2b0a59ea7c0ae2dcd0c6657b3b7", filename: "umt5-xxl-encoder-Q4_K_M.gguf", byteSize: 3655145312, sha256: "17cf97a5bbbc60a646d6105b832b6f657ce904a8a1ad970e4b59df0c67584a40", license: "Apache-2.0"),
            .init(id: "vae", role: "vae", repository: "Comfy-Org/Wan_2.1_ComfyUI_repackaged", revision: "617a7633e636506f850e043bc4605f290a466a8e", filename: "split_files/vae/wan_2.1_vae.safetensors", byteSize: 253815318, sha256: "2fc39d31359a4b0a64f55876d8ff7fa8d780956ae2cb13463b0223e15148976b", license: "Apache-2.0")
        ], runtimeReady: false, minimumMemoryBytes: 16 * 1024 * 1024 * 1024)
    ]
}
