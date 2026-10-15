import Foundation

public actor URLSessionHFHTTPClient: HFHTTPClient {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Self.validate(request.url)
        let delegate = RestrictedDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelLibraryError.invalidResponse }
        try Self.validate(http.url)
        return (data, http)
    }

    public func download(for request: URLRequest, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> HTTPURLResponse {
        try Self.validate(request.url)
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            defer { session.finishTasksAndInvalidate() }
            return try await delegate.start(task: task)
        } onCancel: {
            task.cancel()
        }
    }

    fileprivate static func validate(_ url: URL?) throws {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            throw ModelLibraryError.invalidResponse
        }
        let allowed = host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co") || host.hasSuffix(".xethub.hf.co")
        guard allowed else { throw ModelLibraryError.invalidResponse }
    }
}

private class RestrictedDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do { try URLSessionHFHTTPClient.validate(request.url); completionHandler(request) }
        catch { completionHandler(nil) }
    }
}

private final class DownloadDelegate: RestrictedDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: HTTPURLResponse?
    private var moveError: Error?

    init(destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.destination = destination; self.progress = progress
    }

    func start(task: URLSessionDownloadTask) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(DownloadProgress(receivedBytes: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            response = downloadTask.response as? HTTPURLResponse
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<HTTPURLResponse, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error {
            if (error as? URLError)?.code == .cancelled { continuation?.resume(throwing: ModelLibraryError.cancelled) }
            else { continuation?.resume(throwing: error) }
        } else if let moveError { continuation?.resume(throwing: moveError) }
        else if let response { continuation?.resume(returning: response) }
        else { continuation?.resume(throwing: ModelLibraryError.invalidResponse) }
    }
}
