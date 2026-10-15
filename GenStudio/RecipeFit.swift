import Foundation

/// Disk needed to install a recipe, crediting components already installed with identical content (SHA-256 + size).
struct StoragePlan: Equatable, Sendable {
    struct Reuse: Equatable, Sendable {
        let componentID: String
        let installedModelID: String
        let installedModelName: String
        let bytes: Int64
    }
    static let reserveBytes: Int64 = 256 * 1024 * 1024

    let totalBytes: Int64
    let downloadBytes: Int64
    let reused: [Reuse]
    /// Largest single transfer: the download is momentarily present in temporary space and in staging.
    let stagingBytes: Int64
    /// True when reused files are APFS clones that share blocks until modified.
    let clonesShareStorage: Bool
    let requiredFreeBytes: Int64
    var reusedBytes: Int64 { reused.reduce(0) { $0 + $1.bytes } }

    /// Nil when metadata is invalid or arithmetic overflows; nil is never treated as zero.
    static func make(recipe: ModelRecipe, installed: [InstalledGenerationModel], clonesShareStorage: Bool) -> StoragePlan? {
        guard !recipe.components.isEmpty, recipe.components.allSatisfy({ $0.byteSize > 0 }) else { return nil }
        var total: Int64 = 0, download: Int64 = 0, largest: Int64 = 0, reused: [Reuse] = []
        func add(_ a: Int64, _ b: Int64) -> Int64? { let sum = a.addingReportingOverflow(b); return sum.overflow ? nil : sum.partialValue }
        for component in recipe.components {
            guard let nextTotal = add(total, component.byteSize) else { return nil }
            total = nextTotal
            if let source = reusableSource(for: component, installed: installed, excluding: recipe.id) {
                reused.append(.init(componentID: component.id, installedModelID: source.id, installedModelName: source.name, bytes: component.byteSize))
            } else {
                guard let next = add(download, component.byteSize) else { return nil }
                download = next; largest = max(largest, component.byteSize)
            }
        }
        let reusedBytes = reused.reduce(Int64(0)) { $0 + $1.bytes }
        guard let copied = add(download, clonesShareStorage ? 0 : reusedBytes), let staged = add(copied, largest), let required = add(staged, reserveBytes) else { return nil }
        return .init(totalBytes: total, downloadBytes: download, reused: reused, stagingBytes: largest, clonesShareStorage: clonesShareStorage, requiredFreeBytes: required)
    }

    static func reusableSource(for component: ModelComponent, installed: [InstalledGenerationModel], excluding recipeID: String) -> InstalledGenerationModel? {
        installed.first { model in
            model.id != recipeID && model.available && model.components.contains { $0.source.sha256.lowercased() == component.sha256.lowercased() && $0.source.byteSize == component.byteSize }
        }
    }
}

/// Task-level adapter/proof status shown next to a recipe.
struct RecipeTaskStatus: Identifiable, Hashable, Sendable {
    enum Proof: Hashable, Sendable { case verified(String), awaitingProof, unavailable(String) }
    var id: String { title }
    let title: String
    let proof: Proof
    let note: String
    let measured: String?

    static func statuses(recipeID: String, images: [ImageCapability] = ImageCapabilityRegistry.shipped, videos: [VideoCapability] = VideoCapabilityRegistry.shipped, upscales: [UpscaleCapability] = UpscaleCapabilityRegistry.shipped, installed: InstalledGenerationModel? = nil) -> [RecipeTaskStatus] {
        func proof(_ readiness: CapabilityReadiness) -> Proof {
            switch readiness {
            case .verified(let evidence): .verified(evidence)
            case .awaitingProof: .awaitingProof
            case .unavailable(let reason): .unavailable(reason)
            }
        }
        let image = ImageTask.allCases.compactMap { task in ImageCapabilityRegistry.capability(recipeID: recipeID, task: task, in: images).map {
            let localProof = installed?.available == true && installed?.hasVerifiedImageTask(task) == true
            return RecipeTaskStatus(title: $0.conditioning == .referenceImage ? "Reference image edit" : task.title,
                                    proof: localProof ? .verified("Decoded local render") : proof($0.readiness), note: $0.qualityNote, measured: $0.measuredBaseline)
        } }
        let video = VideoTask.allCases.compactMap { task in VideoCapabilityRegistry.capability(recipeID: recipeID, task: task, in: videos).map {
            let localProof = installed?.available == true && installed?.hasVerifiedVideoTask(task) == true
            return RecipeTaskStatus(title: task.title, proof: localProof ? .verified("Decoded local render") : proof($0.readiness), note: $0.qualityNote, measured: $0.measuredBaseline)
        } }
        let upscale = UpscaleCapabilityRegistry.capability(recipeID: recipeID, in: upscales).map { capability -> RecipeTaskStatus in
            let localProof = installed?.available == true && installed?.hasVerifiedUpscale == true
            return RecipeTaskStatus(title: "Upscale", proof: localProof ? .verified("Decoded local render") : proof(capability.readiness), note: capability.qualityNote, measured: capability.measuredBaseline)
        }
        return image + video + [upscale].compactMap { $0 }
    }
}

/// Hardware, storage, adapter and proof assessment for image/video recipes. Pure, so every branch is tested.
struct RecipeFit: Sendable {
    enum State: String, Sendable {
        /// Known platform mismatch with the bundled engines.
        case incompatible
        /// A required resource is known to be short, or could not be established.
        case insufficientResources
        /// The exact files are known, but this build has no adapter for any task.
        case adapterNeeded
        /// An adapter exists and resources pass, but the estimate leaves limited headroom.
        case possibleDemanding
        /// An adapter exists and resources pass; no decoded local render proves it yet.
        case adapterUnverified
        /// At least one task has a decoded local render through GenStudio's adapter.
        case locallyVerified
    }
    let state: State
    let label: String
    let detail: String
    let storage: StoragePlan?
    let memoryFloorBytes: UInt64
    let tasks: [RecipeTaskStatus]
    let installed: Bool
    var canInstall: Bool { !installed && [.possibleDemanding, .adapterUnverified, .locallyVerified].contains(state) }

    static func assess(recipe: ModelRecipe, hardware: HardwareProfile?, installed: [InstalledGenerationModel],
                       images: [ImageCapability] = ImageCapabilityRegistry.shipped, videos: [VideoCapability] = VideoCapabilityRegistry.shipped, upscales: [UpscaleCapability] = UpscaleCapabilityRegistry.shipped) -> RecipeFit {
        let existing = installed.first { $0.id == recipe.id }
        let tasks = RecipeTaskStatus.statuses(recipeID: recipe.id, images: images, videos: videos, upscales: upscales, installed: existing)
        let isInstalled = existing?.available == true
        let storage = hardware.flatMap { StoragePlan.make(recipe: recipe, installed: installed, clonesShareStorage: $0.volumeSupportsCloning) }
        func result(_ state: State, _ label: String, _ detail: String) -> RecipeFit {
            .init(state: state, label: label, detail: detail, storage: storage, memoryFloorBytes: recipe.minimumMemoryBytes, tasks: tasks, installed: isInstalled)
        }
        if let issue = ModelCompatibility.platformIssue(hardware) {
            return result(issue.state == .incompatible ? .incompatible : .insufficientResources, issue.label, issue.detail)
        }
        guard let hardware else { return result(.insufficientResources, "Checking this Mac", "Computer information is unavailable.") }
        guard tasks.contains(where: { status in
            if case .unavailable = status.proof { return false }
            return true
        }) else {
            return result(.adapterNeeded, "Adapter needed", "The exact files are pinned, but this version of GenStudio has no adapter that can run them, so installation is disabled.")
        }
        guard hardware.memoryBytes > 0 else { return result(.insufficientResources, "Memory not established", "GenStudio could not read this Mac's memory.") }
        let gib = Double(1024 * 1024 * 1024)
        let floorText = "\((Double(recipe.minimumMemoryBytes) / gib).formatted(.number.precision(.fractionLength(0)))) GB"
        if recipe.minimumMemoryBytes > hardware.memoryBytes {
            return result(.insufficientResources, "Not enough memory", "Its weights alone need at least \(floorText), more than this Mac's memory.")
        }
        if let existing, !existing.available {
            return result(.insufficientResources, "Installed files missing", "Repair or reinstall the complete recipe before using it.")
        }
        if !isInstalled {
            guard let storage else { return result(.insufficientResources, "Storage not established", "The complete download and staging requirement could not be established.") }
            guard hardware.freeDiskBytes > 0 else { return result(.insufficientResources, "Free storage unknown", "GenStudio could not read free space on the model-library drive.") }
            guard hardware.freeDiskBytes >= storage.requiredFreeBytes else {
                return result(.insufficientResources, "Needs more free storage", "Download, staging and reserve need \(ModelLibraryViewModel.bytes(storage.requiredFreeBytes)) free; this drive has \(ModelLibraryViewModel.bytes(hardware.freeDiskBytes)).")
            }
        }
        let verified = tasks.filter { if case .verified = $0.proof { return true }; return false }
        let demandingReason = MediaModelCatalog.profile(recipe.id)?.demandingReason
        let gpuShort = hardware.gpuWorkingSetBytes > 0 && recipe.minimumMemoryBytes > hardware.gpuWorkingSetBytes
        if demandingReason != nil || gpuShort || recipe.minimumMemoryBytes > hardware.memoryBytes / 2 {
            let why = demandingReason ?? (gpuShort ? "The weight floor (\(floorText)) exceeds Metal's recommended working set on this Mac." : "The weight floor (\(floorText)) is more than half of this Mac's memory.")
            return result(.possibleDemanding, "Possible, but demanding", why + (verified.isEmpty ? " No local render has validated this adapter yet." : " Timing is only known for the measured settings shown."))
        }
        if !verified.isEmpty {
            return result(.locallyVerified, "Verified locally", "A decoded render through GenStudio's adapter validated \(verified.map(\.title).joined(separator: ", ")). Other tasks and settings keep their own status; speed and quality vary.")
        }
        return result(.adapterUnverified, "Adapter available · not yet measured", "An adapter and exact files exist and this Mac passes the weight-floor and storage checks. Once installed, the recipe can run directly; GenStudio will decode and validate the output and record the result.")
    }
}
