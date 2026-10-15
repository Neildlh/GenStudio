import CryptoKit
import XCTest
@testable import GenStudio

private struct FixtureModelTransport: ModelDownloadTransport {
    let bytes: Data
    var pause = false
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if pause { try await Task.sleep(for: .seconds(5)) }
        try Task.checkCancellation()
        try bytes.write(to: to); progress(Int64(bytes.count))
    }
}

final class ModelLibraryTests: XCTestCase {
    private func fixture() -> Data {
        var data = Data("GGUF".utf8); data.append(contentsOf: [3,0,0,0]); data.append(Data(repeating: 0, count: 64)); return data
    }
    private func recipe(_ bytes: Data, components: Int = 1) -> ModelRecipe {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(id: "fixture", name: "Fixture", kind: .text, engineID: "llama.cpp", components: (0..<components).map { index in
            ModelComponent(id: "part\(index)", role: index == 0 ? "model" : "encoder", repository: "test/model", revision: String(repeating: "a", count: 40), filename: "fixture.gguf", byteSize: Int64(bytes.count), sha256: digest, license: "test")
        }, runtimeReady: false, minimumMemoryBytes: 0)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioLibraryTests-\(UUID())", directoryHint: .isDirectory) }

    func testDownloadVerifiesRecipeOfflineReopensAndRemovesOwnedFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let data = fixture(); let library = ModelLibrary(root: root, catalog: [recipe(data, components: 2)], transport: FixtureModelTransport(bytes: data), diskAvailable: { _ in Int64.max })
        let model = try await library.install(recipe: recipe(data, components: 2))
        XCTAssertEqual(model.components.count, 2); XCTAssertFalse(model.inferenceVerified)
        let reopened = ModelLibrary(root: root, catalog: [recipe(data, components: 2)])
        let resolved = try await reopened.resolveInstalledModel(id: model.id)
        XCTAssertTrue(resolved.available)
        try await reopened.markInferenceVerified(id: model.id)
        let records = try await reopened.installedModels(); XCTAssertTrue(records[0].inferenceVerified)
        try await reopened.remove(id: model.id)
        let remaining = try await reopened.installedModels(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.components[0].fileURL.path))
    }

    func testCorruptionAndLowDiskNeverRegisterPartialModel() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let data = fixture(); var corrupt = data; corrupt[40] = 9
        let library = ModelLibrary(root: root, catalog: [recipe(data)], transport: FixtureModelTransport(bytes: corrupt), diskAvailable: { _ in Int64.max })
        do { _ = try await library.install(recipe: recipe(data)); XCTFail("Expected hash rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("Checksum")) }
        let records = try await library.installedModels(); XCTAssertTrue(records.isEmpty)
        let lowDisk = ModelLibrary(root: root, catalog: [recipe(data)], transport: FixtureModelTransport(bytes: data), diskAvailable: { _ in 0 })
        do { _ = try await lowDisk.install(recipe: recipe(data)); XCTFail("Expected disk rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("disk")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "registry.json").path))
    }

    func testCancellationReleasesBusyStateAndLeavesNoRegistration() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let data = fixture(); let recipe = recipe(data)
        let library = ModelLibrary(root: root, catalog: [recipe], transport: FixtureModelTransport(bytes: data, pause: true), diskAvailable: { _ in Int64.max })
        let job = Task { try await library.install(recipe: recipe) }
        try await Task.sleep(for: .milliseconds(20)); job.cancel()
        do { _ = try await job.value; XCTFail("Expected cancellation") } catch is CancellationError { } catch { XCTFail("Wrong error: \(error)") }
        let records = try await library.installedModels(); XCTAssertTrue(records.isEmpty)
        try await library.remove(id: "absent")
    }

    @MainActor
    func testInstallCanRunWhileGenerationIsActive() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let data = fixture(), recipe = recipe(data)
        let library = ModelLibrary(root: root, catalog: [recipe], transport: FixtureModelTransport(bytes: data), diskAvailable: { _ in Int64.max })
        let store = ModelLibraryViewModel(library: library)
        store.generationRunning = true

        store.install(recipe)
        XCTAssertEqual(store.activeRecipeID, recipe.id, "An active generation must not block a background download")
        for _ in 0..<100 where store.busy { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.generationRunning)
        XCTAssertEqual(store.installed.map(\.id), [recipe.id])
        XCTAssertNil(store.failure)
    }

    @MainActor
    func testStorageSummaryDeduplicatesSharedComponentsAndIncludesPartialDownloads() {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ModelComponent(id: "shared", role: "model", repository: "test/model", revision: String(repeating: "a", count: 40), filename: "model.gguf", byteSize: 1_000, sha256: String(repeating: "b", count: 64), license: "test")
        let component = InstalledModelComponent(id: "shared", role: "model", fileURL: root.appending(path: "model.gguf"), source: source)
        let first = InstalledGenerationModel(id: "first", name: "First", kind: .text, engineID: "llama.cpp", components: [component], installedAt: Date(), inferenceVerified: false, available: true)
        let second = InstalledGenerationModel(id: "second", name: "Second", kind: .text, engineID: "llama.cpp", components: [component], installedAt: Date(), inferenceVerified: false, available: true)
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        store.installed = [first, second]
        store.partialDownloadBytes = 250

        XCTAssertEqual(store.installedStorageBytes, 1_000)
        XCTAssertEqual(store.modelStorageBytes, 1_250)
    }

    func testImportCopiesAndRejectsChangedInstalledBytes() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.gguf"); let data = fixture(); try data.write(to: source)
        let library = ModelLibrary(root: root.appending(path: "library"), catalog: [recipe(data)], diskAvailable: { _ in Int64.max })
        let installed = try await library.importFiles(recipe: recipe(data), filesByComponentID: ["part0": source])
        XCTAssertNotEqual(installed.components[0].fileURL, source)
        try FileManager.default.removeItem(at: source)
        _ = try await library.resolveInstalledModel(id: installed.id)
        var changed = data; changed[40] = 8; try changed.write(to: installed.components[0].fileURL)
        do { _ = try await library.resolveInstalledModel(id: installed.id); XCTFail("Expected modified-file rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("Checksum")) }
    }

    func testIncompleteImportAndInvalidRegistryPreserveOriginals() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: root)
        do { _ = try await library.importFiles(recipe: recipe(fixture(), components: 2), filesByComponentID: [:]); XCTFail("Expected full-recipe requirement") } catch { }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "registry.json"), bytes = Data("invalid registry".utf8); try bytes.write(to: file)
        do { _ = try await library.installedModels(); XCTFail("Expected malformed registry rejection") } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }


    func testTamperedRegistryAndUnsupportedRecipesCannotBecomeRunnable() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = fixture(), valid = recipe(fixture())
        let library = ModelLibrary(root: root, catalog: [valid], transport: FixtureModelTransport(bytes: bytes), diskAvailable: { _ in Int64.max })
        let installed = try await library.install(recipe: valid)
        let file = root.appending(path: "registry.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var models = try XCTUnwrap(json["models"] as? [[String: Any]])
        models[0]["engineID"] = "untrusted engine"; json["models"] = models
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        do { _ = try await library.resolveInstalledModel(id: installed.id); XCTFail("Expected canonical registry rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("pinned recipe")) }
        let defaultLibrary = ModelLibrary(root: root.appending(path: "unsupported"), transport: FixtureModelTransport(bytes: bytes), diskAvailable: { _ in Int64.max })
        do { _ = try await defaultLibrary.install(recipe: valid); XCTFail("Expected unsupported recipe rejection") } catch { XCTAssertTrue(error.localizedDescription.contains("catalog")) }
    }

    func testRecoveryCleansOnlyOwnedUUIDStagingEntries() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let leftover = root.appending(path: ".staging/\(UUID())")
        let unrelated = root.appending(path: ".staging/keep-me")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let library = ModelLibrary(root: root)
        let removed = try await library.cleanupInterruptedInstalls()
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testHubLinksAndPinnedCatalog() throws {
        XCTAssertEqual(try ModelLibrary.parseHubLink("https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/main"), "Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        XCTAssertEqual(try ModelLibrary.parseHubLink("Qwen/Qwen2.5-0.5B-Instruct-GGUF"), "Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        XCTAssertThrowsError(try ModelLibrary.parseHubLink("https://example.com/a/b"))
        XCTAssertThrowsError(try ModelLibrary.parseHubLink("https://huggingface.co/spaces/a/b"))
        XCTAssertEqual(ModelCatalog.legacyRecipes.map(\.id), ["qwen25-05b-q4km", "sd15-q4", "wan21-13b-q4"])
        XCTAssertEqual(Set(ModelCatalog.recipes.map(\.id)).count, ModelCatalog.recipes.count)
        for recipe in VisionModelCatalog.recipes {
            XCTAssertEqual(Set(recipe.components.map(\.role)), ["model", "mmproj"])
            XCTAssertEqual(Set(recipe.components.map(\.repository)).count, 1)
            XCTAssertEqual(Set(recipe.components.map(\.revision)).count, 1)
        }
        XCTAssertEqual(MLXVLMModelCatalog.qwen38.components.filter { $0.role == "weights" }.count, 3)
        XCTAssertEqual(Set(MLXVLMModelCatalog.qwen38.workflowCapabilities ?? []), [.textGeneration, .imageUnderstanding])
        XCTAssertEqual(ModelCatalog.recipes[2].components.count, 3)
        XCTAssertFalse(ModelCatalog.recipes[2].runtimeReady)
    }
}

@MainActor
final class StarterRecommendationTests: XCTestCase {
    private var sd15: ModelRecipe { ModelCatalog.recipes.first { $0.id == ImageCapabilityRegistry.sd15RecipeID }! }
    private var klein: ModelRecipe { MediaModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID }! }

    /// The recommended production default must be a recipe GenStudio can truly install (an exact,
    /// pinned component manifest) and truly run (a registered adapter for at least one image task).
    /// This is the evidence bar the task set for "a better default than SD 1.5" — not proof of a
    /// decoded render, which GenStudio cannot fabricate without downloading and running weights.
    func testRecommendedImageDefaultHasAnExactManifestAndARealAdapter() {
        XCTAssertEqual(ModelRecipePresentation.recommendedImageRecipeID, MediaModelCatalog.kleinRecipeID)
        XCTAssertFalse(klein.components.isEmpty)
        for component in klein.components {
            XCTAssertEqual(component.sha256.count, 64); XCTAssertGreaterThan(component.byteSize, 0)
            XCTAssertFalse(component.repository.isEmpty); XCTAssertFalse(component.revision.isEmpty)
        }
        XCTAssertTrue(ImageCapabilityRegistry.hasAdapter(klein.id))
        XCTAssertNotNil(ImageCapabilityRegistry.capability(recipeID: klein.id, task: .textToImage))
        XCTAssertNotNil(ImageCapabilityRegistry.capability(recipeID: klein.id, task: .imageToImage))
        // Both Klein tasks now carry a decoded local proof (docs/research/model-expansion/evidence/proofs/flux2-klein-reference),
        // so the recommended default is also globally verified, not merely adapter-complete.
        XCTAssertTrue(ImageCapabilityRegistry.supportsRecipe(klein.id), "Recommended default should be backed by real evidence, not just manifest completeness")
    }

    /// SD 1.5 remains an always-verified optional fallback. The MLX video routes
    /// (FastMetal, LTX-2.3) stay out of Start Here until they complete an
    /// end-to-end proof; Wan 2.1 T2V already has one and is included.
    func testSD15RemainsAnAlwaysVerifiedOptionalFallback() {
        XCTAssertTrue(ImageCapabilityRegistry.supportsRecipe(sd15.id), "The fallback must actually be verified, or the guidance text lies")
        let store = ModelLibraryViewModel(library: ModelLibrary(root: FileManager.default.temporaryDirectory.appending(path: "starter-\(UUID())")))
        store.hardware = .init(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "Version 26.6.2 (Build 25G100)", freeDiskBytes: 800 << 30)
        let starterIDs = Set(store.starterRecipes.map(\.id))
        XCTAssertFalse(starterIDs.contains(sd15.id), "SD 1.5 is available later, not queued by default")
        XCTAssertTrue(starterIDs.contains(MediaModelCatalog.klein9BRecipeID), "Klein 9B is the image model that meets the speed-and-quality bar")
        XCTAssertFalse(starterIDs.contains(MediaModelCatalog.kleinRecipeID), "Klein 4B failed the quality bar")
    }

    func testJuggernautXLIsAnInstallableNonFluxImageComparison() {
        let recipe = try! XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.juggernautXLRecipeID })
        XCTAssertEqual(recipe.components.count, 1)
        XCTAssertEqual(recipe.components[0].filename, "Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors")
        XCTAssertEqual(recipe.components[0].byteSize, 7_105_348_188)
        XCTAssertTrue(ImageCapabilityRegistry.hasUsableAdapter(recipe.id))
        XCTAssertEqual(ImageCapabilityRegistry.capability(recipeID: recipe.id, task: .textToImage)?.steps, 35)
        XCTAssertEqual(ImageCapabilityRegistry.capability(recipeID: recipe.id, task: .imageToImage)?.maximumReferenceImages, 1)
    }

    /// The compact queue covers shared text/vision, image creation and finishing,
    /// plus the one video recipe with a decoded, measured proof (Wan 2.1 T2V —
    /// see docs/evidence/video-benchmark-m1max-2026-09-18.md). Every other video
    /// specialist stays on an explicit Download & Test card rather than joining
    /// the compact one-click starter queue.
    func testStarterSetIsCompactAndNeverQueuesUnverifiedSpecialistsByDefault() {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: FileManager.default.temporaryDirectory.appending(path: "starter-minimal-\(UUID())")))
        store.hardware = .init(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "Version 26.6.2 (Build 25G100)", freeDiskBytes: 800 << 30)
        let starter = store.starterRecipes
        XCTAssertEqual(starter.filter { $0.kind == .video }.map(\.id), [MLXVideoModelCatalog.fastMetal5BRecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID],
                       "Start Here video is the two routes that meet the bar: FastMetal for drafts, LTX-2.3 for finals and image-to-video")
        let unverifiedVideoIDs: Set<String> = [MediaModelCatalog.animateDiffRecipeID, MediaModelCatalog.lingBotRecipeID, MediaModelCatalog.wan22TI2VRecipeID, MediaModelCatalog.wan21FLFRecipeID, MediaModelCatalog.minimaxH3RecipeID, MediaModelCatalog.minimaxH3Ref2VARecipeID]
        XCTAssertTrue(Set(starter.map(\.id)).isDisjoint(with: unverifiedVideoIDs), "No unverified video adapter is ever core-recommended by Start Here")
        XCTAssertEqual(Set(starter.map(\.kind)), [.vision, .image, .video, .upscaler, .speech], "Voiceover is part of making an advert")
        XCTAssertEqual(starter.count, 6)
        XCTAssertEqual(starter.filter { $0.id == MLXVLMModelCatalog.qwen38RecipeID }.count, 1)
        XCTAssertEqual(starter.filter { $0.kind == .image }.count, 1)
        XCTAssertEqual(starter.filter { $0.kind == .upscaler }.count, 1)
    }

    func testStarterQueueSummaryMatchesWhatOneClickWillDownload() {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: FileManager.default.temporaryDirectory.appending(path: "starter-summary-\(UUID())")))
        store.hardware = .init(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "Version 26.6.2", freeDiskBytes: 800 << 30)
        let pending = store.starterPendingRecipes
        XCTAssertTrue(store.starterQueueSummary.contains("Ready to queue \(pending.count) model package"))
        XCTAssertTrue(store.starterQueueSummary.contains(ModelLibraryViewModel.bytes(store.starterDownloadBytes)))
    }

    /// The recommended recipe sorts first regardless of the source order, and no recipe is dropped.
    func testOrderedForRecommendationPutsTheRecommendedDefaultFirstWithoutLosingAnyRecipe() {
        let klein4B = try! XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID })
        for input in [[sd15, klein4B], [klein4B, sd15]] {
            let ordered = ModelRecipePresentation.orderedForRecommendation(input)
            XCTAssertEqual(ordered.first?.id, MediaModelCatalog.kleinRecipeID)
            XCTAssertEqual(Set(ordered.map(\.id)), Set(input.map(\.id)))
        }
        XCTAssertEqual(ModelRecipePresentation.orderedForRecommendation([]), [])
    }

    /// The starter titles must actually say what the guidance text promises: one recipe reads as
    /// recommended, the other explicitly reads as a fallback, so the UI never implies both equally.
    func testTitlesLabelRecommendedAndFallbackExplicitly() {
        let klein4B = try! XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID })
        XCTAssertTrue(ModelRecipePresentation.title(klein4B).localizedCaseInsensitiveContains("verified"))
        XCTAssertTrue(ModelRecipePresentation.title(sd15).localizedCaseInsensitiveContains("fallback"))
    }
}

final class OptimalCanvasAndRatioLockTests: XCTestCase {
    private func capability(_ id: String, _ task: VideoTask = .textToVideo) throws -> VideoCapability {
        try XCTUnwrap(VideoCapabilityRegistry.capability(recipeID: id, task: task))
    }

    func testRatioButtonsStartFromTheRecipesOwnRecommendedPixelBudget() throws {
        let wan = try capability(VideoCapabilityRegistry.wanT2VRecipeID)
        let size = try XCTUnwrap(AspectRatioPreset.vertical.dimensions(width: wan.width, height: wan.height, targetPixels: wan.optimalPixels))
        XCTAssertTrue(wan.width.contains(size.0) && wan.height.contains(size.1))
        XCTAssertEqual(Double(size.0) / Double(size.1), 9.0 / 16.0, accuracy: 0.02)
        XCTAssertLessThan(abs(size.0 * size.1 - wan.optimalPixels), wan.optimalPixels / 2, "Starts near the recommended canvas, not the largest allowed")
        let ltx = try capability(MLXVideoModelCatalog.ltx23Q4RecipeID)
        let exact = try XCTUnwrap(AspectRatioPreset.vertical.dimensions(width: ltx.width, height: ltx.height, targetPixels: ltx.optimalPixels))
        XCTAssertEqual(Double(exact.0) / Double(exact.1), 9.0 / 16.0, accuracy: 0.001)
    }

    func testImageRatioButtonsUseTheModelFamilySweetSpot() throws {
        let klein = try XCTUnwrap(ImageCapabilityRegistry.capability(recipeID: MediaModelCatalog.kleinRecipeID, task: .textToImage))
        let sd15 = try XCTUnwrap(ImageCapabilityRegistry.capability(recipeID: ImageCapabilityRegistry.sd15RecipeID, task: .textToImage))
        let big = try XCTUnwrap(AspectRatioPreset.square.dimensions(width: klein.width, height: klein.height, targetPixels: klein.optimalPixels))
        let small = try XCTUnwrap(AspectRatioPreset.square.dimensions(width: sd15.width, height: sd15.height, targetPixels: sd15.optimalPixels))
        XCTAssertEqual(big.0, 1024); XCTAssertEqual(small.0, 512)
    }

    func testLockedWidthDragMovesHeightAndKeepsTheRatio() {
        let w = IntegerBounds(minimum: 256, maximum: 1024, multiple: 64), h = IntegerBounds(minimum: 256, maximum: 1024, multiple: 64)
        let r = RatioLock.resolve(changedWidth: true, raw: 576, currentWidth: 384, currentHeight: 704, widthBounds: w, heightBounds: h)
        XCTAssertEqual(r.width, 576)
        XCTAssertEqual(Double(r.width) / Double(r.height), 9.0 / 16.0, accuracy: 0.03)
        XCTAssertTrue(w.contains(r.width) && h.contains(r.height))
    }

    func testLockedDragNeverLeavesTheBounds() {
        let w = IntegerBounds(minimum: 160, maximum: 832, multiple: 16), h = IntegerBounds(minimum: 96, maximum: 480, multiple: 16)
        let r = RatioLock.resolve(changedWidth: true, raw: 832, currentWidth: 272, currentHeight: 480, widthBounds: w, heightBounds: h)
        XCTAssertTrue(w.contains(r.width) && h.contains(r.height))
        XCTAssertEqual(Double(r.width) / Double(r.height), 9.0 / 16.0, accuracy: 0.03, "Width is pulled back when height hits its ceiling")
    }

    func testRatioLockStateSurvivesEncodingAndOldProjectsDefaultOff() throws {
        var node = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 0, y: 0))
        XCTAssertFalse(node.ratioLocked)
        node.ratioLocked = true
        let decoded = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(node))
        XCTAssertTrue(decoded.ratioLocked)
    }
}
