import XCTest
@testable import GenStudio

final class ModelSizeSummaryTests: XCTestCase {
    private func file(_ path: String, _ bytes: Int64?) -> DiscoveryFile {
        .init(path: path, bytes: bytes, sha256: nil)
    }

    func testAlternativeGGUFVersionsExcludeProjectorAndNeverSumRepository() {
        let summary = ModelSizeSummary.summarize(repository: "test/model", revision: nil, files: [
            file("model.Q4.gguf", 4_000_000_000), file("model.Q8.gguf", 8_000_000_000),
            file("mmproj-F16.gguf", 900_000_000), file("README.md", 200), file("config.json", 10)
        ], recipes: [])
        XCTAssertEqual(summary.minBytes, 4_000_000_000)
        XCTAssertEqual(summary.maxBytes, 8_000_000_000)
        XCTAssertEqual(summary.label, "GGUF files")
        XCTAssertTrue(summary.detail.contains("Choose one version"))
    }

    func testCompleteShardsAreSummedButIncompleteDuplicateAndOverflowSetsAreExcluded() {
        let summary = ModelSizeSummary.summarize(repository: "test/model", revision: nil, files: [
            file("model.Q4-00001-of-00002.gguf", 3_000_000_000), file("model.Q4-00002-of-00002.gguf", 2_000_000_000),
            file("model.Q8-00001-of-00002.gguf", 7_000_000_000),
            file("overflow-00001-of-00002.gguf", Int64.max), file("overflow-00002-of-00002.gguf", 1),
            file("duplicate-00001-of-00002.gguf", 50), file("duplicate-00001-of-00002.gguf", 50)
        ], recipes: [])
        XCTAssertEqual(summary.minBytes, 5_000_000_000)
        XCTAssertEqual(summary.maxBytes, 5_000_000_000)
        XCTAssertEqual(summary.label, "Known gguf files")
        XCTAssertTrue(summary.detail.contains("missing"))
    }

    func testUnknownDoesNotInventZeroAndWeightsAreNotCompleteDownloads() {
        for files in [[file("model.gguf", nil)], [file("model.gguf", -1)], [file("config.json", 20)]] {
            let summary = ModelSizeSummary.summarize(repository: "test/model", revision: nil, files: files, recipes: [])
            XCTAssertNil(summary.minBytes)
            XCTAssertEqual(summary.title, "Size unavailable")
        }
        let weights = ModelSizeSummary.summarize(repository: "test/model", revision: nil, files: [
            file("model-00001-of-00002.safetensors", 4_000_000_000), file("model-00002-of-00002.safetensors", 3_000_000_000),
            file("pytorch_model.bin", 8_000_000_000), file("tokenizer.bin", 1_000_000)
        ], recipes: [])
        XCTAssertEqual(weights.minBytes, 7_000_000_000)
        XCTAssertEqual(weights.maxBytes, 8_000_000_000)
        XCTAssertEqual(weights.label, "Weight files")
        XCTAssertTrue(weights.detail.contains("not complete"))
    }

    func testDownloadRequiresExactCompletePackageIncludingProjector() throws {
        let recipe = try XCTUnwrap(VisionModelCatalog.recipes.first)
        let component = try XCTUnwrap(recipe.components.first)
        let files = recipe.components.map { DiscoveryFile(path: $0.filename, bytes: $0.byteSize, sha256: $0.sha256) }
        let full = ModelSizeSummary.summarize(repository: component.repository, revision: component.revision, files: files, recipes: [recipe])
        XCTAssertEqual(full.minBytes, recipe.totalBytes)
        XCTAssertEqual(full.label, "Download")
        for (revision, inventory) in [(Optional(component.revision), Array(files.prefix(1))), (Optional(String(repeating: "f", count: 40)), files)] {
            let partial = ModelSizeSummary.summarize(repository: component.repository, revision: revision, files: inventory, recipes: [recipe])
            XCTAssertNotEqual(partial.label, "Download")
        }
        let tampered = files.map { DiscoveryFile(path: $0.path, bytes: $0.bytes, sha256: "invalid") }
        XCTAssertNotEqual(ModelSizeSummary.summarize(repository: component.repository, revision: component.revision, files: tampered, recipes: [recipe]).label, "Download")
    }

    func testPinnedMetadataOnlyLookupCachesAcrossRestartAndRejectsChangedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ModelSizeFixture()
        let revision = String(repeating: "a", count: 40)
        let first = try await ModelDiscovery(cacheRoot: root, transport: transport).modelSize(repository: "test/model", revision: revision)
        XCTAssertEqual(first.minBytes, 4_000_000_000)
        let restarted = try await ModelDiscovery(cacheRoot: root, transport: transport).modelSize(repository: "test/model", revision: revision)
        XCTAssertEqual(first, restarted)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.path, "/api/models/test/model/revision/\(revision)")
        XCTAssertEqual(requests.first?.query, "blobs=true")
        do {
            _ = try await ModelDiscovery(cacheRoot: root, transport: transport).modelSize(repository: "test/model", revision: String(repeating: "b", count: 40))
            XCTFail("A different revision must not reuse cached data or accept the wrong revision")
        } catch { }
    }

    func testSizeRequestsAreBoundedAndCanceledWaitersDoNotLeakSlots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ModelSizeFixture(delay: .milliseconds(40))
        let discovery = ModelDiscovery(cacheRoot: root, transport: transport)
        let tasks = (0..<12).map { index in Task {
            try await discovery.modelSize(repository: "test/model\(index)", revision: nil)
        } }
        try await Task.sleep(for: .milliseconds(10))
        tasks[8].cancel()
        for task in tasks { _ = try? await task.value }
        let peak = await transport.peak()
        XCTAssertLessThanOrEqual(peak, 4)
        _ = try await discovery.modelSize(repository: "test/final", revision: nil)
    }

    func testBothMetadataPathsRejectInvalidNumericSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = ModelDiscovery(cacheRoot: root, transport: InvalidSizeFixture())
        let summary = try await discovery.modelSize(repository: "test/model", revision: nil)
        XCTAssertNil(summary.minBytes)
        let detail = try await discovery.detail(repository: "test/model")
        XCTAssertEqual(detail.files.count, 5)
        XCTAssertTrue(detail.files.allSatisfy { $0.bytes == nil })
        XCTAssertNil(ModelSizeSummary.summarize(repository: "test/model", revision: nil, files: detail.files, recipes: []).minBytes)
    }
}

private struct InvalidSizeFixture: DiscoveryTransport {
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        let json = #"{"id":"test/model","siblings":[{"rfilename":"bool.gguf","size":true},{"rfilename":"fraction.gguf","size":1.5},{"rfilename":"overflow.gguf","size":18446744073709551615},{"rfilename":"negative.gguf","size":-1},{"rfilename":"missing.gguf"}]}"#
        return .init(data: Data(json.utf8), nextLink: nil)
    }
}

private actor ModelSizeFixture: DiscoveryTransport {
    private var urls: [URL] = []
    private var active = 0
    private var maximum = 0
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func requests() -> [URL] { urls }
    func peak() -> Int { maximum }
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        urls.append(url)
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        let path = url.pathComponents
        let id = path.dropFirst(3).prefix(2).joined(separator: "/")
        let json: [String: Any] = ["id": id, "sha": String(repeating: "a", count: 40), "siblings": [
            ["rfilename": "model.gguf", "size": 4_000_000_000], ["rfilename": "README.md", "size": 30]
        ]]
        return .init(data: try JSONSerialization.data(withJSONObject: json), nextLink: nil)
    }
}
