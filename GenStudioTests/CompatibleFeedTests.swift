import XCTest
@testable import GenStudio

@MainActor
final class CompatibleFeedTests: XCTestCase {
    func testLiveDiscoveryIsDefaultAndCompatibleFeedRequiresNoInstalledTextModel() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CompatibleFeedTransport()
        let store = makeStore(root: root, transport: transport)

        XCTAssertTrue(store.onlyCompatibleModels)
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertTrue(store.compatibleRecipes.isEmpty, "Unknown hardware must not be silently accepted.")
        store.hardware = mac()
        let recipes = store.supportedRecipes(matching: "")
        XCTAssertFalse(recipes.contains { $0.id == MLXVideoModelCatalog.fastMetal5BRecipeID })
        XCTAssertTrue(store.controlledEvaluationRecipes.contains { $0.id == MLXVideoModelCatalog.fastMetal5BRecipeID })
        XCTAssertTrue(recipes.contains { $0.id == "sd15-q4" })
        XCTAssertTrue(recipes.contains { $0.id == "qwen25-05b-q4km" })
        XCTAssertTrue(recipes.contains { $0.kind == .vision })
        // The immutable Wan manifest predates its adapter; only its verified text-to-video capability admits it.
        XCTAssertTrue(recipes.contains { $0.id == "wan21-13b-q4" })
        XCTAssertTrue(store.canInstall(try XCTUnwrap(recipes.first { $0.id == "wan21-13b-q4" })), "Existing Wan files can be imported")
        XCTAssertTrue(recipes.allSatisfy { $0.runtimeReady || ($0.kind == .video && VideoCapabilityRegistry.hasAdapter($0.id)) || ($0.kind == .image && ImageCapabilityRegistry.hasAdapter($0.id)) || ($0.kind == .upscaler && UpscaleCapabilityRegistry.hasAdapter($0.id)) || ($0.engineID == "mlx-vlm" && MLXVLMModelCatalog.supportsRecipe($0.id)) })

        store.setCompatibilityScope(true, query: "stable")
        store.selectDiscoveryCategory(.images, query: "stable")
        XCTAssertFalse(store.searching)
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty, "Compatibility and category browsing must work before installing any LLM.")
    }

    func testCategoryAndUseFiltersOnlyOfferCapabilitiesTheAppCanExecute() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        store.hardware = mac()

        store.selectDiscoveryCategory(.images, query: "")
        XCTAssertEqual(store.supportedRecipes(matching: "").map(\.id), ["sd15-q4", MediaModelCatalog.kleinRecipeID])
        store.discoveryTask = .imageEditing
        XCTAssertEqual(store.supportedRecipes(matching: "").map(\.id), ["sd15-q4", MediaModelCatalog.kleinRecipeID], "Only decoded task proofs belong in the normal image-editing feed.")

        store.selectDiscoveryCategory(.video, query: "")
        XCTAssertEqual(store.supportedRecipes(matching: "").map(\.id), [VideoCapabilityRegistry.wanT2VRecipeID], "Only video recipes with decoded task proof are offered; LTX and unmeasured adapters remain diagnostic or evaluation-only.")
        store.selectDiscoveryCategory(.sound, query: "")
        XCTAssertTrue(store.supportedRecipes(matching: "").isEmpty)
        store.selectDiscoveryCategory(.text, query: "")
        XCTAssertFalse(store.supportedRecipes(matching: "").isEmpty)
        XCTAssertTrue(store.supportedRecipes(matching: "").allSatisfy { $0.kind == .text || $0.workflowCapabilities?.contains(.textGeneration) == true })
        store.selectDiscoveryCategory(.understanding, query: "")
        XCTAssertFalse(store.supportedRecipes(matching: "").isEmpty)
        XCTAssertTrue(store.supportedRecipes(matching: "").allSatisfy { $0.kind == .vision || $0.workflowCapabilities?.contains(.imageUnderstanding) == true })
        XCTAssertEqual(store.discoveryTask, .all)
    }

    func testSupportedSearchMatchesNamesAndPublisherWithoutLosingCategory() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        store.hardware = mac()

        XCTAssertEqual(store.supportedRecipes(matching: "  STABLE DIFFUSION  ").map(\.id), ["sd15-q4"])
        XCTAssertEqual(store.supportedRecipes(matching: "SECOND-STATE").map(\.id), ["sd15-q4"])
        XCTAssertTrue(store.supportedRecipes(matching: "a-model-that-does-not-exist").isEmpty)
        // "qwen" matches Klein's Qwen3-4B text encoder component repository, so it stays inside the
        // images category (proving search reaches component repositories, not just the recipe name).
        store.selectDiscoveryCategory(.images, query: "qwen")
        XCTAssertEqual(store.supportedRecipes(matching: "qwen").map(\.id), [MediaModelCatalog.kleinRecipeID])
        store.selectDiscoveryCategory(.understanding, query: "QWEN")
        let vision = store.supportedRecipes(matching: "QWEN")
        XCTAssertFalse(vision.isEmpty)
        XCTAssertTrue(vision.allSatisfy { $0.kind == .vision })
    }

    func testSearchAcceptsModelErrorTextAndFindsBuiltInVisionRecipe() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        store.hardware = mac()

        XCTAssertEqual(
            store.supportedRecipes(matching: "Model vision-smolvlm-500m-q8").map(\.id),
            ["vision-smolvlm-500m-q8"]
        )

        store.scoutQuery = "Model vision-smolvlm-500m-q8"
        XCTAssertEqual(store.scoutCatalogMatches.map(\.id), ["vision-smolvlm-500m-q8"])
    }

    func testJuggernautIsHiddenUntilARealLocalTaskProofExists() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        store.hardware = mac()

        let juggernaut = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.juggernautXLRecipeID })
        XCTAssertTrue(store.supportedRecipes(matching: "Juggernaut XL v9").isEmpty)
        XCTAssertTrue(store.canInstall(juggernaut), "The exact evaluation package remains installable from its explicit package route.")
        XCTAssertEqual(store.mediaFit(juggernaut).state, .adapterUnverified)
    }

    func testFeedRecomputesWhenMemoryOrFreeStorageChanges() {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        store.hardware = mac()
        let initialIDs = Set(store.compatibleRecipes.map(\.id))
        XCTAssertTrue(initialIDs.contains("sd15-q4"))

        store.hardware = mac(memory: 4 << 30)
        XCTAssertFalse(store.compatibleRecipes.contains { $0.id == "sd15-q4" })
        XCTAssertTrue(store.compatibleRecipes.contains { $0.id == "qwen25-05b-q4km" })

        store.hardware = mac(freeStorage: 100 * 1024 * 1024)
        XCTAssertTrue(store.compatibleRecipes.isEmpty)
        store.hardware = mac()
        XCTAssertEqual(Set(store.compatibleRecipes.map(\.id)), initialIDs)
    }

    func testReturningToCompatibleFeedCancelsAndDiscardsSlowBroadSearch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CompatibleFeedTransport()
        let store = makeStore(root: root, transport: transport)
        store.hardware = mac()

        store.setCompatibilityScope(false, query: "first")
        try await waitUntil { !store.searching }
        XCTAssertEqual(store.visibleDiscoveryModels.map(\.id), ["hub/first"])

        store.search("slow")
        for _ in 0..<100 {
            if await transport.requests().contains(where: { $0.query?.contains("slow") == true }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.contains { $0.query?.contains("slow") == true })
        store.setCompatibilityScope(true, query: "stable")
        store.selectDiscoveryCategory(.images, query: "stable")
        XCTAssertFalse(store.searching)
        XCTAssertTrue(store.visibleDiscoveryModels.isEmpty)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(store.visibleDiscoveryModels.isEmpty)
        XCTAssertFalse(store.discoveryModels.contains { $0.id == "hub/slow" })
        XCTAssertEqual(store.supportedRecipes(matching: "stable").map(\.id), ["sd15-q4"])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private func mac(memory: UInt64 = 64 << 30, freeStorage: Int64 = 800 << 30) -> HardwareProfile {
        .init(chip: "Apple M1 Max", memoryBytes: memory, osVersion: "26.6.2", freeDiskBytes: freeStorage)
    }
    private func makeStore(root: URL, transport: CompatibleFeedTransport = CompatibleFeedTransport()) -> ModelLibraryViewModel {
        .init(library: ModelLibrary(root: root.appendingPathComponent("library")),
              discovery: ModelDiscovery(cacheRoot: root.appendingPathComponent("cache"), transport: transport))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The fixture search did not finish.")
    }
}

private actor CompatibleFeedTransport: DiscoveryTransport {
    private var urls: [URL] = []
    func requests() -> [URL] { urls }
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        urls.append(url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "search" }?.value ?? ""
        if query == "slow" {
            // Simulate an HTTP response that arrives despite cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
            }
        }
        let rows = [["id": "hub/\(query)", "pipeline_tag": "text-generation"]]
        return .init(data: try JSONSerialization.data(withJSONObject: rows), nextLink: nil)
    }
}
