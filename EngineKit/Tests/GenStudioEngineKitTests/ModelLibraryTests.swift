import Foundation
import XCTest
@testable import GenStudioEngineKit

final class ModelLibraryTests: XCTestCase {
    func testLiveFixtureLifecycle() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["HF_INTEGRATION_ROOT"] else {
            throw XCTSkip("Set HF_INTEGRATION_ROOT to run the public network fixture")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let library = try ModelLibrary(root: root)
        let repositories = try await library.searchRepositories(query: "Qwen/Qwen2.5-0.5B-Instruct-GGUF", limit: 10)
        let repository = try XCTUnwrap(repositories.first { $0.id == "Qwen/Qwen2.5-0.5B-Instruct-GGUF" })
        XCTAssertEqual(repository.revision, "9217f5db79a29953eb74d5343926648285ec7e67")
        XCTAssertFalse(repository.gated)
        XCTAssertEqual(repository.license, "apache-2.0")
        let files = try await library.listGGUFFiles(repositoryID: repository.id, revision: repository.revision)
        let file = try XCTUnwrap(files.first { $0.name == "qwen2.5-0.5b-instruct-q4_k_m.gguf" })
        XCTAssertEqual(file.size, 491_400_032)
        XCTAssertEqual(file.sha256, "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db")
        let installed = try await library.download(file)
        XCTAssertEqual(installed.architecture, "qwen2")
        XCTAssertEqual(installed.sha256, file.sha256)
        let reopened = try ModelLibrary(root: root)
        let persisted = await reopened.models()
        XCTAssertEqual(persisted.map(\.id), [installed.id])
        XCTAssertEqual(persisted.first?.availability, .available)
        XCTAssertEqual(persisted.first?.inferenceVerification, .unverified)
    }

    func testSearchAndPinnedMetadata() async throws {
        let search = #"[{"id":"Qwen/Test","sha":"9217f5db79a29953eb74d5343926648285ec7e67","gated":false,"tags":["license:apache-2.0"]}]"#.data(using: .utf8)!
        let detail = #"{"id":"Qwen/Test","sha":"9217f5db79a29953eb74d5343926648285ec7e67","gated":false,"cardData":{"license":"apache-2.0"},"siblings":[{"rfilename":"model.gguf","size":99,"lfs":{"sha256":"abc","size":99}},{"rfilename":"model-00001-of-00002.gguf","size":50}]}"#.data(using: .utf8)!
        let http = MockHTTP(dataResponses: [search, detail])
        let library = try ModelLibrary(root: temporaryDirectory(), httpClient: http)
        let repositories = try await library.searchRepositories(query: "qwen")
        XCTAssertEqual(repositories.first?.license, "apache-2.0")
        let files = try await library.listGGUFFiles(repositoryID: repositories[0].id, revision: repositories[0].revision)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].sha256, "abc")
    }

    func testImportExternalMissingUnregisterAndPersistedReload() async throws {
        let root = temporaryDirectory()
        let source = root.appending(path: "fixture.gguf")
        try makeGGUF(architecture: "qwen2").write(to: source)
        let library = try ModelLibrary(root: root)
        let imported = try await library.importGGUF(from: source, copyIntoLibrary: false)
        XCTAssertEqual(imported.inferenceVerification, .unverified)
        XCTAssertEqual(imported.architecture, "qwen2")
        let reopened = try ModelLibrary(root: root)
        var models = await reopened.models()
        XCTAssertEqual(models.count, 1)
        try FileManager.default.removeItem(at: source)
        models = await reopened.models()
        XCTAssertEqual(models[0].availability, .missing)
        try await reopened.unregister(id: imported.id)
        models = await reopened.models()
        XCTAssertEqual(models.count, 0)
    }

    func testManagedImportCopiesAndPreservesSource() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory().appending(path: "source.gguf")
        try makeGGUF(architecture: "qwen3moe").write(to: external)
        let library = try ModelLibrary(root: root)
        let model = try await library.importGGUF(from: external, copyIntoLibrary: true)
        XCTAssertEqual(model.ownership, .managed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.filePath))
        try await library.unregister(id: model.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.filePath), "unregister must not delete weights")
    }

    func testRejectsUnsupportedAndInvalidHeaders() throws {
        let root = temporaryDirectory()
        let unsupported = root.appending(path: "mistral.gguf")
        try makeGGUF(architecture: "mistral3").write(to: unsupported)
        XCTAssertThrowsError(try GGUFParser.parse(url: unsupported))
        let bogus = root.appending(path: "bogus.gguf")
        try Data("NOPE".utf8).write(to: bogus)
        XCTAssertThrowsError(try GGUFParser.parse(url: bogus))
    }

    func testHTTPAndMalformedResponsesAreVisible() async throws {
        let root = temporaryDirectory()
        let failing = try ModelLibrary(root: root, httpClient: MockHTTP(dataResponses: [Data()], status: 403))
        await XCTAssertThrowsErrorAsync { _ = try await failing.searchRepositories(query: "x") }
        let malformed = try ModelLibrary(root: temporaryDirectory(), httpClient: MockHTTP(dataResponses: [Data("{".utf8)]))
        await XCTAssertThrowsErrorAsync { _ = try await malformed.searchRepositories(query: "x") }
    }

    func testDownloadLengthChecksumAndCancellationNeverRegister() async throws {
        let data = makeGGUF(architecture: "qwen2")
        let repo = HFRepository(id: "Qwen/Test", revision: "9217f5db79a29953eb74d5343926648285ec7e67", gated: false, license: nil)
        let badLength = HFGGUFFile(repository: repo, name: "model.gguf", size: Int64(data.count + 1), sha256: nil)
        let library = try ModelLibrary(root: temporaryDirectory(), httpClient: MockHTTP(downloadData: data))
        await XCTAssertThrowsErrorAsync { _ = try await library.download(badLength) }
        var models = await library.models()
        XCTAssertEqual(models.count, 0)

        let badHash = HFGGUFFile(repository: repo, name: "model.gguf", size: Int64(data.count), sha256: String(repeating: "0", count: 64))
        await XCTAssertThrowsErrorAsync { _ = try await library.download(badHash) }
        models = await library.models()
        XCTAssertEqual(models.count, 0)

        let cancelledLibrary = try ModelLibrary(root: temporaryDirectory(), httpClient: MockHTTP(downloadData: data, suspendDownload: true))
        let task = Task { try await cancelledLibrary.download(HFGGUFFile(repository: repo, name: "model.gguf", size: Int64(data.count), sha256: nil)) }
        task.cancel()
        await XCTAssertThrowsErrorAsync { _ = try await task.value }
        models = await cancelledLibrary.models()
        XCTAssertEqual(models.count, 0)
    }

    func testCorruptAndNewerRegistryRemainUntouched() throws {
        for content in [Data("not json".utf8), Data("{\"schemaVersion\":999,\"models\":[]}".utf8)] {
            let root = temporaryDirectory()
            let registry = root.appending(path: "registry.json")
            try content.write(to: registry)
            XCTAssertThrowsError(try ModelLibrary(root: root))
            XCTAssertEqual(try Data(contentsOf: registry), content)
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class MockHTTP: HFHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var dataResponses: [Data]
    private let status: Int
    private let downloadData: Data
    private let suspendDownload: Bool
    init(dataResponses: [Data] = [], status: Int = 200, downloadData: Data = Data(), suspendDownload: Bool = false) {
        self.dataResponses = dataResponses; self.status = status; self.downloadData = downloadData; self.suspendDownload = suspendDownload
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = lock.withLock { dataResponses.removeFirst() }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func download(for request: URLRequest, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> HTTPURLResponse {
        if suspendDownload { try await Task.sleep(for: .seconds(10)) }
        try Task.checkCancellation()
        try downloadData.write(to: destination)
        progress(DownloadProgress(receivedBytes: Int64(downloadData.count), expectedBytes: Int64(downloadData.count)))
        return HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private func makeGGUF(architecture: String, version: UInt32 = 3) -> Data {
    var data = Data([0x47, 0x47, 0x55, 0x46])
    data.appendLE(version); data.appendLE(UInt64(0)); data.appendLE(UInt64(1))
    data.appendString("general.architecture"); data.appendLE(UInt32(8)); data.appendString(architecture)
    return data
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    mutating func appendString(_ value: String) {
        let bytes = Data(value.utf8); appendLE(UInt64(bytes.count)); append(bytes)
    }
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("expected error", file: file, line: line) } catch {}
}
