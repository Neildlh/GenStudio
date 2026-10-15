import XCTest
@testable import GenStudio

private actor DiscoveryFixture: DiscoveryTransport {
    var urls: [URL] = []
    var fail = false
    func setFailure() { fail = true }
    func requests() -> [URL] { urls }
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        urls.append(url)
        if fail { throw URLError(.notConnectedToInternet) }
        if url.path == "/api/models" {
            return .init(data: Data("[{\"id\":\"test/model\",\"pipeline_tag\":\"text-generation\"}]".utf8), nextLink: "<https://huggingface.co/api/models?cursor=opaque>; rel=\"next\"")
        }
        if url.path.hasSuffix("config.json") {
            return .init(data: Data("{\"model_type\":\"qwen2\",\"architectures\":[\"Qwen2ForCausalLM\"],\"max_position_embeddings\":32768}".utf8), nextLink: nil)
        }
        let json: [String: Any] = ["id": "test/model", "sha": String(repeating: "a", count: 40), "pipeline_tag": "text-generation", "gated": "manual", "cardData": ["license": "apache-2.0"], "siblings": [["rfilename": "model.gguf", "size": 100, "lfs": ["sha256": String(repeating: "b", count: 64)]], ["rfilename": "config.json", "size": 70]]]
        return .init(data: try JSONSerialization.data(withJSONObject: json), nextLink: nil)
    }
}
final class ModelDiscoveryTests: XCTestCase {
    func testAdultClassificationUsesPublisherMetadataNotModelName() {
        let marked = discoveryModel(id: "studio/innocuous", tags: ["diffusers", "not-for-all-audiences"])
        let nameOnly = discoveryModel(id: "studio/nsfw-in-name", tags: ["diffusers"])
        XCTAssertTrue(marked.isAdultContent)
        XCTAssertFalse(nameOnly.isAdultContent)
    }

    @MainActor
    func testAudienceFilterKeepsAdultModelsDiscoverable() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        store.onlyCompatibleModels = false
        store.discoveryModels = [
            discoveryModel(id: "studio/general", tags: ["text-to-image"]),
            discoveryModel(id: "studio/adult", tags: ["text-to-image", "not-for-all-audiences"])
        ]
        XCTAssertFalse(store.onlyCompatibleModels)
        XCTAssertEqual(store.visibleDiscoveryModels.count, 2)
        store.discoveryAudience = .adult
        XCTAssertEqual(store.visibleDiscoveryModels.map(\.id), ["studio/adult"])
        store.discoveryAudience = .general
        XCTAssertEqual(store.visibleDiscoveryModels.map(\.id), ["studio/general"])
    }

    @MainActor
    func testScoutAudienceTabsFilterFetchedListingsWithoutRestartingSearch() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        store.scoutResults = [
            ModelScoutResult(source: "Hugging Face", id: "studio/general", summary: "Image", installable: false, reason: "", recipe: nil),
            ModelScoutResult(source: "Civitai", id: "studio/adult", summary: "Image", installable: false, reason: "", recipe: nil, isAdultContent: true)
        ]

        store.scoutAudience = .general
        XCTAssertEqual(store.visibleScoutResults.map(\.idText), ["studio/general"])
        store.scoutAudience = .adult
        XCTAssertEqual(store.visibleScoutResults.map(\.idText), ["studio/adult"])
        store.scoutAudience = .all
        XCTAssertEqual(store.visibleScoutResults.count, 2)
        XCTAssertFalse(store.scoutBusy)
    }

    func testCategoryQueriesEveryTaskAndMaintainsIndependentPagination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CategoryDiscoveryFixture()
        let discovery = ModelDiscovery(cacheRoot: root, transport: transport)
        let first = try await discovery.browse(query: "studio", category: .images, sort: .downloads)
        XCTAssertEqual(first.models.map(\.id), ["test/shared", "test/image-to-image", "test/text-to-image"])
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.streams.filter { !$0.finished }.map(\.task), [.image])
        let initialRequests = await transport.requests()
        XCTAssertEqual(Set(initialRequests.compactMap { queryItem("pipeline_tag", in: $0) }), Set(["text-to-image", "image-to-image"]))
        XCTAssertTrue(initialRequests.allSatisfy { queryItem("search", in: $0) == "studio" && queryItem("sort", in: $0) == "downloads" })
        let second = try await discovery.browse(query: "studio", category: .images, sort: .downloads, streams: first.streams)
        XCTAssertEqual(second.models.map(\.id), ["test/page-two"])
        XCTAssertFalse(second.hasMore)
        let allRequests = await transport.requests()
        XCTAssertEqual(allRequests.count, 3)
        XCTAssertEqual(queryItem("pipeline_tag", in: try XCTUnwrap(allRequests.last)), "text-to-image")
        let restarted = ModelDiscovery(cacheRoot: root, transport: transport)
        let cached = try await restarted.browse(query: "studio", category: .images, sort: .downloads, offline: true)
        XCTAssertTrue(cached.isCached)
        XCTAssertEqual(cached.models.map(\.id), first.models.map(\.id))
        XCTAssertEqual(cached.fetchedAt, first.fetchedAt)
    }

    func testPartialCategoryFailureRetainsFailedStreamForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CategoryDiscoveryFixture()
        await transport.failNextEditingRequest()
        let discovery = ModelDiscovery(cacheRoot: root, transport: transport)
        let first = try await discovery.browse(query: "partial", category: .images)
        XCTAssertEqual(first.warnings.count, 1)
        XCTAssertEqual(first.successfulRequests, 1)
        XCTAssertEqual(first.streams.last, DiscoveryStream(task: .imageEditing))
        let retry = try await discovery.browse(query: "partial", category: .images, streams: first.streams)
        XCTAssertTrue(retry.warnings.isEmpty)
        XCTAssertFalse(retry.hasMore)
        XCTAssertTrue(retry.models.contains { $0.id == "test/image-to-image" })
        do {
            _ = try await discovery.browse(query: "partial", category: .video, streams: first.streams)
            XCTFail("A changed category must not reuse another category's cursors")
        } catch { }
    }

    func testExplicitCardMetadataRecoversPurposeWithoutGuessingNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = ModelDiscovery(cacheRoot: root, transport: CategoryDiscoveryFixture())
        let page = try await discovery.search(query: "metadata")
        XCTAssertEqual(page.models[0].purposes, [.imageGeneration])
        XCTAssertEqual(page.models[1].purposes, [.transcription])
        XCTAssertEqual(page.models[2].purposes, [.unknown])
        XCTAssertEqual(page.models[0].pipelineTag, "text-to-image")
    }

    func testCategorySubtypeAndTaskCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CategoryDiscoveryFixture()
        _ = try await ModelDiscovery(cacheRoot: root, transport: transport).browse(query: "", category: .sound, task: .speech)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(queryItem("pipeline_tag", in: requests[0]), "text-to-speech")
        XCTAssertEqual(DiscoveryCategory.video.tasks(for: .all), [.video, .imageToVideo])
        XCTAssertTrue(DiscoveryCategory.text.tasks(for: .all).contains(.textAnalysis))
        XCTAssertTrue(DiscoveryCategory.understanding.tasks(for: .all).contains(.vision))
        XCTAssertEqual(DiscoveryCategory.images.tasks(for: .speech), [.image, .imageEditing])
    }

    @MainActor
    func testChangingCategoryDiscardsSlowPriorSearchAndUnknownsStayAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CategoryDiscoveryFixture()
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root.appendingPathComponent("library")),
            discovery: ModelDiscovery(cacheRoot: root.appendingPathComponent("cache"), transport: transport))
        store.onlyCompatibleModels = false // This test exercises the explicitly opted-in broad hub feed.
        XCTAssertEqual(store.discoverySort, .trending)
        store.search("slow-old")
        for _ in 0..<100 {
            if await transport.requests().contains(where: { queryItem("search", in: $0) == "slow-old" }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.selectDiscoveryCategory(.video, query: "new")
        for _ in 0..<100 {
            if !store.searching { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(store.searching)
        XCTAssertEqual(store.discoveryCategory, .video)
        XCTAssertEqual(Set(store.discoveryModels.map(\.id)), Set(["test/text-to-video", "test/image-to-video", "test/shared"]))
        XCTAssertFalse(store.discoveryModels.contains { $0.id == "test/old" })
        store.selectDiscoveryCategory(.all, query: "metadata")
        for _ in 0..<100 {
            if !store.searching { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.unknownPurposeCount, 1)
        XCTAssertEqual(store.visibleDiscoveryModels.count, 2)
        store.showUnknownPurposes = true
        XCTAssertEqual(store.visibleDiscoveryModels.count, 3)
    }

    func testPagingFiltersAndOfflineRestartCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DiscoveryFixture()
        let discovery = ModelDiscovery(cacheRoot: root, transport: transport)
        let page = try await discovery.search(query: "hello", task: .video, sort: .trending)
        XCTAssertEqual(page.models.first?.id, "test/model")
        XCTAssertEqual(page.nextCursor, "https://huggingface.co/api/models?cursor=opaque")
        let requests = await transport.requests()
        let query = URLComponents(url: try XCTUnwrap(requests.first), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(.init(name: "pipeline_tag", value: "text-to-video")) == true)
        XCTAssertTrue(query?.contains(.init(name: "sort", value: "trendingScore")) == true)
        let restarted = ModelDiscovery(cacheRoot: root, transport: transport)
        let cached = try await restarted.search(query: "hello", task: .video, sort: .trending, offline: true)
        XCTAssertTrue(cached.isCached)
        XCTAssertEqual(cached.fetchedAt, page.fetchedAt)
        await transport.setFailure()
        let fallback = try await restarted.search(query: "hello", task: .video, sort: .trending)
        XCTAssertTrue(fallback.isCached)
    }
    func testDetailPinsConfigAndDoesNotPromoteGGUF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = DiscoveryFixture()
        let detail = try await ModelDiscovery(cacheRoot: root, transport: transport).detail(repository: "test/model")
        XCTAssertEqual(detail.model.license, "apache-2.0")
        XCTAssertTrue(detail.model.gated)
        XCTAssertEqual(detail.contextLength, 32768)
        XCTAssertEqual(detail.experimentalTextFiles.count, 1)
        let requests = await transport.requests()
        XCTAssertTrue(requests.last!.path.contains(String(repeating: "a", count: 40)))
        let mac = HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "26", freeDiskBytes: 100 << 30)
        let assessment = ModelDiscovery.assess(detail: detail, hardware: mac)
        XCTAssertFalse(assessment.runtimeSupported)
        XCTAssertEqual(assessment.hardware, .unknown)
        XCTAssertTrue(assessment.exactRecipeIDs.isEmpty)
    }
    func testExactRecipeRequiresHashAndRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try await ModelDiscovery(cacheRoot: root, transport: DiscoveryFixture()).detail(repository: "test/model")
        func recipe(_ hash: String) -> ModelRecipe {
            .init(id: "verified", name: "Test", kind: .text, engineID: "llama.cpp", components: [.init(id: "model", role: "model", repository: "test/model", revision: String(repeating: "a", count: 40), filename: "model.gguf", byteSize: 100, sha256: hash, license: "apache-2.0")], runtimeReady: true, minimumMemoryBytes: 4 << 30)
        }
        let mac = HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "26", freeDiskBytes: 100 << 30)
        XCTAssertFalse(ModelDiscovery.assess(detail: detail, hardware: mac, recipes: [recipe("wrong")]).runtimeSupported)
        XCTAssertTrue(ModelDiscovery.assess(detail: detail, hardware: mac, recipes: [recipe(String(repeating: "b", count: 64))]).runtimeSupported)
    }
    func testMediaRecipeMatchesByAdapterPresenceNotRuntimeReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try await ModelDiscovery(cacheRoot: root, transport: DiscoveryFixture()).detail(repository: "test/model")
        // Image/video recipes are never runtimeReady by design; their adapter presence lives in the
        // capability registries instead (see ModelCompatibility.integrated's own note on this). An
        // exact recipe/file match must still be recognized rather than reported unknown/unsupported
        // just because this unrelated text/vision-only flag is false.
        let video = ModelRecipe(id: VideoCapabilityRegistry.wanT2VRecipeID, name: "Test video", kind: .video, engineID: "stable-diffusion.cpp",
            components: [.init(id: "model", role: "model", repository: "test/model", revision: String(repeating: "a", count: 40), filename: "model.gguf", byteSize: 100, sha256: String(repeating: "b", count: 64), license: "apache-2.0")],
            runtimeReady: false, minimumMemoryBytes: 16 << 30)
        let mac = HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "26", freeDiskBytes: 100 << 30)
        let assessment = ModelDiscovery.assess(detail: detail, hardware: mac, recipes: [video])
        XCTAssertTrue(assessment.runtimeSupported)
        XCTAssertEqual(assessment.exactRecipeIDs, [video.id])
        XCTAssertNotEqual(assessment.hardware, .unknown)
        XCTAssertFalse(assessment.storageExplanation.contains("A verified component plan is needed"))

        // A recipe with no registered adapter anywhere is still correctly excluded: this
        // widens the match to real adapter presence, not to every unverified manifest.
        let unadapted = ModelRecipe(id: "no-such-recipe", name: "Test video", kind: .video, engineID: "stable-diffusion.cpp",
            components: video.components, runtimeReady: false, minimumMemoryBytes: 16 << 30)
        XCTAssertTrue(ModelDiscovery.assess(detail: detail, hardware: mac, recipes: [unadapted]).exactRecipeIDs.isEmpty)
    }

    func testUntrustedPaginationCannotFetchOtherHost() throws {
        for value in ["https://evil.example/api/models", "https://huggingface.co/resolve/model", "http://huggingface.co/api/models", "https://user@huggingface.co/api/models"] {
            XCTAssertThrowsError(try ModelDiscovery.validCursor(value))
        }
    }
}

private func discoveryModel(id: String, tags: [String]) -> DiscoveryModel {
    DiscoveryModel(id: id, sha: nil, pipelineTag: "text-to-image", library: nil,
                   license: nil, gated: false, downloads: nil, likes: nil,
                   createdAt: nil, lastModified: nil, tags: tags)
}

private func queryItem(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

private actor CategoryDiscoveryFixture: DiscoveryTransport {
    private var urls: [URL] = []
    private var failEditing = false
    func requests() -> [URL] { urls }
    func failNextEditingRequest() { failEditing = true }
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        urls.append(url)
        let query = queryItem("search", in: url)
        if query == "slow-old" {
            // Deliberately ignores cancellation: the view model must still discard stale responses.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
            }
            return try response([["id": "test/old", "pipeline_tag": "text-generation"]])
        }
        if query == "metadata" {
            return try response([
                ["id": "test/card-pipeline", "cardData": ["pipeline_tag": "text-to-image"]],
                ["id": "test/card-tags", "cardData": ["tags": ["automatic-speech-recognition"]]],
                ["id": "test/image-video-music-llama", "tags": ["gguf"], "cardData": ["description": "An image generation video and music model with no declared machine-readable task."]]
            ])
        }
        let task = queryItem("pipeline_tag", in: url) ?? ""
        if task == "image-to-image" && failEditing { failEditing = false; throw URLError(.notConnectedToInternet) }
        if queryItem("cursor", in: url) != nil {
            return try response([["id": "test/page-two", "pipeline_tag": task, "downloads": 50]])
        }
        let next = task == "text-to-image" ? "<https://huggingface.co/api/models?pipeline_tag=text-to-image&cursor=two>; rel=\"next\"" : nil
        return try response([
            ["id": "test/shared", "pipeline_tag": task, "downloads": 100],
            ["id": "test/\(task)", "pipeline_tag": task, "downloads": task == "image-to-image" ? 20 : 10]
        ], next: next)
    }
    private func response(_ rows: [[String: Any]], next: String? = nil) throws -> DiscoveryResponse {
        .init(data: try JSONSerialization.data(withJSONObject: rows), nextLink: next)
    }
}
