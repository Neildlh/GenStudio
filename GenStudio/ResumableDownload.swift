import Foundation
import Darwin

/// Why a download response cannot be used. `discardsPartial` marks responses that prove the saved prefix unusable.
enum DownloadResponseError: LocalizedError, Equatable {
    case invalidRange(String)
    case unexpectedLength
    case oversized
    case endedEarly(saved: Int64, expected: Int64)
    case http(Int)

    var discardsPartial: Bool {
        switch self {
        case .invalidRange, .oversized: true
        case .unexpectedLength, .endedEarly, .http: false
        }
    }
    var errorDescription: String? {
        switch self {
        case .invalidRange(let detail): "The server could not continue the saved download (\(detail)). The saved part was discarded; installing again starts this file from the beginning."
        case .unexpectedLength: "The server reported a different file size than the pinned recipe. Nothing was added to the saved download."
        case .oversized: "The download exceeded its pinned size and was discarded."
        case .endedEarly(let saved, let expected): "The connection ended after \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)). Progress is kept; install again to resume."
        case .http(let status): GenerationLibraryError.hub(status: status, action: "Model download").errorDescription ?? "Model download failed (HTTP \(status))."
        }
    }
}

/// Pure validation of a response to a (possibly ranged) request for a file of known size.
enum ResumeResponse {
    enum Decision: Equatable { case append, restart }

    static func decide(requestedOffset: Int64, expectedBytes: Int64, status: Int, contentRange: String?, contentLength: Int64?) throws -> Decision {
        let length = contentLength.flatMap { $0 >= 0 ? $0 : nil }
        switch status {
        case 200:
            // A full response, including a server or CDN that ignored Range: never append it to the saved prefix.
            if let length, length != expectedBytes { throw DownloadResponseError.unexpectedLength }
            return .restart
        case 206:
            guard requestedOffset > 0, let contentRange, let range = parse(contentRange) else {
                throw DownloadResponseError.invalidRange("unexpected partial response")
            }
            guard range.first == requestedOffset, range.last == expectedBytes - 1, range.total == expectedBytes else {
                throw DownloadResponseError.invalidRange("range \(contentRange) does not continue at byte \(requestedOffset)")
            }
            if let length, length != expectedBytes - requestedOffset { throw DownloadResponseError.invalidRange("partial length mismatch") }
            return .append
        case 416:
            throw DownloadResponseError.invalidRange("requested range not satisfiable")
        default:
            throw DownloadResponseError.http(status)
        }
    }

    /// Accepts only `bytes FIRST-LAST/TOTAL` with decimal integers and no extra text.
    static func parse(_ header: String) -> (first: Int64, last: Int64, total: Int64)? {
        guard header.hasPrefix("bytes ") else { return nil }
        let body = header.dropFirst(6)
        let slash = body.split(separator: "/", omittingEmptySubsequences: false)
        guard slash.count == 2 else { return nil }
        let bounds = slash[0].split(separator: "-", omittingEmptySubsequences: false)
        func number(_ text: Substring) -> Int64? { text.isEmpty || !text.allSatisfy(\.isASCII) || !text.allSatisfy(\.isNumber) ? nil : Int64(text) }
        guard bounds.count == 2, let first = number(bounds[0]), let last = number(bounds[1]), let total = number(slash[1]), first <= last, last < total else { return nil }
        return (first, last, total)
    }
}

/// Resumable HTTP transport. Bytes stream straight into the destination file; a saved prefix is continued only when
/// the server answers with the exact matching Content-Range. Otherwise the prefix is replaced or discarded.
struct StreamingModelTransport: ModelDownloadTransport {
    let makeConfiguration: @Sendable () -> URLSessionConfiguration

    init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = StreamingModelTransport.defaultConfiguration) {
        self.makeConfiguration = makeConfiguration
    }
    static let defaultConfiguration: @Sendable () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let transfer = try ResumableTransfer(destination: to, expectedBytes: expectedBytes, progress: progress, configuration: makeConfiguration())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(url: from, continuation: $0) }
        } onCancel: { transfer.cancel() }
    }
}

private final class ResumableTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let configuration: URLSessionConfiguration
    // File state is touched only on the serial delegate queue after start.
    private let file: FileHandle
    private var written: Int64
    private let requestedOffset: Int64
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var failure: Error?

    init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void, configuration: URLSessionConfiguration) throws {
        guard expectedBytes > 0 else { throw GenerationLibraryError.invalid("Invalid pinned component size.") }
        let descriptor = open(destination.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GenerationLibraryError.invalid("Cannot open the partial download file.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor); throw GenerationLibraryError.invalid("The partial download is not a regular file.")
        }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var saved = Int64(info.st_size)
        if saved > expectedBytes { try file.truncate(atOffset: 0); saved = 0 }
        written = saved; requestedOffset = saved
        self.expectedBytes = expectedBytes; self.progress = progress; self.configuration = configuration
    }

    func start(url: URL, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        if requestedOffset == expectedBytes { lock.unlock(); try? file.close(); continuation.resume(); return }
        self.continuation = continuation
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if requestedOffset > 0 { request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let dataTask = session.dataTask(with: request); task = dataTask
        lock.unlock()
        if requestedOffset > 0 { progress(requestedOffset) }
        dataTask.resume()
    }

    func cancel() { lock.lock(); cancelled = true; let active = task; lock.unlock(); active?.cancel() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { fail(DownloadResponseError.http(0)); completionHandler(.cancel); return }
        do {
            let decision = try ResumeResponse.decide(requestedOffset: requestedOffset, expectedBytes: expectedBytes, status: http.statusCode,
                contentRange: http.value(forHTTPHeaderField: "Content-Range"), contentLength: http.expectedContentLength)
            if decision == .restart {
                try file.truncate(atOffset: 0); written = 0
            } else {
                try file.seek(toOffset: UInt64(requestedOffset))
            }
            completionHandler(.allow)
        } catch {
            fail(error); completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        let next = written.addingReportingOverflow(Int64(data.count))
        guard !next.overflow, next.partialValue <= expectedBytes else { fail(DownloadResponseError.oversized); dataTask.cancel(); return }
        do { try file.write(contentsOf: data); written = next.partialValue; progress(written) }
        catch { fail(error); dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = failure as? DownloadResponseError, failure.discardsPartial { try? file.truncate(atOffset: 0) }
        try? file.synchronize(); try? file.close()
        lock.lock(); let callback = continuation; continuation = nil; let wasCancelled = cancelled; self.task = nil; lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure { callback?.resume(throwing: failure) }
        else if wasCancelled { callback?.resume(throwing: CancellationError()) }
        else if let error { callback?.resume(throwing: error) }
        else if written != expectedBytes { callback?.resume(throwing: DownloadResponseError.endedEarly(saved: written, expected: expectedBytes)) }
        else { callback?.resume() }
    }

    private func fail(_ error: Error) { if failure == nil { failure = error } }
}

/// Saved partial downloads, keyed only by the pinned SHA-256 and byte size. Lives under the library root in `.partial`.
struct PartialDownloadStore: Sendable {
    let directory: URL
    /// Untouched partials older than this are pruned at the start of an install, bounding abandoned growth.
    static let retention: TimeInterval = 14 * 24 * 3600

    init(root: URL) { directory = root.appending(path: ".partial", directoryHint: .isDirectory) }

    static func fileName(sha256: String, byteSize: Int64) -> String? {
        let hash = sha256.lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }), byteSize > 0 else { return nil }
        return "\(hash)-\(byteSize).part"
    }
    static func isPartialName(_ name: String) -> Bool {
        guard name.hasSuffix(".part") else { return false }
        let parts = name.dropLast(5).split(separator: "-")
        guard parts.count == 2, let bytes = Int64(parts[1]) else { return false }
        return fileName(sha256: String(parts[0]), byteSize: bytes) == name
    }

    /// Creates the directory and refuses a redirected (symlinked) location.
    func preparedDirectory(root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateLocation(root: root)
        return directory
    }
    func validateLocation(root: URL) throws {
        let expected = root.standardizedFileURL.resolvingSymlinksInPath().appending(path: ".partial").path
        guard directory.standardizedFileURL.resolvingSymlinksInPath().path == expected else {
            throw GenerationLibraryError.invalid("Refusing to use a redirected partial-download directory.")
        }
    }
    func url(for component: ModelComponent) -> URL? {
        Self.fileName(sha256: component.sha256, byteSize: component.byteSize).map { directory.appending(path: $0) }
    }
    /// Saved bytes for a component, without following symlinks. Zero when absent or not a regular file.
    func savedBytes(for component: ModelComponent) -> Int64 {
        guard let url = url(for: component), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { return 0 }
        return min(Int64(size), component.byteSize)
    }
    func entries() -> [(url: URL, bytes: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return items.compactMap { item in
            guard Self.isPartialName(item.lastPathComponent), let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (item, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}

/// Exclusive advisory lock on a partial file, so two GenStudio processes never write the same download.
final class PartialDownloadLock: Sendable {
    private let descriptor: Int32

    init(_ url: URL) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GenerationLibraryError.invalid("Cannot open the partial download file.") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); throw GenerationLibraryError.invalid("The partial download is not a regular file.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw GenerationLibraryError.invalid("Another GenStudio window is already downloading this file. Wait for it to finish.")
        }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
