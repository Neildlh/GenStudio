import Foundation

/// Evidence-based compatibility for the engines shipped with this application.
/// This does not ask a language model to infer support from publisher names or prose.
enum ModelCompatibility {
    enum State: String, Sendable {
        case supported, demanding, needsValidation, unsupported, incompatible, insufficientStorage, unknownResources
    }
    struct Assessment: Sendable {
        let state: State
        /// Eligible for the default "Works on this Mac" feed. This is adapter/resource
        /// guidance, not evidence that this exact machine has completed inference.
        let eligible: Bool
        let label: String
        let detail: String
        var recipeID: String? = nil
        var requiredStorageBytes: Int64? = nil
    }

    /// The installer keeps the complete package plus one in-flight component and a reserve.
    /// Nil is deliberately not treated as zero when arithmetic or metadata is invalid.
    static func installationStorageBytes(recipe: ModelRecipe) -> Int64? {
        guard !recipe.components.isEmpty, recipe.components.allSatisfy({ $0.byteSize > 0 }) else { return nil }
        var total: Int64 = 0
        for component in recipe.components {
            let sum = total.addingReportingOverflow(component.byteSize)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        let staged = total.addingReportingOverflow(recipe.components.map(\.byteSize).max() ?? 0)
        guard !staged.overflow else { return nil }
        let reserved = staged.partialValue.addingReportingOverflow(256 * 1024 * 1024)
        return reserved.overflow ? nil : reserved.partialValue
    }

    static func assess(recipe: ModelRecipe, hardware: HardwareProfile?, installed: InstalledGenerationModel? = nil) -> Assessment {
        let matchingInstalled = installed.flatMap { matches($0, recipe: recipe) ? $0 : nil }
        let canonical = ModelCatalog.recipes.contains { $0 == recipe && integrated($0) }
        // ModelLibrary only admits these snapshots after parsing the local GGUF header,
        // architecture and embedded chat template. File hashes are rechecked at execution.
        let admittedText = matchingInstalled.map {
            $0.recipeSnapshot == recipe && $0.kind == .text && $0.engineID == "llama.cpp"
                && $0.canAttemptGeneration && (recipe.id.hasPrefix("text-gguf-") || recipe.baseRecipeID == "qwen25-05b-q4km")
        } ?? false
        // An installed image/video model with a descriptor remains diagnosable even if that
        // descriptor is rejected for new installs (for example, a historical AnimateDiff
        // workflow). This does not admit the recipe into the installable feed or claim proof.
        let installedWithAdapter = matchingInstalled != nil && recipe.engineID == "stable-diffusion.cpp"
            && (recipe.kind == .video ? VideoCapabilityRegistry.hasAdapter(recipe.id)
                : recipe.kind == .image ? ImageCapabilityRegistry.hasAdapter(recipe.id)
                : recipe.kind == .upscaler ? UpscaleCapabilityRegistry.hasAdapter(recipe.id) : false)
        let userImage = recipe.kind == .image && UserModelCatalog.isSupported(recipe)
        let mlxVLM = recipe.engineID == "mlx-vlm" && recipe.runtimeProfile == "mlx-vlm"
            && recipe.workflowCapabilities == [.textGeneration, .imageUnderstanding]
        guard canonical || admittedText || installedWithAdapter || userImage || mlxVLM else {
            let candidate = recipe.kind == .text && recipe.engineID == "llama.cpp" && recipe.id.hasPrefix("text-gguf-")
            return .init(state: candidate ? .needsValidation : .unsupported, eligible: false,
                label: candidate ? "Needs file validation" : "Not supported in this app",
                detail: candidate ? "This text file must pass architecture and chat-template validation before it can appear as usable."
                    : "There is no verified adapter for this exact model package in GenStudio. A model family, format or publisher claim does not establish support.", recipeID: recipe.id)
        }
        if mlxVLM, (try? ManagedMLXRuntime.pythonExecutable(for: .vlm)) == nil {
            return .init(state: .unsupported, eligible: false, label: "Managed MLX runtime unavailable", detail: "This GenStudio build does not include the version-pinned MLX VLM runtime, so an installed package would not be runnable. It is intentionally not offered as a compatible model.", recipeID: recipe.id)
        }
        if recipe.engineID == "mlx-ltx", recipe.runtimeProfile == "mlx-ltx",
           (try? ManagedMLXRuntime.pythonExecutable(for: .ltx)) == nil {
            return .init(state: .unsupported, eligible: false, label: "Managed LTX runtime unavailable", detail: "This GenStudio build does not include the pinned native MLX LTX runtime, so the model package is not offered for download.", recipeID: recipe.id)
        }
        if recipe.engineID == "mlx-fastvideo", recipe.runtimeProfile == "mlx-fastvideo",
           (try? ManagedMLXRuntime.pythonExecutable(for: .fastVideo)) == nil {
            return .init(state: .unsupported, eligible: false, label: "Managed FastVideo runtime unavailable", detail: "This GenStudio build does not include the pinned FastVideo MLX runtime, so the model package is not offered for download.", recipeID: recipe.id)
        }
        if let hardwareIssue = platformIssue(hardware) { return attaching(hardwareIssue, recipeID: recipe.id) }
        guard let hardware else { return .init(state: .unknownResources, eligible: false, label: "Checking this Mac", detail: "Computer information is unavailable.", recipeID: recipe.id) }
        if let matchingInstalled, !matchingInstalled.available {
            return .init(state: .needsValidation, eligible: false, label: "Installed files missing", detail: "Repair or reinstall the complete model package before using it.", recipeID: recipe.id)
        }
        guard hardware.memoryBytes > 0, recipe.minimumMemoryBytes > 0 else {
            return .init(state: .unknownResources, eligible: false, label: "Memory not established", detail: "Available computer memory or model memory guidance is unknown.", recipeID: recipe.id)
        }
        if hardware.memoryBytes < recipe.minimumMemoryBytes {
            return .init(state: .demanding, eligible: false, label: "Below memory guidance", detail: "This Mac has less memory than the package's estimated requirement. It may be possible with heavy memory pressure, but it is excluded from the suitable-model feed. This is not a proven incompatibility.", recipeID: recipe.id)
        }
        var required: Int64?
        if matchingInstalled == nil {
            guard let storage = installationStorageBytes(recipe: recipe) else {
                return .init(state: .unknownResources, eligible: false, label: "Storage not established", detail: "The complete download and staging requirement could not be established.", recipeID: recipe.id)
            }
            required = storage
            guard hardware.freeDiskBytes > 0 else {
                return .init(state: .unknownResources, eligible: false, label: "Free storage unknown", detail: "GenStudio could not read free space on the model-library drive.", recipeID: recipe.id, requiredStorageBytes: storage)
            }
            guard hardware.freeDiskBytes >= storage else {
                return .init(state: .insufficientStorage, eligible: false, label: "Needs more free storage", detail: "The complete package, temporary download space and installation reserve exceed the drive's free space.", recipeID: recipe.id, requiredStorageBytes: storage)
            }
        }
        let demanding = hardware.memoryBytes / 2 < recipe.minimumMemoryBytes
        // canonical/admittedText already imply a globally verified task, so this only ever
        // reads false for the installedWithAdapter path above (an installed, adapter-ready
        // but not-yet-decoded-anywhere recipe). Never claim proof that does not exist.
        let localProof = matchingInstalled?.available == true && matchingInstalled?.inferenceVerified == true
        let verifiedAdapter = recipe.kind == .video ? (VideoCapabilityRegistry.supportsRecipe(recipe.id) || localProof)
            : recipe.kind == .image ? (ImageCapabilityRegistry.supportsRecipe(recipe.id) || localProof)
            : recipe.kind == .upscaler ? (UpscaleCapabilityRegistry.supportsRecipe(recipe.id) || localProof)
            : recipe.kind == .vision ? (VisionModelCatalog.supportsRecipe(recipe.id) || MLXVLMModelCatalog.supportsRecipe(recipe.id) || localProof)
            : true
        let unverifiedLabel = matchingInstalled == nil ? "Adapter available · not yet verified" : "Installed · adapter not yet verified"
        return .init(state: demanding ? .demanding : .supported, eligible: true,
            label: demanding ? "Possible, but demanding" : (verifiedAdapter ? "Supported on this Mac" : unverifiedLabel),
            detail: demanding ? "A compatible local adapter is included, but estimated memory use leaves limited headroom. Speed and quality on this configuration are unmeasured."
                : (verifiedAdapter ? "A compatible local adapter is included and this Mac meets the package's memory and storage guidance. This does not promise a particular speed or output quality."
                    : "A compatible local adapter and complete install route are included. Speed and quality are unmeasured until a decoded local render records the result."),
            recipeID: recipe.id, requiredStorageBytes: required)
    }

    static func assess(detail: DiscoveryDetail, hardware: HardwareProfile?, installedModels: [InstalledGenerationModel] = []) -> Assessment {
        let known = ModelCatalog.recipes + installedModels.compactMap(\.recipeSnapshot)
        let exact = known.filter { recipe in
            // Recipes can be assembled from several repositories. Matching the inspected
            // repository's own pinned components is enough to identify the complete route;
            // installation still downloads and verifies every remaining component.
            let own = recipe.components.filter { $0.repository.caseInsensitiveCompare(detail.model.id) == .orderedSame }
            return !own.isEmpty && own.allSatisfy { component in
                component.revision == detail.model.sha
                    && detail.files.contains { $0.path == component.filename && $0.bytes == component.byteSize && $0.sha256 == component.sha256 }
            }
        }.map { recipe in assess(recipe: recipe, hardware: hardware, installed: installedModels.first { $0.id == recipe.id }) }
        if let usable = exact.first(where: \.eligible) { return usable }
        if let evidence = exact.first { return evidence }
        if let hardwareIssue = platformIssue(hardware) { return hardwareIssue }
        if !detail.experimentalTextFiles.isEmpty {
            return .init(state: .needsValidation, eligible: false, label: "Needs file validation", detail: "A possible standalone text GGUF is available. Its downloaded architecture and chat template must be checked before it can be offered as usable on this Mac.")
        }
        return .init(state: .unsupported, eligible: false, label: "No supported package", detail: "GenStudio does not have a verified local adapter and complete installation plan for this exact revision. This does not mean the model cannot run on any Mac.")
    }

    private static func integrated(_ recipe: ModelRecipe) -> Bool {
        // Released video manifests are immutable, so readiness comes from the exact recipe/task capability descriptor.
        // Image, video and upscaler readiness come from the exact recipe/task capability descriptors, never from runtimeReady or an id check.
        if recipe.kind == .video {
            let supportedEngine = recipe.engineID == "stable-diffusion.cpp" || recipe.engineID == "mlx-fastvideo" || recipe.engineID == "mlx-ltx"
            return supportedEngine && VideoCapabilityRegistry.hasUsableAdapter(recipe.id) && ModelCatalog.recipes.contains(recipe)
        }
        if recipe.kind == .image { return recipe.engineID == "stable-diffusion.cpp" && ImageCapabilityRegistry.hasUsableAdapter(recipe.id) && ModelCatalog.recipes.contains(recipe) }
        if recipe.kind == .upscaler { return recipe.engineID == "stable-diffusion.cpp" && UpscaleCapabilityRegistry.hasUsableAdapter(recipe.id) && ModelCatalog.recipes.contains(recipe) }
        if recipe.kind == .speech { return recipe.engineID == "mlx-audio" && recipe.runtimeProfile == "mlx-audio" && SpeechModelCatalog.recipes.contains(recipe) }
        if recipe.kind == .vision, recipe.engineID == "mlx-vlm", recipe.runtimeProfile == "mlx-vlm" {
            return MLXVLMModelCatalog.recipes.contains(recipe)
        }
        guard recipe.runtimeReady else { return false }
        switch recipe.kind {
        case .text: return recipe.id == "qwen25-05b-q4km" && recipe.engineID == "llama.cpp"
        case .image: return false
        case .vision: return recipe.engineID == "llama.cpp-vision" && VisionModelCatalog.recipes.contains(recipe)
        case .video: return false
        case .upscaler, .speech: return false
        }
    }

    private static func matches(_ model: InstalledGenerationModel, recipe: ModelRecipe) -> Bool {
        model.id == recipe.id && model.kind == recipe.kind && model.engineID == recipe.engineID
            && model.components.count == recipe.components.count && zip(model.components, recipe.components).allSatisfy {
                $0.id == $1.id && $0.role == $1.role && $0.source == $1
            }
    }

    static func platformIssue(_ hardware: HardwareProfile?) -> Assessment? {
        guard let hardware else {
            return .init(state: .unknownResources, eligible: false, label: "Checking this Mac", detail: "Computer information is unavailable.")
        }
        let version = try? NSRegularExpression(pattern: #"^(?:Version |macOS )?(\d+)(?:\.|$)"#)
        let nsVersion = hardware.osVersion as NSString
        let major = version?.firstMatch(in: hardware.osVersion, range: NSRange(location: 0, length: nsVersion.length)).flatMap { Int(nsVersion.substring(with: $0.range(at: 1))) }
        let chip = hardware.chip.trimmingCharacters(in: .whitespacesAndNewlines)
        if chip.localizedCaseInsensitiveContains("intel") || (major != nil && major! < 26) {
            return .init(state: .incompatible, eligible: false, label: "Incompatible with this build", detail: "The app's bundled engines require Apple Silicon and macOS 26 or later.")
        }
        guard chip.range(of: #"^Apple M\d"#, options: .regularExpression) != nil, major != nil else {
            return .init(state: .unknownResources, eligible: false, label: "Hardware not established", detail: "Apple Silicon and the macOS version could not both be confirmed. Unknown hardware is not treated as incompatible.")
        }
        return nil
    }

    private static func attaching(_ assessment: Assessment, recipeID: String) -> Assessment {
        var result = assessment; result.recipeID = recipeID; return result
    }
}
