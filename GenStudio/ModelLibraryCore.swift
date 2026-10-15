import Foundation
import CryptoKit
import Darwin
import IOKit
import Metal

struct HardwareProfile: Sendable {
    let chip: String
    let memoryBytes: UInt64
    let osVersion: String
    let freeDiskBytes: Int64
    var totalDiskBytes: Int64 = 0
    /// Metal's recommended working set; guidance, not guaranteed allocatable memory. Zero when unknown.
    var gpuWorkingSetBytes: UInt64 = 0
    /// Whether the library volume can clone files, so reused components share storage.
    var volumeSupportsCloning = false
    /// CPU and GPU core counts. Zero when the system does not report them.
    var performanceCores = 0
    var efficiencyCores = 0
    var gpuCores = 0
    /// Memory models can realistically occupy: Metal's recommended working set when known,
    /// otherwise three quarters of unified memory. Guidance, not an allocation guarantee.
    var usableModelBytes: UInt64 { gpuWorkingSetBytes > 0 ? gpuWorkingSetBytes : memoryBytes / 4 * 3 }
    /// Half of memory: the same line `ModelCompatibility` uses to call a package demanding.
    var comfortableModelBytes: UInt64 { memoryBytes / 2 }
    private static func sysctlInt(_ name: String) -> Int {
        var value = 0; var length = MemoryLayout<Int>.size
        return sysctlbyname(name, &value, &length, nil, 0) == 0 ? value : 0
    }
    /// Apple's GPU driver publishes its core count in the I/O registry; there is no public API for it.
    private static func gpuCoreCount() -> Int {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0
    }
    static func current(storageURL: URL? = nil) -> Self {
        var chipLength = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &chipLength, nil, 0)
        var chipBuffer = [CChar](repeating: 0, count: max(chipLength, 1))
        let chipResult = sysctlbyname("machdep.cpu.brand_string", &chipBuffer, &chipLength, nil, 0)
        var memory: UInt64 = 0; var memoryLength = MemoryLayout<UInt64>.size
        let memoryResult = sysctlbyname("hw.memsize", &memory, &memoryLength, nil, 0)
        var diskURL = storageURL ?? FileManager.default.homeDirectoryForCurrentUser
        while !FileManager.default.fileExists(atPath: diskURL.path), diskURL.path != "/" { diskURL.deleteLastPathComponent() }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: diskURL.path)
        let cloning = (try? diskURL.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
        return .init(chip: chipResult == 0 ? String(decoding: chipBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "Unknown", memoryBytes: memoryResult == 0 ? memory : 0,
                     osVersion: ProcessInfo.processInfo.operatingSystemVersionString, freeDiskBytes: (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0,
                     totalDiskBytes: (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0,
                     gpuWorkingSetBytes: MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0, volumeSupportsCloning: cloning,
                     performanceCores: sysctlInt("hw.perflevel0.physicalcpu"), efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu"), gpuCores: gpuCoreCount())
    }
}

enum GenerationLibraryError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }

    /// Actionable wording for Hugging Face HTTP failures. No credential is ever sent, so gated files fail here.
    static func hub(status: Int, action: String) -> GenerationLibraryError {
        switch status {
        case 401, 403: .invalid("\(action) was refused by Hugging Face (HTTP \(status)). The repository may be gated or private: sign in on huggingface.co and accept the publisher’s licence. GenStudio does not send Hugging Face credentials yet, so gated files cannot be downloaded here.")
        case 404: .invalid("\(action) failed: the file or revision was not found on Hugging Face (HTTP 404). The publisher may have removed or renamed it.")
        case 429: .invalid("\(action) was rate-limited by Hugging Face (HTTP 429). Wait a few minutes and try again.")
        case 500...599: .invalid("\(action) failed because Hugging Face is unavailable (HTTP \(status)). Try again later; installed models keep working offline.")
        default: .invalid("\(action) failed (HTTP \(status)).")
        }
    }
}

protocol ModelDownloadTransport: Sendable {
    /// Writes the pinned file to `to`. If `to` already holds a prefix of the file, a transport may resume it; it must
    /// never leave more than `expectedBytes` there. The library always re-verifies the final size and SHA-256.
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws
}

actor ModelLibrary {
    nonisolated let root: URL
    private let transport: any ModelDownloadTransport
    private let diskAvailable: @Sendable (URL) -> Int64
    private var busy = false
    private let catalog: [ModelRecipe]
    let updateMetadata: any ModelUpdateMetadataProvider
    var admittedUpdates: [String: ModelRecipe] = [:]
    private var admittedTextRecipes: [String: ModelRecipe] = [:]
    private var admittedMLXRecipes: [String: ModelRecipe] = [:]
    private var admittedUserRecipes: [String: ModelRecipe] = [:]
    /// Full SHA-256 validation is deliberately performed before a model is first
    /// handed to an inference engine. Repeating that same multi-gigabyte disk
    /// read before every node in the same process made successive local renders
    /// substantially slower without finding a new state. Verified fingerprints are
    /// also kept in `verified-components.json` so a relaunch reuses them; a changed
    /// file fingerprint invalidates the entry before it can be reused.
    private struct ValidatedComponent: Codable, Hashable, Sendable {
        let path: String
        let expectedSHA256: String
        let byteSize: Int64
        let fileNumber: UInt64
        let modificationTime: TimeInterval
    }
    private var validatedComponents: Set<ValidatedComponent> = []
    private var validationLedgerLoaded = false
    /// Verified fingerprints survive a relaunch, so an unchanged multi-gigabyte file is not hashed again
    /// on every launch (~15 s for LTX-2.3 on the reference Mac). Trust is exactly the in-session rule: the
    /// same path, size, file number and modification time. A missing or unreadable ledger only costs a rehash.
    private struct ValidationLedger: Codable { var schemaVersion = 1; var components: [ValidatedComponent] = [] }
    private var validationLedgerURL: URL { root.appending(path: "verified-components.json") }
    private func loadValidationLedgerIfNeeded() {
        guard !validationLedgerLoaded else { return }
        validationLedgerLoaded = true
        guard let data = try? Data(contentsOf: validationLedgerURL),
              let ledger = try? JSONDecoder().decode(ValidationLedger.self, from: data), ledger.schemaVersion == 1 else { return }
        validatedComponents.formUnion(ledger.components)
    }
    private func saveValidationLedger() {
        // Only entries whose file still exists are worth keeping; a stale entry could never match anyway.
        let live = validatedComponents.filter { FileManager.default.fileExists(atPath: $0.path) }
        let ledger = ValidationLedger(components: live.sorted { $0.path < $1.path })
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: validationLedgerURL, options: .atomic)
    }
    /// Components hashed by this instance (tests observe that a relaunch reuses earlier verification).
    private(set) var hashedComponentCount = 0
    private struct Registry: Codable { var schemaVersion = 1; var models: [InstalledGenerationModel] = [] }
    init(root: URL? = nil, catalog: [ModelRecipe] = ModelCatalog.recipes, transport: any ModelDownloadTransport = StreamingModelTransport(), diskAvailable: @escaping @Sendable (URL) -> Int64 = { HardwareProfile.current(storageURL: $0).freeDiskBytes }, updateMetadata: any ModelUpdateMetadataProvider = HubUpdateMetadataProvider()) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "GenStudio/Models", directoryHint: .isDirectory)
        self.transport = transport; self.diskAvailable = diskAvailable; self.catalog = catalog; self.updateMetadata = updateMetadata
    }
    private var registryURL: URL { root.appending(path: "registry.json") }
    /// Safely calculates bytes needed: rejects overflow before comparison.
    private nonisolated func checkDiskSpaceForNeeded(_ bytes: Int64, _ reserve: Int64, root: URL) throws {
        let sum = bytes.addingReportingOverflow(reserve)
        guard !sum.overflow else { throw GenerationLibraryError.invalid("Model component sizes overflow storage calculation.") }
        let needed = sum.partialValue
        guard needed <= diskAvailable(root) else { throw GenerationLibraryError.invalid("Free disk space dropped during installation. Nothing was registered; free space and retry.") }
    }
    private func readRegistry() throws -> Registry {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return Registry() }
        do {
            let registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
            guard registry.schemaVersion == 1, Set(registry.models.map(\.id)).count == registry.models.count else { throw GenerationLibraryError.invalid("Unsupported or invalid model registry. Its file has been preserved.") }
            return registry
        } catch { throw GenerationLibraryError.invalid("Cannot read model registry. Its file has been preserved: \(error.localizedDescription)") }
    }
    private func writeRegistry(_ registry: Registry) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: registryURL, options: .atomic)
    }
    func installedModels() throws -> [InstalledGenerationModel] {
        try readRegistry().models.map { model in
            var updated = model
            updated.available = !model.components.isEmpty && model.components.allSatisfy { FileManager.default.isReadableFile(atPath: $0.fileURL.path) }
            return updated
        }
    }
    func resolveInstalledModel(id: String) async throws -> InstalledGenerationModel {
        guard let model = try installedModels().first(where: { $0.id == id }) else { throw GenerationLibraryError.invalid("The selected model is not installed. Open Model Library to install it.") }
        _ = try installedRecipe(id: id)
        guard model.available else { throw GenerationLibraryError.invalid("A selected model component is missing. Reinstall the complete model recipe.") }
        loadValidationLedgerIfNeeded()
        var verifiedNow = false
        for component in model.components {
            let fingerprint = try componentFingerprint(component)
            if validatedComponents.contains(fingerprint) { continue }
            let inspectText = model.id.hasPrefix("text-gguf-") || (model.recipeSnapshot?.baseRecipeID != nil && model.kind == .text)
            hashedComponentCount += 1
            let job = Task.detached {
                try Self.validateFile(component.fileURL, component: component.source)
                if inspectText { try Task.checkCancellation(); try GGUFTextInspector.validate(component.fileURL) }
            }
            try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
            // Re-read after the asynchronous hash. A write during validation
            // cannot become trusted merely because it began with this identity.
            guard fingerprint == (try componentFingerprint(component)) else {
                throw GenerationLibraryError.invalid("Model component \(component.fileURL.lastPathComponent) changed while GenStudio was verifying it. Run again after the file is stable.")
            }
            validatedComponents.insert(fingerprint)
            verifiedNow = true
        }
        if verifiedNow { saveValidationLedger() }
        try Task.checkCancellation()
        return model
    }

    private func componentFingerprint(_ component: InstalledModelComponent) throws -> ValidatedComponent {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: component.fileURL.path) }
        catch { throw GenerationLibraryError.invalid("Model component \(component.fileURL.lastPathComponent) is not readable.") }
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else {
            throw GenerationLibraryError.invalid("Could not inspect model component \(component.fileURL.lastPathComponent).")
        }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return .init(path: component.fileURL.standardizedFileURL.path, expectedSHA256: component.source.sha256, byteSize: size, fileNumber: fileNumber, modificationTime: date.timeIntervalSinceReferenceDate)
    }
    /// Reads the immutable install manifest without hashing gigabytes for a metadata check.
    func installedRecipe(id: String) throws -> ModelRecipe {
        guard let model = try installedModels().first(where: { $0.id == id }) else { throw GenerationLibraryError.invalid("The selected model is not installed.") }
        let installDirectory = try ownedInstallDirectory(for: model)
        let manifestURL = installDirectory.appending(path: ".recipe.json")
        finishPendingExtension(model, manifestURL: manifestURL)
        let recipe: ModelRecipe
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            recipe = try JSONDecoder().decode(ModelRecipe.self, from: Data(contentsOf: manifestURL))
        } else {
            // Only previously trusted exact releases may migrate without a manifest.
            guard let legacy = (ModelCatalog.legacyRecipes + catalog).first(where: { Self.matches(model, recipe: $0) }) else { throw GenerationLibraryError.invalid("The installed registry entry does not match a supported pinned recipe.") }
            recipe = legacy
            try JSONEncoder().encode(recipe).write(to: manifestURL, options: .atomic)
        }
        guard Self.matches(model, recipe: recipe), model.recipeSnapshot == nil || model.recipeSnapshot == recipe else { throw GenerationLibraryError.invalid("The installed registry entry does not match its pinned recipe manifest.") }
        return recipe
    }

    /// Returns the one UUID package directory owned by this library. Components
    /// may be nested below it (MLX loaders require published relative paths),
    /// but no component may escape it or point into a second installation.
    private func ownedInstallDirectory(for model: InstalledGenerationModel) throws -> URL {
        let owned = root.appending(path: "Installed").standardizedFileURL.resolvingSymlinksInPath()
        guard !model.components.isEmpty else { throw GenerationLibraryError.invalid("Model files must be owned by this library.") }
        var packageName: String?
        for component in model.components {
            let resolved = component.fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(owned.path + "/") else { throw GenerationLibraryError.invalid("Model files must be owned by this library.") }
            let relative = String(resolved.path.dropFirst(owned.path.count + 1))
            guard let first = relative.split(separator: "/").first,
                  UUID(uuidString: String(first)) != nil else { throw GenerationLibraryError.invalid("Model files must be owned by this library.") }
            let componentPackage = String(first)
            if let packageName, packageName != componentPackage { throw GenerationLibraryError.invalid("Model files must be owned by one installed package.") }
            packageName = componentPackage
        }
        guard let packageName else { throw GenerationLibraryError.invalid("Model files must be owned by this library.") }
        return owned.appending(path: packageName, directoryHint: .isDirectory)
    }
    private static func matches(_ model: InstalledGenerationModel, recipe: ModelRecipe) -> Bool {
        model.id == recipe.id && model.name == recipe.name && model.engineID == recipe.engineID && model.kind == recipe.kind && model.components.count == recipe.components.count && zip(model.components, recipe.components).allSatisfy { installed, expected in installed.source == expected && installed.id == expected.id && installed.role == expected.role }
    }
    func markInferenceVerified(id: String, for task: VideoTask? = nil) throws {
        var registry = try readRegistry()
        guard let index = registry.models.firstIndex(where: { $0.id == id }) else { throw GenerationLibraryError.invalid("Model is not installed.") }
        guard registry.models[index].components.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.fileURL.path) }) else { throw GenerationLibraryError.invalid("Model files are missing.") }; registry.models[index].inferenceVerified = true
        if let task {
            registry.models[index].verifiedVideoTasks = Set((registry.models[index].verifiedVideoTasks ?? []) + [task])
        }
        try writeRegistry(registry)
    }
    func markImageInferenceVerified(id: String, for task: ImageTask) throws {
        var registry = try readRegistry()
        guard let index = registry.models.firstIndex(where: { $0.id == id }) else { throw GenerationLibraryError.invalid("Model is not installed.") }
        guard registry.models[index].components.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.fileURL.path) }) else { throw GenerationLibraryError.invalid("Model files are missing.") }
        registry.models[index].inferenceVerified = true
        registry.models[index].verifiedImageTasks = Set((registry.models[index].verifiedImageTasks ?? []) + [task])
        try writeRegistry(registry)
    }
    func markUpscaleInferenceVerified(id: String) throws {
        var registry = try readRegistry()
        guard let index = registry.models.firstIndex(where: { $0.id == id }) else { throw GenerationLibraryError.invalid("Model is not installed.") }
        guard registry.models[index].components.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.fileURL.path) }) else { throw GenerationLibraryError.invalid("Model files are missing.") }
        registry.models[index].inferenceVerified = true
        registry.models[index].verifiedUpscale = true
        try writeRegistry(registry)
    }
    /// Advanced discovery admission is provisional; parsed architecture/template validation follows download.
    func admitTextRecipe(_ recipe: ModelRecipe) throws {
        guard recipe.id.hasPrefix("text-gguf-"), recipe.kind == .text, recipe.engineID == "llama.cpp", !recipe.runtimeReady,
              recipe.components.count == 1, recipe.components[0].role == "model", recipe.components[0].id == "model",
              recipe.components[0].filename.lowercased().hasSuffix(".gguf"), recipe.baseRecipeID == nil else { throw GenerationLibraryError.invalid("Only a complete standalone experimental text GGUF recipe can be admitted here.") }
        try validateRecipeShape(recipe)
        admittedTextRecipes[recipe.id] = recipe
    }
    func admitUserRecipe(_ recipe: ModelRecipe) throws {
        guard UserModelCatalog.isSupported(recipe) else { throw GenerationLibraryError.invalid("Unsupported user model runtime profile.") }
        try validateRecipeShape(recipe)
        admittedUserRecipes[recipe.id] = recipe
    }
    /// MLX repositories are directory packages: tokenizer/config files and all
    /// shards are installed together and retain their published filenames.
    func admitMLXRecipe(_ recipe: ModelRecipe) throws {
        guard recipe.id.hasPrefix("mlx-vlm-"), recipe.kind == .vision,
              recipe.engineID == "mlx-vlm", recipe.runtimeProfile == "mlx-vlm",
              recipe.workflowCapabilities == [.textGeneration, .imageUnderstanding],
              recipe.components.contains(where: { $0.role == "config" && $0.filename == "config.json" }),
              recipe.components.contains(where: { $0.role == "weights" && $0.filename.hasSuffix(".safetensors") }) else {
            throw GenerationLibraryError.invalid("An MLX vision package needs its config, tokenizer and every pinned weight shard.")
        }
        try validateRecipeShape(recipe)
        admittedMLXRecipes[recipe.id] = recipe
    }
    /// MLX video repositories are complete directory packages too. Their
    /// relative paths are part of the upstream runtime contract (for example
    /// FastMetal resolves `text_encoder/`, `tokenizer/`, and `vae/` beneath one
    /// model root), so imports retain them after strict path validation.
    func admitMLXVideoRecipe(_ recipe: ModelRecipe) throws {
        let fastMetal = recipe.id.hasPrefix("mlx-fastmetal-") && recipe.engineID == "mlx-fastvideo" && recipe.runtimeProfile == "mlx-fastvideo"
            && recipe.components.contains(where: { $0.role == "mlxDiT" && $0.filename == "mlx_dit.safetensors" })
            && recipe.components.contains(where: { $0.role == "mlxConfig" && $0.filename == "mlx_dit.json" })
            && recipe.components.contains(where: { $0.role == "textEncoder" && $0.filename.hasPrefix("text_encoder/") })
            && recipe.components.contains(where: { $0.role == "vae" && $0.filename.hasPrefix("vae/") })
        let ltx = recipe.id.hasPrefix("mlx-ltx-") && recipe.engineID == "mlx-ltx" && recipe.runtimeProfile == "mlx-ltx"
            && recipe.components.contains(where: { $0.role == "ltxTransformer" && $0.filename.hasSuffix(".safetensors") })
            && recipe.components.contains(where: { $0.role == "textConnector" && $0.filename == "connector.safetensors" })
            && recipe.components.contains(where: { $0.role == "textEncoder" && $0.filename.hasPrefix("gemma/") })
            && recipe.components.contains(where: { $0.role == "vaeEncoder" && $0.filename == "vae_encoder.safetensors" })
            && recipe.components.contains(where: { $0.role == "vaeDecoder" && $0.filename == "vae_decoder.safetensors" })
            && recipe.components.contains(where: { $0.role == "upscaler" && $0.filename.hasSuffix(".safetensors") })
        guard recipe.kind == .video, fastMetal || ltx else {
            throw GenerationLibraryError.invalid("An MLX video package needs its complete pinned transformer, text encoder, tokenizer, VAE and pipeline-specific auxiliary files.")
        }
        try validateRecipeShape(recipe)
        admittedMLXRecipes[recipe.id] = recipe
    }
    func install(recipe: ModelRecipe, progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }) async throws -> InstalledGenerationModel {
        try await performInstall(recipe: recipe, sources: nil, progress: progress)
    }
    func importFiles(recipe: ModelRecipe, filesByComponentID: [String: URL], progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }) async throws -> InstalledGenerationModel {
        guard Set(filesByComponentID.keys) == Set(recipe.components.map(\.id)) else { throw GenerationLibraryError.invalid("Choose every component of the selected recipe. Import accepts this exact verified file set, not arbitrary model families.") }
        return try await performInstall(recipe: recipe, sources: filesByComponentID, progress: progress)
    }
    private func performInstall(recipe: ModelRecipe, sources: [String: URL]?, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws -> InstalledGenerationModel {
        guard !busy else { throw GenerationLibraryError.invalid("Another model installation is running.") }
        busy = true; defer { busy = false }
        try validateRecipe(recipe)
        // Shipped image/video manifests without an exact adapter remain information-only.
        // This applies to the legacy stable-diffusion.cpp LTX recipe, not the
        // separately identified native-MLX LTX-2.3 Q4 recipe.
        if MediaModelCatalog.recipes.contains(where: { $0.id == recipe.id }),
           !(ImageCapabilityRegistry.hasAdapter(recipe.id) || VideoCapabilityRegistry.hasAdapter(recipe.id)) {
            throw GenerationLibraryError.invalid("This recipe has no adapter in this version of GenStudio, so it cannot be installed yet.")
        }
        let registry = try readRegistry()
        guard !registry.models.contains(where: { $0.id == recipe.id }) else { throw GenerationLibraryError.invalid("This recipe is already registered. Remove it before reinstalling.") }
        // Downloads may reuse components already installed with identical content; imports copy the user's chosen files.
        let installedModels = sources == nil ? try installedModels() : []
        let clones = sources == nil && Self.volumeSupportsCloning(root)
        guard let plan = StoragePlan.make(recipe: recipe, installed: installedModels, clonesShareStorage: clones) else { throw GenerationLibraryError.invalid("Invalid model recipe sizes.") }
        // Bytes already saved by an earlier, interrupted download of these exact components are on disk already.
        let partials = PartialDownloadStore(root: root)
        if sources == nil { try pruneAbandonedPartials(keeping: recipe) }
        let savedBytes = sources == nil ? recipe.components.filter { StoragePlan.reusableSource(for: $0, installed: installedModels, excluding: recipe.id) == nil }
            .reduce(Int64(0)) { $0 + partials.savedBytes(for: $1) } : 0
        let required: Int64
        if sources == nil { required = max(StoragePlan.reserveBytes, plan.requiredFreeBytes - savedBytes) } else {
            let reserve = recipe.totalBytes.addingReportingOverflow(StoragePlan.reserveBytes)
            guard !reserve.overflow else { throw GenerationLibraryError.invalid("Invalid model recipe sizes.") }
            required = reserve.partialValue
        }
        guard required <= diskAvailable(root) else { throw GenerationLibraryError.invalid("Insufficient disk space for all model components and download scratch space.") }
        let manager = FileManager.default
        let stage = root.appending(path: ".staging/\(UUID().uuidString)", directoryHint: .isDirectory)
        let final = root.appending(path: "Installed/\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        var completed: Int64 = 0; var files: [InstalledModelComponent] = []
        var remainingTransfer = max(0, plan.downloadBytes - savedBytes)
        // Verified downloads stay in `.partial` (locked) until every component succeeds, so a later failure or
        // cancellation never throws away a completed multi-gigabyte file.
        var verifiedParts: [(part: URL, target: URL)] = []
        var partLocks: [PartialDownloadLock] = []
        defer { partLocks.removeAll() }
        for component in recipe.components {
            try Task.checkCancellation()
            // MLX loaders resolve config/tokenizer/shard names relative to the
            // model directory. Preserve their strictly validated hierarchy.
            let filename = Self.isManagedMLXPackage(recipe) ? component.filename : component.id + "." + URL(fileURLWithPath: component.filename).pathExtension
            let stagedTarget = stage.appending(path: filename)
            try manager.createDirectory(at: stagedTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
            var target = stagedTarget
            var downloadedPart: URL?
            let base = completed
            var reusedFrom: String?
            if let source = sources?[component.id] {
                let copy = Task.detached(priority: .utility) { [target] in try Self.copyStreaming(source: source, target: target, expectedBytes: component.byteSize, progress: { count in progress(.init(completedBytes: base + count, totalBytes: recipe.totalBytes, phase: "Importing " + component.role)) }) }
                try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
            } else {
                // Identical content earlier in this same recipe: copy the part already verified in this install.
                if let earlier = partials.url(for: component), verifiedParts.contains(where: { $0.part == earlier }), Self.cloneOrCopy(earlier, to: target) {
                    reusedFrom = "this download"
                    do { try checkDiskSpaceForNeeded(remainingTransfer, StoragePlan.reserveBytes, root: root) }
                    catch { try? manager.removeItem(at: target); throw error }
                } else if let owner = StoragePlan.reusableSource(for: component, installed: installedModels, excluding: recipe.id),
                   let file = owner.components.first(where: { $0.source.sha256.lowercased() == component.sha256.lowercased() && $0.source.byteSize == component.byteSize })?.fileURL,
                   Self.cloneOrCopy(file, to: target) {
                    reusedFrom = owner.name
                    // Reuse may silently degrade to a full copy; re-check free space like we do for downloads.
                    do { try checkDiskSpaceForNeeded(remainingTransfer, StoragePlan.reserveBytes, root: root) }
                    catch { try? manager.removeItem(at: target); throw error }
                    progress(.init(completedBytes: base, totalBytes: recipe.totalBytes, phase: "Reusing \(component.role) from \(owner.name)"))
                }
                if reusedFrom == nil {
                    _ = try partials.preparedDirectory(root: root)
                    guard let part = partials.url(for: component) else { throw GenerationLibraryError.invalid("Invalid pinned model component.") }
                    partLocks.append(try PartialDownloadLock(part))
                    let saved = partials.savedBytes(for: component)
                    let outstanding = component.byteSize - saved
                    // Free space can change while earlier components transfer; re-check before each download.
                    let withComponent = remainingTransfer.addingReportingOverflow(outstanding)
                    guard !withComponent.overflow else { throw GenerationLibraryError.invalid("Model component sizes overflow storage calculation.") }
                    try checkDiskSpaceForNeeded(withComponent.partialValue, StoragePlan.reserveBytes, root: root)
                    if saved == component.byteSize {
                        progress(.init(completedBytes: base + saved, totalBytes: recipe.totalBytes, phase: "Found a complete saved \(component.role) download"))
                    } else {
                        if saved > 0 { progress(.init(completedBytes: base + saved, totalBytes: recipe.totalBytes, phase: "Resuming \(component.role) download")) }
                        try await transport.download(from: component.downloadURL, to: part, expectedBytes: component.byteSize) { count in progress(.init(completedBytes: base + min(count, component.byteSize), totalBytes: recipe.totalBytes)) }
                    }
                    remainingTransfer = max(0, remainingTransfer - outstanding)
                    target = part; downloadedPart = part
                }
            }
            try Task.checkCancellation()
            progress(.init(completedBytes: completed, totalBytes: recipe.totalBytes, phase: "Verifying " + component.role))
            let inspectText = recipe.id.hasPrefix("text-gguf-") || (recipe.baseRecipeID != nil && recipe.kind == .text)
            // Reused files are verified exactly like downloads; a changed or corrupt source cannot enter this install.
            let verification = Task.detached(priority: .utility) { [target] in
                try Self.validateFile(target, component: component)
                if inspectText { try Task.checkCancellation(); try GGUFTextInspector.validate(target) }
            }
            do {
                try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() }
            } catch {
                // A saved download that fails its size, format or checksum check can never become valid: restart it next time.
                if let downloadedPart, !(error is CancellationError), !Task.isCancelled { try? manager.removeItem(at: downloadedPart) }
                throw error
            }
            if let downloadedPart { verifiedParts.append((downloadedPart, stagedTarget)) }
            completed += component.byteSize
            files.append(.init(id: component.id, role: component.role, fileURL: final.appending(path: filename), source: component))
            progress(.init(completedBytes: completed, totalBytes: recipe.totalBytes))
        }
        try Task.checkCancellation()
        // Keep each verified, locked content-addressed part in place until the completed model is registered.
        // This makes every finalisation failure recoverable and prevents another process from creating a new file at
        // a temporarily vacated partial path. APFS uses a clone; other filesystems fall back to a regular copy.
        for item in verifiedParts {
            guard Self.cloneOrCopy(item.part, to: item.target) else {
                throw GenerationLibraryError.invalid("Could not prepare a verified download for installation. The saved download was kept; install again to retry.")
            }
        }
        try manager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        let model = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID, components: files, installedAt: Date(), inferenceVerified: false, available: true, recipeSnapshot: recipe)
        try JSONEncoder().encode(recipe).write(to: stage.appending(path: ".recipe.json"), options: .atomic)
        var latest = try readRegistry()
        guard !latest.models.contains(where: { $0.id == model.id }) else { try? manager.removeItem(at: final); throw GenerationLibraryError.invalid("This model was installed by another operation.") }
        try manager.moveItem(at: stage, to: final)
        latest.models.append(model)
        do { try writeRegistry(latest) } catch { try? manager.removeItem(at: final); throw error }
        // Registration is the commit point. Failure to remove a now-redundant part is harmless and can be handled by
        // Discard Saved Downloads; removing it earlier would sacrifice resume data if registry persistence failed.
        for item in verifiedParts { try? manager.removeItem(at: item.part) }
        return model
    }
    /// Adds pinned components to an installed package in place. `upgraded` must be the installed recipe with new
    /// components appended (same identity, every existing file unchanged), so a 30 GB package gains a 365 MB
    /// decoder without downloading again. Only the new files are fetched (resumably) and SHA-256 verified. The
    /// registry write is the commit point; proof flags already earned are kept, because the existing weights did
    /// not change. Any failure before the commit leaves the package exactly as it was.
    func extendInstalledPackage(id: String, to upgraded: ModelRecipe, progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }) async throws -> InstalledGenerationModel {
        guard !busy else { throw GenerationLibraryError.invalid("Another model installation is running.") }
        busy = true; defer { busy = false }
        try validateRecipe(upgraded)
        let current = try installedRecipe(id: id)
        let existing = Array(upgraded.components.prefix(current.components.count))
        guard upgraded.id == current.id, upgraded.name == current.name, upgraded.kind == current.kind, upgraded.engineID == current.engineID,
              upgraded.runtimeProfile == current.runtimeProfile, upgraded.components.count > current.components.count, existing == current.components else {
            throw GenerationLibraryError.invalid("This package update would change the model's existing files, so it cannot be added in place. Install it as a new model instead.")
        }
        guard let model = try readRegistry().models.first(where: { $0.id == id }) else { throw GenerationLibraryError.invalid("The selected model is not installed.") }
        let package = try ownedInstallDirectory(for: model)
        let added = Array(upgraded.components.dropFirst(current.components.count))
        let mlxPackage = Self.isManagedMLXPackage(upgraded)
        func filename(_ component: ModelComponent) -> String { mlxPackage ? component.filename : component.id + "." + URL(fileURLWithPath: component.filename).pathExtension }
        let existingNames = Set(model.components.map { $0.fileURL.standardizedFileURL.path })
        let addedBytes = added.reduce(Int64(0)) { $0.addingReportingOverflow($1.byteSize).partialValue }
        try checkDiskSpaceForNeeded(addedBytes, StoragePlan.reserveBytes, root: root)

        let manager = FileManager.default
        let partials = PartialDownloadStore(root: root)
        var placed: [URL] = [], files: [InstalledModelComponent] = [], parts: [URL] = [], locks: [PartialDownloadLock] = []
        var committed = false
        defer {
            locks.removeAll()
            if !committed { for url in placed { try? manager.removeItem(at: url) } }
        }
        var completed: Int64 = 0
        for component in added {
            try Task.checkCancellation()
            let target = package.appending(path: filename(component))
            guard !existingNames.contains(target.standardizedFileURL.path) else { throw GenerationLibraryError.invalid("Invalid model package update.") }
            // A file left by an interrupted earlier attempt is not registered; replace it with a verified copy.
            try? manager.removeItem(at: target)
            _ = try partials.preparedDirectory(root: root)
            guard let part = partials.url(for: component) else { throw GenerationLibraryError.invalid("Invalid pinned model component.") }
            locks.append(try PartialDownloadLock(part))
            let base = completed
            if partials.savedBytes(for: component) != component.byteSize {
                try await transport.download(from: component.downloadURL, to: part, expectedBytes: component.byteSize) { count in
                    progress(.init(completedBytes: base + min(count, component.byteSize), totalBytes: addedBytes, phase: "Downloading " + component.role))
                }
            }
            try Task.checkCancellation()
            progress(.init(completedBytes: base, totalBytes: addedBytes, phase: "Verifying " + component.role))
            let verification = Task.detached(priority: .utility) { try Self.validateFile(part, component: component) }
            do { try await withTaskCancellationHandler { try await verification.value } onCancel: { verification.cancel() } }
            catch {
                if !(error is CancellationError), !Task.isCancelled { try? manager.removeItem(at: part) }
                throw error
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard Self.cloneOrCopy(part, to: target) else { throw GenerationLibraryError.invalid("Could not add a verified file to the installed package. The saved download was kept; try again.") }
            placed.append(target); parts.append(part)
            files.append(.init(id: component.id, role: component.role, fileURL: target, source: component))
            completed += component.byteSize
            progress(.init(completedBytes: completed, totalBytes: addedBytes))
        }
        try Task.checkCancellation()

        var extended = InstalledGenerationModel(id: model.id, name: upgraded.name, kind: model.kind, engineID: model.engineID, components: model.components + files,
                                                installedAt: model.installedAt, inferenceVerified: model.inferenceVerified, available: true, recipeSnapshot: upgraded)
        extended.verifiedVideoTasks = model.verifiedVideoTasks; extended.verifiedImageTasks = model.verifiedImageTasks; extended.verifiedUpscale = model.verifiedUpscale
        // The new manifest waits beside the old one until the registry commits; `installedRecipe` promotes it
        // if the app stops in between, and discards it if the registry never changed.
        let pending = package.appending(path: Self.pendingManifestName)
        try JSONEncoder().encode(upgraded).write(to: pending, options: .atomic)
        var registry = try readRegistry()
        guard let index = registry.models.firstIndex(where: { $0.id == id }), registry.models[index] == model else {
            try? manager.removeItem(at: pending)
            throw GenerationLibraryError.invalid("The installed model changed while its files were being added. Try again.")
        }
        registry.models[index] = extended
        do { try writeRegistry(registry) } catch { try? manager.removeItem(at: pending); throw error }
        committed = true
        finishPendingExtension(extended, manifestURL: package.appending(path: ".recipe.json"))
        for part in parts { try? manager.removeItem(at: part) }
        return extended
    }

    private static let pendingManifestName = ".recipe.pending.json"

    /// Completes or discards an in-place extension that stopped between its registry commit and its manifest swap.
    private func finishPendingExtension(_ model: InstalledGenerationModel, manifestURL: URL) {
        let pending = manifestURL.deletingLastPathComponent().appending(path: Self.pendingManifestName)
        guard let data = try? Data(contentsOf: pending) else { return }
        if let recipe = try? JSONDecoder().decode(ModelRecipe.self, from: data), Self.matches(model, recipe: recipe), model.recipeSnapshot == recipe {
            let manager = FileManager.default
            if manager.fileExists(atPath: manifestURL.path) { _ = try? manager.replaceItemAt(manifestURL, withItemAt: pending) }
            else { try? manager.moveItem(at: pending, to: manifestURL) }
        } else {
            try? FileManager.default.removeItem(at: pending)
        }
    }

    /// APFS clone when available (no additional blocks until modified), otherwise a regular copy. Never a hard link or
    /// symlink, so removing either installation cannot affect the other.
    nonisolated static func cloneOrCopy(_ source: URL, to target: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: source.path) else { return false }
        return copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0
    }
    nonisolated static func volumeSupportsCloning(_ url: URL) -> Bool {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning ?? false
    }
    private func validateRecipe(_ recipe: ModelRecipe) throws {
        guard catalog.contains(recipe) || admittedUpdates[recipe.id] == recipe || admittedTextRecipes[recipe.id] == recipe || admittedMLXRecipes[recipe.id] == recipe || admittedUserRecipes[recipe.id] == recipe else { throw GenerationLibraryError.invalid("This model recipe is not in the supported or imported model catalog.") }
        try validateRecipeShape(recipe)
    }
    private func validateRecipeShape(_ recipe: ModelRecipe) throws {
        func safe(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        guard safe(recipe.id), !recipe.components.isEmpty, Set(recipe.components.map(\.id)).count == recipe.components.count, recipe.totalBytes > 0, recipe.totalBytes < Int64.max else { throw GenerationLibraryError.invalid("Invalid model recipe.") }
        let isMLXPackage = Self.isManagedMLXPackage(recipe)
        let allowedExtensions: Set<String> = isMLXPackage ? ["safetensors", "json", "jinja", "model", "txt"] : ["gguf", "safetensors", "pth"]
        for component in recipe.components {
            let pathParts = component.filename.split(separator: "/", omittingEmptySubsequences: false)
            let sourcePathParts = (component.sourceFilename ?? component.filename).split(separator: "/", omittingEmptySubsequences: false)
            let safePackagePath = isMLXPackage && !pathParts.isEmpty && pathParts.allSatisfy { part in
                !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            }
            let safeSourcePath = !sourcePathParts.isEmpty && sourcePathParts.allSatisfy { part in
                !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
            }
            guard safe(component.id), component.byteSize > 0, component.sha256.count == 64, component.sha256.allSatisfy(\.isHexDigit), component.revision.count == 40, component.revision.allSatisfy(\.isHexDigit), (try? Self.parseHubLink(component.repository)) == component.repository,
                  !component.filename.hasPrefix("/"), !component.filename.split(separator: "/").contains(".."), safeSourcePath,
                  (!isMLXPackage || safePackagePath), allowedExtensions.contains(URL(fileURLWithPath: component.filename).pathExtension) else { throw GenerationLibraryError.invalid("Invalid pinned model component.") }
        }
    }
    private static func isManagedMLXPackage(_ recipe: ModelRecipe) -> Bool {
        (recipe.engineID == "mlx-vlm" && recipe.runtimeProfile == "mlx-vlm")
            || (recipe.engineID == "mlx-fastvideo" && recipe.runtimeProfile == "mlx-fastvideo")
            || (recipe.engineID == "mlx-ltx" && recipe.runtimeProfile == "mlx-ltx")
            || (recipe.engineID == "mlx-audio" && recipe.runtimeProfile == "mlx-audio")
    }
    nonisolated private static func copyStreaming(source: URL, target: URL, expectedBytes: Int64, progress: @Sendable (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target); defer { try? output.close() }
        var count: Int64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); count += Int64(data.count)
            guard count <= expectedBytes else { throw GenerationLibraryError.invalid("Imported file exceeds the expected size.") }
            try output.write(contentsOf: data); progress(count)
        }
    }
    nonisolated private static func validateFile(_ url: URL, component: ModelComponent) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == component.byteSize else { throw GenerationLibraryError.invalid("Model component size does not match its pinned recipe.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let header = try handle.read(upToCount: 24) ?? Data()
        if component.filename.hasSuffix(".gguf") {
            guard header.count == 24, header.prefix(4) == Data("GGUF".utf8), [2,3].contains(header[4]), header[5...7].allSatisfy({ $0 == 0 }) else { throw GenerationLibraryError.invalid("Model component is not a supported GGUF file.") }
        } else if component.filename.hasSuffix(".pth") {
            // Modern torch.save checkpoints are a ZIP archive; this is the local-file-header magic every
            // .pth GenStudio pins begins with (confirmed against both pinned upscaler mirrors). SHA-256
            // below remains the authoritative integrity check; this only rejects an obviously wrong file.
            guard header.count >= 4, header.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else { throw GenerationLibraryError.invalid("Model component is not a supported PyTorch checkpoint (.pth) file.") }
        } else if component.filename.hasSuffix(".safetensors") {
            guard header.count >= 8 else { throw GenerationLibraryError.invalid("Truncated safetensors file.") }
            let length = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard length > 1, length <= 16 * 1024 * 1024, length < UInt64(component.byteSize - 8) else { throw GenerationLibraryError.invalid("Invalid safetensors header.") }
        } else {
            // Config/tokenizer metadata is still SHA-256 pinned. Parse JSON
            // where applicable so an HTML error page cannot look installable.
            guard header.first != nil else { throw GenerationLibraryError.invalid("Empty model metadata file.") }
            if component.filename.hasSuffix(".json") {
                let data = try Data(contentsOf: url)
                guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw GenerationLibraryError.invalid("Invalid JSON model metadata file.") }
            }
        }
        try handle.seek(toOffset: 0); var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == component.sha256.lowercased() else { throw GenerationLibraryError.invalid("Checksum mismatch. The downloaded/imported file is not the selected verified recipe.") }
    }
    func remove(id: String) throws {
        guard !busy else { throw GenerationLibraryError.invalid("Wait for the current model installation to finish.") }
        var registry = try readRegistry(); guard let model = registry.models.first(where: { $0.id == id }) else { return }
        let directory: URL
        do { directory = try ownedInstallDirectory(for: model) }
        catch { throw GenerationLibraryError.invalid("Refusing to remove files outside this library's owned model directory.") }
        let manager = FileManager.default
        let trash = root.appending(path: ".trash/\(UUID().uuidString)", directoryHint: .isDirectory)
        let existed = manager.fileExists(atPath: directory.path)
        if existed { try manager.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true); try manager.moveItem(at: directory, to: trash) }
        registry.models.removeAll { $0.id == id }
        do { try writeRegistry(registry) } catch { if existed { try? manager.moveItem(at: trash, to: directory) }; throw error }
        if existed { do { try manager.removeItem(at: trash) } catch { throw GenerationLibraryError.invalid("Model was unregistered, but its staged removal remains in .trash. Use Clean Interrupted Downloads to recover disk space.") } }
    }
    /// Saved partial downloads that a later install of the same pinned component can resume.
    func partialDownloadSummary() throws -> (count: Int, bytes: Int64) {
        let store = PartialDownloadStore(root: root)
        guard FileManager.default.fileExists(atPath: store.directory.path) else { return (0, 0) }
        try store.validateLocation(root: root)
        let entries = store.entries()
        return (entries.count, entries.reduce(0) { $0 + $1.bytes })
    }
    /// Explicit discard of saved partial downloads. Resume progress for these files is lost.
    func discardPartialDownloads() throws -> Int {
        guard !busy else { throw GenerationLibraryError.invalid("Wait for the current installation before discarding saved downloads.") }
        let store = PartialDownloadStore(root: root)
        guard FileManager.default.fileExists(atPath: store.directory.path) else { return 0 }
        try store.validateLocation(root: root)
        var removed = 0
        for entry in store.entries() {
            // Skip a file another GenStudio process is writing.
            guard let lock = try? PartialDownloadLock(entry.url) else { continue }
            try FileManager.default.removeItem(at: entry.url); removed += 1
            withExtendedLifetime(lock) {}
        }
        return removed
    }
    private func pruneAbandonedPartials(keeping recipe: ModelRecipe) throws {
        let store = PartialDownloadStore(root: root)
        guard FileManager.default.fileExists(atPath: store.directory.path) else { return }
        try store.validateLocation(root: root)
        let keep = Set(recipe.components.compactMap { store.url(for: $0)?.lastPathComponent })
        for entry in store.entries() where !keep.contains(entry.url.lastPathComponent) && Date().timeIntervalSince(entry.modified) > PartialDownloadStore.retention {
            guard let lock = try? PartialDownloadLock(entry.url) else { continue }
            try? FileManager.default.removeItem(at: entry.url)
            withExtendedLifetime(lock) {}
        }
    }
    /// Explicit recovery, called only when this app has no active installations.
    func cleanupInterruptedInstalls() throws -> Int {
        guard !busy else { throw GenerationLibraryError.invalid("Wait for the current installation before cleaning partial files.") }
        var removed = 0
        for name in [".staging", ".trash"] {
            let directory = root.appending(path: name)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard directory.standardizedFileURL.resolvingSymlinksInPath().path == root.standardizedFileURL.resolvingSymlinksInPath().appending(path: name).path else { throw GenerationLibraryError.invalid("Refusing to clean a redirected staging directory.") }
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard UUID(uuidString: item.lastPathComponent) != nil else { continue }
                try FileManager.default.removeItem(at: item); removed += 1
            }
        }
        return removed
    }
    nonisolated static func parseHubLink(_ input: String) throws -> String {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if clean.contains("://") {
            guard let url = URL(string: clean), url.scheme == "https", url.host?.lowercased() == "huggingface.co", url.user == nil, url.password == nil else { throw GenerationLibraryError.invalid("Use a Hugging Face model link or owner/model identifier.") }
            path = url.path
        } else { path = clean }
        let pieces = path.split(separator: "/")
        guard pieces.count >= 2, !["datasets", "spaces", "api"].contains(String(pieces[0])), pieces.prefix(2).allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }), pieces[0] != "..", pieces[1] != ".." else { throw GenerationLibraryError.invalid("Use a model repository in owner/model form.") }
        return pieces.prefix(2).joined(separator: "/")
    }
    func search(query: String) async throws -> [HubModelSummary] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [.init(name: "search", value: query), .init(name: "limit", value: "30"), .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GenerationLibraryError.invalid("Hugging Face search is unavailable. Installed models remain available offline.") }
        struct Entry: Decodable { let id: String; let downloads: Int?; let likes: Int?; let pipeline_tag: String? }
        return try JSONDecoder().decode([Entry].self, from: data).map { entry in
            .init(id: entry.id, downloads: entry.downloads, likes: entry.likes, pipelineTag: entry.pipeline_tag, recipeID: ModelCatalog.recipes.first { $0.components.contains { $0.repository == entry.id } }?.id)
        }
    }
}
