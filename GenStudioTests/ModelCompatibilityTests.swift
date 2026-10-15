import XCTest
@testable import GenStudio

final class ModelCompatibilityTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private var textRecipe: ModelRecipe { ModelCatalog.recipes.first { $0.id == "qwen25-05b-q4km" }! }
    private func mac(chip: String = "Apple M1 Max", memory: UInt64 = 64 * 1024 * 1024 * 1024,
                     os: String = "Version 26.6.2 (Build 25G100)", disk: Int64 = 800 * 1024 * 1024 * 1024) -> HardwareProfile {
        .init(chip: chip, memoryBytes: memory, osVersion: os, freeDiskBytes: disk)
    }
    private func installed(_ recipe: ModelRecipe, available: Bool = true) -> InstalledGenerationModel {
        .init(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
            components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/test/\($0.filename)"), source: $0) },
            installedAt: Date(), inferenceVerified: false, available: available, recipeSnapshot: recipe)
    }
    private func detail(_ recipe: ModelRecipe, revision: String? = nil, hash: String? = nil) -> DiscoveryDetail {
        .init(model: .init(id: recipe.components[0].repository, sha: revision ?? recipe.components[0].revision,
            pipelineTag: "text-generation", library: "gguf", license: "Apache-2.0", gated: false, downloads: nil, likes: nil,
            createdAt: nil, lastModified: nil, tags: ["cuda", "linux", "windows"]),
            files: recipe.components.map { .init(path: $0.filename, bytes: $0.byteSize, sha256: hash ?? $0.sha256) },
            architectures: [], modelType: nil, contextLength: nil, requiresCustomCode: false, configNote: nil,
            ggufArchitectureHint: "qwen2", fetchedAt: Date(), isCached: false)
    }

    func testSupportedMacDoesNotNeedAnInstalledLanguageModelOrKeywordClassifier() {
        let result = ModelCompatibility.assess(recipe: textRecipe, hardware: mac())
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.state, .supported)
        XCTAssertTrue(ModelCompatibility.assess(detail: detail(textRecipe), hardware: mac()).eligible,
            "CUDA/Linux tags are not a reason to reject a verified Apple Silicon package.")
        XCTAssertTrue(result.detail.contains("does not promise"))
    }

    func testKnownPlatformIncompatibilityIsDifferentFromUnknownHardware() {
        for machine in [mac(chip: "Intel Core i9"), mac(os: "macOS 15.6")] {
            let result = ModelCompatibility.assess(recipe: textRecipe, hardware: machine)
            XCTAssertEqual(result.state, .incompatible)
            XCTAssertFalse(result.eligible)
        }
        for machine in [nil, mac(chip: "Unknown"), mac(os: "Unknown"), mac(memory: 0)] as [HardwareProfile?] {
            let result = ModelCompatibility.assess(recipe: textRecipe, hardware: machine)
            XCTAssertEqual(result.state, .unknownResources)
            XCTAssertFalse(result.eligible)
        }
        XCTAssertTrue(ModelCompatibility.assess(recipe: textRecipe, hardware: mac(os: "26.0")).eligible)
    }

    func testMemoryEstimatesDoNotClaimHardIncompatibility() {
        let below = ModelCompatibility.assess(recipe: textRecipe, hardware: mac(memory: 2 * gib))
        XCTAssertEqual(below.state, .demanding)
        XCTAssertFalse(below.eligible)
        XCTAssertTrue(below.detail.contains("not a proven incompatibility"))
        let constrained = ModelCompatibility.assess(recipe: textRecipe, hardware: mac(memory: 4 * gib))
        XCTAssertEqual(constrained.state, .demanding)
        XCTAssertTrue(constrained.eligible)
        XCTAssertEqual(ModelCompatibility.assess(recipe: textRecipe, hardware: mac(memory: 8 * gib)).state, .supported)
    }

    func testStorageIncludesStagingAndInstalledModelsDoNotRequireAnotherDownload() throws {
        let required = try XCTUnwrap(ModelCompatibility.installationStorageBytes(recipe: textRecipe))
        XCTAssertEqual(required, textRecipe.totalBytes * 2 + 256 * 1024 * 1024)
        let short = ModelCompatibility.assess(recipe: textRecipe, hardware: mac(disk: required - 1))
        XCTAssertEqual(short.state, .insufficientStorage)
        XCTAssertFalse(short.eligible)
        XCTAssertTrue(ModelCompatibility.assess(recipe: textRecipe, hardware: mac(disk: required)).eligible)
        XCTAssertEqual(ModelCompatibility.assess(recipe: textRecipe, hardware: mac(disk: 0)).state, .unknownResources)
        let existing = ModelCompatibility.assess(recipe: textRecipe, hardware: mac(disk: 0), installed: installed(textRecipe))
        XCTAssertTrue(existing.eligible)
        XCTAssertNil(existing.requiredStorageBytes)
        XCTAssertFalse(ModelCompatibility.assess(recipe: textRecipe, hardware: mac(), installed: installed(textRecipe, available: false)).eligible)
    }

    func testUnsupportedAdaptersAndModifiedCatalogMetadataCannotClaimReadiness() {
        let video = ModelCatalog.recipes.first { $0.kind == .video }!
        // Only the exact proven Wan T2V recipe is supported; an altered video manifest cannot borrow that readiness.
        XCTAssertTrue(ModelCompatibility.assess(recipe: video, hardware: mac()).eligible)
        let otherVideo = ModelRecipe(id: "wan21-flf2v-invented", name: video.name, kind: .video, engineID: video.engineID, components: video.components, runtimeReady: true, minimumMemoryBytes: video.minimumMemoryBytes)
        XCTAssertEqual(ModelCompatibility.assess(recipe: otherVideo, hardware: mac()).state, .unsupported)
        let invented = ModelRecipe(id: textRecipe.id, name: textRecipe.name, kind: .text, engineID: "cuda-only-engine",
            components: textRecipe.components, runtimeReady: true, minimumMemoryBytes: textRecipe.minimumMemoryBytes)
        XCTAssertFalse(ModelCompatibility.assess(recipe: invented, hardware: mac()).eligible)
        let altered = ModelRecipe(id: textRecipe.id, name: textRecipe.name, kind: .text, engineID: textRecipe.engineID,
            components: textRecipe.components, runtimeReady: true, minimumMemoryBytes: 1)
        XCTAssertFalse(ModelCompatibility.assess(recipe: altered, hardware: mac()).eligible)
        XCTAssertFalse(ModelCompatibility.assess(detail: detail(textRecipe, revision: String(repeating: "b", count: 40)), hardware: mac()).eligible)
        XCTAssertFalse(ModelCompatibility.assess(detail: detail(textRecipe, hash: String(repeating: "b", count: 64)), hardware: mac()).eligible)
    }

    func testExperimentalTextNeedsInstalledAdmissionBeforeDefaultFeedEligibility() {
        let recipe = ModelRecipe(id: "text-gguf-admitted-fixture", name: "Imported text model", kind: .text, engineID: "llama.cpp",
            components: textRecipe.components, runtimeReady: false, minimumMemoryBytes: textRecipe.minimumMemoryBytes)
        XCTAssertEqual(ModelCompatibility.assess(recipe: recipe, hardware: mac()).state, .needsValidation)
        XCTAssertFalse(ModelCompatibility.assess(recipe: recipe, hardware: mac()).eligible)
        let admitted = installed(recipe)
        XCTAssertTrue(ModelCompatibility.assess(recipe: recipe, hardware: mac(), installed: admitted).eligible)
        XCTAssertFalse(ModelCompatibility.assess(recipe: recipe, hardware: mac(), installed: installed(recipe, available: false)).eligible)
        var unproven = admitted
        unproven.recipeSnapshot = nil
        XCTAssertFalse(ModelCompatibility.assess(recipe: recipe, hardware: mac(), installed: unproven).eligible)
    }

    func testInstalledAdapterReadyVideoModelIsNeverReportedUnsupportedOrIncompatible() {
        let recipe = try! XCTUnwrap(MediaModelCatalog.recipes.first { $0.id == MediaModelCatalog.animateDiffRecipeID })
        XCTAssertTrue(VideoCapabilityRegistry.hasAdapter(recipe.id), "Precondition: GenStudio ships an adapter for this recipe.")
        XCTAssertFalse(VideoCapabilityRegistry.supportsRecipe(recipe.id), "Precondition: that adapter has no decoded proof anywhere yet.")
        // Not installed: this stays out of the proven-only default "Compatible Model Feed" as before.
        XCTAssertEqual(ModelCompatibility.assess(recipe: recipe, hardware: mac()).state, .unsupported)
        // Installed: the model is already running on this Mac, so it can never be honestly
        // reported "Not supported in this app" or "Incompatible with this build" merely
        // because no decoded render has verified it anywhere yet.
        let result = ModelCompatibility.assess(recipe: recipe, hardware: mac(), installed: installed(recipe))
        XCTAssertTrue(result.eligible)
        XCTAssertNotEqual(result.state, .unsupported)
        XCTAssertNotEqual(result.state, .incompatible)
        XCTAssertEqual(result.label, "Installed · adapter not yet verified")
        XCTAssertFalse(result.detail.localizedCaseInsensitiveContains("no verified adapter"), result.detail)
        // Missing files on disk still surface honestly, not as "not supported".
        let missing = ModelCompatibility.assess(recipe: recipe, hardware: mac(), installed: installed(recipe, available: false))
        XCTAssertFalse(missing.eligible)
        XCTAssertEqual(missing.state, .needsValidation)
    }

    func testStorageOverflowNeverWrapsIntoASmallDownload() {
        let base = textRecipe.components[0]
        let huge = ModelComponent(id: base.id, role: base.role, repository: base.repository, revision: base.revision,
            filename: base.filename, byteSize: Int64.max, sha256: base.sha256, license: base.license)
        let recipe = ModelRecipe(id: "oversize", name: "Oversize", kind: .text, engineID: "llama.cpp", components: [huge], runtimeReady: false, minimumMemoryBytes: gib)
        XCTAssertNil(ModelCompatibility.installationStorageBytes(recipe: recipe))
    }
}
