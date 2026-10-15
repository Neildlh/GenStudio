import Foundation

public enum ModelLibraryError: Error, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case invalidRepository
    case invalidRevision
    case unsafeFileName
    case unsupportedFile(String)
    case unsupportedGGUFVersion(UInt32)
    case invalidGGUF(String)
    case lengthMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case insufficientDisk(required: Int64, available: Int64)
    case registryCorrupt
    case registrySchemaTooNew(Int)
    case modelNotFound
    case sourceMissing
    case cancelled
}

public struct HFRepository: Codable, Hashable, Sendable {
    public let id: String
    public let revision: String
    public let gated: Bool
    public let license: String?
    public init(id: String, revision: String, gated: Bool, license: String?) {
        self.id = id; self.revision = revision; self.gated = gated; self.license = license
    }
}

public struct HFGGUFFile: Codable, Hashable, Sendable {
    public let repository: HFRepository
    public let name: String
    public let size: Int64
    public let sha256: String?
    public init(repository: HFRepository, name: String, size: Int64, sha256: String?) {
        self.repository = repository; self.name = name; self.size = size; self.sha256 = sha256
    }
}

public enum ModelOwnership: String, Codable, Sendable { case managed, external }
public enum InferenceVerification: String, Codable, Sendable { case unverified, verified }
public enum ModelAvailability: String, Codable, Sendable { case available, missing }

public struct RegisteredModel: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let filePath: String
    public let ownership: ModelOwnership
    public let architecture: String
    public let ggufVersion: UInt32
    public let byteSize: Int64
    public let sha256: String
    public let sourceRepository: String?
    public let sourceRevision: String?
    public let registeredAt: Date
    public var inferenceVerification: InferenceVerification
    public var availability: ModelAvailability

    public var fileURL: URL { URL(fileURLWithPath: filePath) }
}

public struct DownloadProgress: Sendable, Equatable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64
    public var fraction: Double { expectedBytes > 0 ? Double(receivedBytes) / Double(expectedBytes) : 0 }
    public init(receivedBytes: Int64, expectedBytes: Int64) {
        self.receivedBytes = receivedBytes; self.expectedBytes = expectedBytes
    }
}

public protocol HFHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest, to destination: URL, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> HTTPURLResponse
}
