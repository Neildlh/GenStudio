import XCTest
@testable import GenStudio

/// Serves canned Hub responses by URL and records every request, so no test touches the network.
private final class FakeHub: DiscoveryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URL] = []
    /// Not `@Sendable`: tests configure it before the service runs, and this class is `@unchecked Sendable`.
    var handler: (URL) throws -> Any = { _ in [] }

    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return log }
    private func record(_ url: URL) { lock.lock(); log.append(url); lock.unlock() }
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        record(url)
        return DiscoveryResponse(data: try JSONSerialization.data(withJSONObject: try handler(url)), nextLink: nil)
    }
}

private struct HubDown: LocalizedError { var errorDescription: String? { "The Hugging Face request failed (HTTP 503)." } }

final class ModelRadarServiceTests: XCTestCase {
    private var directory: URL!
    private var hub: FakeHub!
    private var service: ModelRadarService!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: "RadarTests-\(UUID())", directoryHint: .isDirectory)
        hub = FakeHub()
        service = ModelRadarService(transport: hub, cacheRoot: directory)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func row(_ id: String, _ created: String, downloads: Int = 0, gated: Any = false) -> [String: Any] {
        ["id": id, "createdAt": created + "T09:12:33.000Z", "downloads": downloads, "likes": 1, "pipeline_tag": "text-to-video", "gated": gated]
    }
    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    private func files(_ sizes: [String: Int64]) -> [String: Any] {
        ["id": "x/y", "siblings": sizes.map { ["rfilename": $0.key, "size": $0.value] }]
    }
    private var lightricks: [[String: Any]] { [
        row("Lightricks/LTX-2.5-22b-IC-LoRA-Deblur", "2026-09-09"),
        row("Lightricks/LTX-2.5-Pre-Trained", "2026-08-10", downloads: 371),
        row("Lightricks/LTX-2.3-22b-IC-LoRA-Relight", "2026-07-27"),
    ] }
    private var ltxMLX: [[String: Any]] { [
        row("dgrauet/ltx-2.5-mlx-q4", "2026-08-27"),
        row("Karam98/ltx-2.5-mlx-q4", "2026-09-02", downloads: 188),
        row("dgrauet/ltx-2.3-mlx-q4", "2026-05-01", downloads: 9000),
    ] }

    /// A hub that answers the Lightricks listing, the LTX-2.5 MLX search and repository sizes.
    private func ltxOnlyHub() {
        hub.handler = { url in
            if self.query(url, "author") == "Lightricks" { return self.lightricks }
            if self.query(url, "search") != nil { return self.ltxMLX }
            if url.path.hasPrefix("/api/models/") {
                return self.files(["ltx.safetensors": 9_000_000_000, "connector.safetensors": 4_000_000_000, "config.json": 1_200])
            }
            return []   // every other family: nothing found
        }
    }
    private func live(_ id: String, in snapshot: RadarSnapshot) throws -> FamilyLive {
        try XCTUnwrap(snapshot.families.first { $0.familyID == id }, "no live data for \(id)")
    }

    // MARK: request shape

    func testEachFamilyIsListedByPublisherNewestFirst() async throws {
        ltxOnlyHub()
        _ = try await service.check()
        let listings = hub.requests.filter { query($0, "author") != nil }
        XCTAssertEqual(Set(listings.compactMap { query($0, "author") }), ["Wan-AI", "Lightricks", "black-forest-labs", "Qwen"])
        for url in listings {
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertEqual(url.path, "/api/models")
            XCTAssertEqual(query(url, "sort"), "createdAt")
            XCTAssertEqual(query(url, "direction"), "-1")
        }
    }

    func testAppleSiliconSearchNamesTheNewestGenerationAndMLX() async throws {
        ltxOnlyHub()
        _ = try await service.check()
        let searches = hub.requests.compactMap { query($0, "search") }
        XCTAssertTrue(searches.contains("ltx-2.5 mlx"), "searched: \(searches)")
    }

    func testFamiliesWithoutAnAppleSiliconStemAreNotSearchedForBuilds() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "black-forest-labs" { return [self.row("black-forest-labs/FLUX.2-klein-4B", "2026-01-14")] }
            return []
        }
        _ = try await service.check(families: ModelWatchlist.families.filter { $0.id == "flux" })
        XCTAssertTrue(hub.requests.allSatisfy { query($0, "search") == nil })
    }

    // MARK: results

    func testNewestGenerationBuildsAndSizesAreCollected() async throws {
        ltxOnlyHub()
        let ltx = try live("ltx", in: try await service.check())
        XCTAssertNil(ltx.error)
        XCTAssertEqual(ltx.newest?.generation.text, "2.5")
        XCTAssertEqual(ltx.newest?.repos.map(\.id), ["Lightricks/LTX-2.5-Pre-Trained"], "LoRAs excluded")
        XCTAssertEqual(ltx.builds.map(\.id), ["Karam98/ltx-2.5-mlx-q4", "dgrauet/ltx-2.5-mlx-q4"], "2.3 build excluded, most downloaded first")
        XCTAssertEqual(ltx.sizes["Karam98/ltx-2.5-mlx-q4"], 13_000_000_000, "weight files only; config.json is not counted")
    }

    func testAFamilyWithNoBaseReleasesReportsNothingWithoutAnError() async throws {
        ltxOnlyHub()
        let wan = try live("wan", in: try await service.check())
        XCTAssertNil(wan.newest)
        XCTAssertNil(wan.error)
    }

    func testSizeOfAnUpstreamRepositoryIsFetchedWhenNoBuildsExist() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "Qwen" { return [self.row("Qwen/Qwen3.9-30B", "2026-09-01")] }
            if url.path.hasPrefix("/api/models/") { return self.files(["a.safetensors": 20_000_000_000]) }
            return []
        }
        let qwen = try live("qwen", in: try await service.check(families: ModelWatchlist.families.filter { $0.id == "qwen" }))
        XCTAssertEqual(qwen.sizes["Qwen/Qwen3.9-30B"], 20_000_000_000)
    }

    func testGGUFOnlyRepositoriesGetNoSizeBecauseTheirFilesAreAlternativeQuantisations() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "Qwen" { return [self.row("Qwen/Qwen3.9-30B", "2026-09-01")] }
            if url.path.hasPrefix("/api/models/") { return self.files(["q4.gguf": 9_000_000_000, "q8.gguf": 16_000_000_000]) }
            return []
        }
        let qwen = try live("qwen", in: try await service.check(families: ModelWatchlist.families.filter { $0.id == "qwen" }))
        XCTAssertNil(qwen.sizes["Qwen/Qwen3.9-30B"])
    }

    func testGatedRepositoriesAreFlaggedWhetherTheHubSaysTrueOrNamesAGateKind() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "Lightricks" { return [self.row("Lightricks/LTX-2.6-Pre-Trained", "2026-09-10", gated: "manual")] }
            return []
        }
        let ltx = try live("ltx", in: try await service.check(families: ModelWatchlist.families.filter { $0.id == "ltx" }))
        XCTAssertEqual(ltx.newest?.repos.first?.gated, true)
    }

    func testMalformedRepositoryIdsFromTheHubAreDropped() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "Lightricks" {
                return [self.row("Lightricks/../evil", "2026-09-10"), self.row("Lightricks/LTX-2.5-Pre-Trained", "2026-08-10"), ["id": 42]]
            }
            return []
        }
        let ltx = try live("ltx", in: try await service.check(families: ModelWatchlist.families.filter { $0.id == "ltx" }))
        XCTAssertEqual(ltx.newest?.repos.map(\.id), ["Lightricks/LTX-2.5-Pre-Trained"])
    }

    // MARK: failure isolation

    func testOneFamilyFailingLeavesTheOthersIntact() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "Wan-AI" { throw HubDown() }
            if self.query(url, "author") == "Lightricks" { return self.lightricks }
            return []
        }
        let snapshot = try await service.check()
        XCTAssertEqual(try live("wan", in: snapshot).error, "The Hugging Face request failed (HTTP 503).")
        XCTAssertNil(try live("ltx", in: snapshot).error)
        XCTAssertEqual(try live("ltx", in: snapshot).newest?.generation.text, "2.5")
    }

    func testAFailedBuildSearchDoesNotDiscardTheUpstreamResult() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "Lightricks" { return self.lightricks }
            if self.query(url, "search") != nil { throw HubDown() }
            return []
        }
        let ltx = try live("ltx", in: try await service.check())
        XCTAssertNil(ltx.error)
        XCTAssertEqual(ltx.newest?.generation.text, "2.5")
        XCTAssertTrue(ltx.builds.isEmpty)
    }

    func testEveryFamilyFailingIsReportedSoTheCallerCanKeepItsOldSnapshot() async throws {
        hub.handler = { _ in throw HubDown() }
        let snapshot = try await service.check()
        XCTAssertTrue(snapshot.families.allSatisfy { $0.error != nil })
        XCTAssertTrue(snapshot.isTotalFailure)
    }

    func testAPartialFailureIsNotATotalFailure() async throws {
        hub.handler = { url in
            if self.query(url, "author") == "Wan-AI" { throw HubDown() }
            return []
        }
        let snapshot = try await service.check()
        XCTAssertFalse(snapshot.isTotalFailure)
    }

    // MARK: cache

    func testSnapshotIsSavedAndReloadedAcrossInstances() async throws {
        ltxOnlyHub()
        var snapshot = try await service.check()
        snapshot.summary = "Try LTX 2.3 first."
        await service.save(snapshot)
        let reopened = ModelRadarService(transport: hub, cacheRoot: directory)
        let loaded = await reopened.loadCached()
        XCTAssertEqual(loaded?.summary, "Try LTX 2.3 first.")
        XCTAssertEqual(loaded?.families, snapshot.families)
    }

    func testMissingOrCorruptCacheIsSimplyNoSnapshot() async throws {
        let none = await service.loadCached()
        XCTAssertNil(none)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "snapshot.json"))
        let corrupt = await service.loadCached()
        XCTAssertNil(corrupt)
    }
}
