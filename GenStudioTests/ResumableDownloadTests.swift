import CryptoKit
import XCTest
@testable import GenStudio

/// Scripted HTTP responses served through URLProtocol, so the real URLSession delegate code is exercised offline.
private final class RangeFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Ending: Sendable { case finish, fail, stall }
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var chunks: [Data]
        var ending: Ending = .finish
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> Reply] = [:]
    nonisolated(unsafe) private static var ranges: [String: [String?]] = [:]

    static func serve(_ url: URL, _ handler: @escaping @Sendable (URLRequest) -> Reply) { lock.withLock { handlers[url.absoluteString] = handler; ranges[url.absoluteString] = [] } }
    static func rangeHeaders(_ url: URL) -> [String?] { lock.withLock { ranges[url.absoluteString] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url!.absoluteString
        let handler = Self.lock.withLock { () -> (@Sendable (URLRequest) -> Reply)? in
            Self.ranges[key, default: []].append(request.value(forHTTPHeaderField: "Range"))
            return Self.handlers[key]
        }
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        let reply = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        switch reply.ending {
        case .finish: client?.urlProtocolDidFinishLoading(self)
        case .fail: client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .stall: break
        }
    }
    override func stopLoading() {}
}

private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock(); private var value: Int64 = 0
    func record(_ bytes: Int64) { lock.withLock { value = max(value, bytes) } }
    var latest: Int64 { lock.withLock { value } }
}

final class ResumableDownloadTests: XCTestCase {
    private var root: URL!
    private let body = Data((0..<100).map { UInt8($0) })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "resume-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var transport: StreamingModelTransport {
        StreamingModelTransport(makeConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RangeFixtureProtocol.self]
            return configuration
        })
    }
    private func url() -> URL { URL(string: "https://huggingface.co/test/repo/resolve/\(String(repeating: "c", count: 40))/\(UUID().uuidString).gguf")! }

    // MARK: Pure response validation

    func testContentRangeValidationIsExact() throws {
        XCTAssertEqual(try ResumeResponse.decide(requestedOffset: 0, expectedBytes: 100, status: 200, contentRange: nil, contentLength: 100), .restart)
        XCTAssertEqual(try ResumeResponse.decide(requestedOffset: 40, expectedBytes: 100, status: 200, contentRange: nil, contentLength: -1), .restart, "An ignored Range restarts instead of appending")
        XCTAssertEqual(try ResumeResponse.decide(requestedOffset: 40, expectedBytes: 100, status: 206, contentRange: "bytes 40-99/100", contentLength: 60), .append)
        XCTAssertThrowsError(try ResumeResponse.decide(requestedOffset: 0, expectedBytes: 100, status: 200, contentRange: nil, contentLength: 99))
        for header in ["bytes 0-99/100", "bytes 40-98/100", "bytes 40-99/101", "bytes 40-99/*", "bytes  40-99/100", "bytes 40-99/100 ", "items 40-99/100", "bytes -40-99/100", "bytes 4a-99/100"] {
            XCTAssertThrowsError(try ResumeResponse.decide(requestedOffset: 40, expectedBytes: 100, status: 206, contentRange: header, contentLength: nil), header) { error in
                XCTAssertTrue((error as? DownloadResponseError)?.discardsPartial == true)
            }
        }
        XCTAssertThrowsError(try ResumeResponse.decide(requestedOffset: 0, expectedBytes: 100, status: 206, contentRange: "bytes 0-99/100", contentLength: nil), "206 without a Range request")
        XCTAssertThrowsError(try ResumeResponse.decide(requestedOffset: 40, expectedBytes: 100, status: 206, contentRange: "bytes 40-99/100", contentLength: 59))
        XCTAssertThrowsError(try ResumeResponse.decide(requestedOffset: 40, expectedBytes: 100, status: 416, contentRange: nil, contentLength: nil)) { XCTAssertEqual($0 as? DownloadResponseError, .invalidRange("requested range not satisfiable")) }
        XCTAssertThrowsError(try ResumeResponse.decide(requestedOffset: 40, expectedBytes: 100, status: 403, contentRange: nil, contentLength: nil)) { XCTAssertEqual(($0 as? DownloadResponseError)?.discardsPartial, false) }
    }

    // MARK: Transport against scripted responses

    func testFreshDownloadWith200() async throws {
        let source = url(), part = root.appending(path: "a.part"), body = body
        RangeFixtureProtocol.serve(source) { _ in .init(status: 200, headers: ["Content-Length": "100"], chunks: [body.prefix(30), body.dropFirst(30)]) }
        try await transport.download(from: source, to: part, expectedBytes: 100) { _ in }
        XCTAssertEqual(try Data(contentsOf: part), body)
        XCTAssertEqual(RangeFixtureProtocol.rangeHeaders(source), [nil])
    }

    func testValid206ResumesFromSavedPrefix() async throws {
        let source = url(), part = root.appending(path: "a.part"), body = body
        try body.prefix(40).write(to: part)
        RangeFixtureProtocol.serve(source) { request in
            request.value(forHTTPHeaderField: "Range") == "bytes=40-"
                ? .init(status: 206, headers: ["Content-Range": "bytes 40-99/100", "Content-Length": "60"], chunks: [body.dropFirst(40)])
                : .init(status: 500, chunks: [])
        }
        let probe = ProgressProbe()
        try await transport.download(from: source, to: part, expectedBytes: 100) { probe.record($0) }
        XCTAssertEqual(try Data(contentsOf: part), body)
        XCTAssertEqual(RangeFixtureProtocol.rangeHeaders(source), ["bytes=40-"])
        XCTAssertEqual(probe.latest, 100)
    }

    func testIgnoredRangeRestartsInsteadOfAppending() async throws {
        let source = url(), part = root.appending(path: "a.part"), body = body
        try Data(repeating: 0xEE, count: 40).write(to: part)
        RangeFixtureProtocol.serve(source) { _ in .init(status: 200, headers: ["Content-Length": "100"], chunks: [body]) }
        try await transport.download(from: source, to: part, expectedBytes: 100) { _ in }
        XCTAssertEqual(try Data(contentsOf: part), body, "The stale prefix is replaced, never prepended")
    }

    func testInvalidContentRangeDiscardsSavedPrefix() async throws {
        let source = url(), part = root.appending(path: "a.part"), body = body
        try body.prefix(40).write(to: part)
        RangeFixtureProtocol.serve(source) { _ in .init(status: 206, headers: ["Content-Range": "bytes 0-99/100"], chunks: [body]) }
        do { try await transport.download(from: source, to: part, expectedBytes: 100) { _ in }; XCTFail("Mismatched Content-Range must be rejected") }
        catch { XCTAssertEqual((error as? DownloadResponseError)?.discardsPartial, true, "\(error)") }
        XCTAssertEqual(try Data(contentsOf: part).count, 0)
    }

    func testOversizedAndHTTPErrorsAreHandledSafely() async throws {
        let big = url(), denied = url(), part = root.appending(path: "a.part"), other = root.appending(path: "b.part"), body = body
        RangeFixtureProtocol.serve(big) { _ in .init(status: 200, chunks: [body, Data([1])]) }
        do { try await transport.download(from: big, to: part, expectedBytes: 100) { _ in }; XCTFail("Oversized body") } catch { XCTAssertEqual(error as? DownloadResponseError, .oversized) }
        XCTAssertLessThanOrEqual(try Data(contentsOf: part).count, 100)

        try body.prefix(40).write(to: other)
        RangeFixtureProtocol.serve(denied) { _ in .init(status: 403, chunks: []) }
        do { try await transport.download(from: denied, to: other, expectedBytes: 100) { _ in }; XCTFail("HTTP 403") } catch { XCTAssertEqual(error as? DownloadResponseError, .http(403)) }
        XCTAssertEqual(try Data(contentsOf: other), body.prefix(40), "An access error keeps saved progress")
    }

    func testCancellationAndNetworkFailureKeepBoundedPartial() async throws {
        // Realistic chunk sizes: URLSession may coalesce tiny chunks and deliver them only at completion.
        let large = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }), total = Int64(large.count)
        let stalled = url(), dropped = url(), part = root.appending(path: "a.part"), other = root.appending(path: "b.part")
        let half = large.prefix(1 << 19)
        RangeFixtureProtocol.serve(stalled) { _ in .init(status: 200, headers: ["Content-Length": String(total)], chunks: [half], ending: .stall) }
        let probe = ProgressProbe(), transport = transport
        let job = Task { try await transport.download(from: stalled, to: part, expectedBytes: total) { probe.record($0) } }
        for _ in 0..<400 where probe.latest < Int64(half.count) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(probe.latest, Int64(half.count), "Fixture data reached the transport before cancellation")
        job.cancel()
        do { try await job.value; XCTFail("Expected cancellation") } catch is CancellationError { } catch { XCTFail("Wrong error \(error)") }
        XCTAssertEqual(try Data(contentsOf: part), half, "Cancellation keeps exactly the bytes received")

        let failureProbe = ProgressProbe()
        RangeFixtureProtocol.serve(dropped) { _ in .init(status: 200, headers: ["Content-Length": String(total)], chunks: [half], ending: .fail) }
        do { try await transport.download(from: dropped, to: other, expectedBytes: total) { failureProbe.record($0) }; XCTFail("Expected network failure") } catch { }
        let saved = try Data(contentsOf: other)
        XCTAssertEqual(Int64(saved.count), failureProbe.latest, "Saved bytes match reported progress")
        XCTAssertEqual(saved, large.prefix(saved.count), "Only a verified-order prefix is kept")
        XCTAssertLessThanOrEqual(saved.count, large.count)
    }

    func testTransportRefusesSymlinkedPartial() async throws {
        let target = root.appending(path: "elsewhere"), link = root.appending(path: "a.part")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do { try await transport.download(from: url(), to: link, expectedBytes: 100) { _ in }; XCTFail("Symlink must be refused") } catch { }
    }

    // MARK: Library integration

    private func gguf(_ marker: UInt8) -> Data { Data([71, 71, 85, 70, 3, 0, 0, 0] + Array(repeating: marker, count: 64)) }
    private func recipe(_ data: Data) -> ModelRecipe {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return .init(id: "resume-fixture", name: "Resume", kind: .image, engineID: "stable-diffusion.cpp", components: [
            .init(id: "checkpoint", role: "checkpoint", repository: "test/resume", revision: String(repeating: "c", count: 40), filename: "model.gguf", byteSize: Int64(data.count), sha256: hash, license: "test")
        ], runtimeReady: false, minimumMemoryBytes: 1)
    }

    func testInterruptedInstallResumesInANewLibraryInstanceAndRegistersOnlyVerifiedFile() async throws {
        let data = gguf(7), recipe = recipe(data)
        let first = ModelLibrary(root: root, catalog: [recipe], transport: HalfThenFailTransport(data: data), diskAvailable: { _ in Int64.max })
        do { _ = try await first.install(recipe: recipe); XCTFail("First attempt fails mid-transfer") } catch { }
        let installedAfterFailure = try await first.installedModels()
        XCTAssertTrue(installedAfterFailure.isEmpty, "A partial model is never registered")
        let summary = try await first.partialDownloadSummary()
        XCTAssertEqual(summary.count, 1); XCTAssertEqual(summary.bytes, Int64(data.count / 2))

        // A fresh instance models an app restart: only disk state carries over.
        let resume = AppendingTransport(data: data)
        let restarted = ModelLibrary(root: root, catalog: [recipe], transport: resume, diskAvailable: { _ in Int64.max })
        let installed = try await restarted.install(recipe: recipe)
        XCTAssertEqual(resume.startOffsets, [Int64(data.count / 2)])
        XCTAssertEqual(try Data(contentsOf: installed.components[0].fileURL), data)
        let afterInstall = try await restarted.partialDownloadSummary()
        XCTAssertEqual(afterInstall.count, 0, "The completed part is handed off into the installed model")
    }

    func testCompleteSavedPartIsVerifiedWithoutNetworkAndCorruptPartIsDiscarded() async throws {
        let data = gguf(8), recipe = recipe(data)
        let store = PartialDownloadStore(root: root)
        let part = try XCTUnwrap(store.url(for: recipe.components[0]))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        var corrupt = data; corrupt[20] = 0xFF
        try corrupt.write(to: part)
        let never = AppendingTransport(data: data)
        let library = ModelLibrary(root: root, catalog: [recipe], transport: never, diskAvailable: { _ in Int64.max })
        do { _ = try await library.install(recipe: recipe); XCTFail("Checksum mismatch") } catch { XCTAssertTrue(error.localizedDescription.contains("Checksum"), error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path), "A full-size part that fails SHA-256 is discarded")
        XCTAssertTrue(never.startOffsets.isEmpty)

        try data.write(to: part)
        let installed = try await library.install(recipe: recipe)
        XCTAssertTrue(never.startOffsets.isEmpty, "A complete saved part needs no network")
        XCTAssertEqual(try Data(contentsOf: installed.components[0].fileURL), data)
    }

    func testDiscardRemovesOnlyPartialsAndRefusesRedirectedDirectory() async throws {
        let store = PartialDownloadStore(root: root)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let valid = store.directory.appending(path: try XCTUnwrap(PartialDownloadStore.fileName(sha256: String(repeating: "a", count: 64), byteSize: 10)))
        let unrelated = store.directory.appending(path: "notes.txt")
        try Data(count: 5).write(to: valid); try Data(count: 5).write(to: unrelated)
        let library = ModelLibrary(root: root, diskAvailable: { _ in Int64.max })
        let summary = try await library.partialDownloadSummary()
        XCTAssertEqual(summary.count, 1)
        let removed = try await library.discardPartialDownloads()
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

        let other = FileManager.default.temporaryDirectory.appending(path: "redirect-\(UUID())"); defer { try? FileManager.default.removeItem(at: other) }
        let redirectedRoot = root.appending(path: "redirected")
        try FileManager.default.createDirectory(at: redirectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: redirectedRoot.appending(path: ".partial"), withDestinationURL: other)
        do { _ = try await ModelLibrary(root: redirectedRoot).discardPartialDownloads(); XCTFail("Redirected directory") } catch { XCTAssertTrue(error.localizedDescription.contains("redirected")) }
    }

    func testPartialNamesAreKeyedByHashAndSizeAndLockedAgainstSecondWriter() throws {
        XCTAssertNil(PartialDownloadStore.fileName(sha256: "../../etc", byteSize: 10))
        XCTAssertNil(PartialDownloadStore.fileName(sha256: String(repeating: "a", count: 64), byteSize: 0))
        XCTAssertEqual(PartialDownloadStore.fileName(sha256: String(repeating: "A", count: 64), byteSize: 10), String(repeating: "a", count: 64) + "-10.part")
        XCTAssertFalse(PartialDownloadStore.isPartialName("x-10.part"))
        let part = root.appending(path: "locked.part")
        do {
            let first = try PartialDownloadLock(part)
            XCTAssertThrowsError(try PartialDownloadLock(part), "A second writer is refused while the first holds the lock")
            withExtendedLifetime(first) {}
        }
        XCTAssertNoThrow(try PartialDownloadLock(part), "Releasing the lock allows a later resume")
    }

    // MARK: Prompt syntax

    func testLoRAPromptSyntaxIsRejectedButOrdinaryAngleBracketsAreNot() throws {
        XCTAssertNoThrow(try EnginePromptSyntax.validate("a <red> cat, 2 < 3, lora style, <loraish>"))
        XCTAssertThrowsError(try EnginePromptSyntax.validate("a cat <LoRA:style:1>"))
        XCTAssertThrowsError(try EnginePromptSyntax.validate("fine", "<lora:x:0.5>"), "Negative prompts are checked too")
        XCTAssertNoThrow(try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .textToImage, prompt: "a <blue> bird", width: 512, height: 512, seed: 1, strength: nil, registry: ImageCapabilityRegistry.shipped))
        XCTAssertThrowsError(try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .textToImage, prompt: "a bird <lora:x:1>", width: 512, height: 512, seed: 1, strength: nil, registry: ImageCapabilityRegistry.shipped)) { error in
            XCTAssertTrue(error.localizedDescription.contains("node’s settings"), error.localizedDescription)
        }
        let settings = VideoGenerationSettings(), capability = VideoFixtures.verifiedRegistry[0]
        let request = try VideoRequestPlanner.makeRequest(settings: settings, task: .textToVideo, capability: capability, prompt: "waves <slow>", negativePrompt: nil)
        XCTAssertThrowsError(try VideoRequestPlanner.makeRequest(settings: settings, task: .textToVideo, capability: capability, prompt: "waves", negativePrompt: "<LORA:blur:1>"))
        // Command builders refuse the syntax too, in case a request is constructed without the planner.
        let tagged = VideoGenerationRequest(task: .textToVideo, recipeID: request.recipeID, engineBuild: request.engineBuild, prompt: "x <lora:y:1>", negativePrompt: "", width: 320, height: 192, frameCount: 9, fps: 8, steps: 20, cfgScale: 6, flowShift: 3, sampler: "euler", seed: 1, mediaInputs: [])
        let components = WanTextToVideoCommand.Components(diffusion: URL(fileURLWithPath: "/m/d.gguf"), textEncoder: URL(fileURLWithPath: "/m/t.gguf"), vae: URL(fileURLWithPath: "/m/v.safetensors"))
        XCTAssertThrowsError(try WanTextToVideoCommand.arguments(tagged, components: components, framePattern: URL(fileURLWithPath: "/w/f.png")))
    }
}

private struct HalfThenFailTransport: ModelDownloadTransport {
    let data: Data
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try data.prefix(data.count / 2).write(to: to)
        throw URLError(.networkConnectionLost)
    }
}

/// Appends the missing suffix to whatever is saved, recording the offset it resumed from.
private final class AppendingTransport: ModelDownloadTransport, @unchecked Sendable {
    let data: Data
    private let lock = NSLock(); private var offsets: [Int64] = []
    init(data: Data) { self.data = data }
    var startOffsets: [Int64] { lock.withLock { offsets } }
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let handle = try FileHandle(forUpdating: to); defer { try? handle.close() }
        let saved = try handle.seekToEnd()
        lock.withLock { offsets.append(Int64(saved)) }
        try handle.write(contentsOf: data.dropFirst(Int(saved)))
    }
}
