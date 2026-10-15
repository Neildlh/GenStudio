import CryptoKit
import Foundation

public actor ModelLibrary {
    public static let registrySchemaVersion = 1

    private let root: URL
    private let registryURL: URL
    private let http: any HFHTTPClient
    private var records: [RegisteredModel]

    public init(root: URL, httpClient: any HFHTTPClient = URLSessionHFHTTPClient()) throws {
        self.root = root.standardizedFileURL
        self.registryURL = root.appending(path: "registry.json")
        self.http = httpClient
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.records = try Self.loadRegistry(at: registryURL)
    }

    public func searchRepositories(query: String, limit: Int = 20) async throws -> [HFRepository] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "full", value: "true")
        ]
        let (data, response) = try await http.data(for: URLRequest(url: components.url!))
        try Self.requireSuccess(response)
        do {
            return try JSONDecoder().decode([SearchDTO].self, from: data).compactMap { dto in
                guard let sha = dto.sha, Self.validRevision(sha), Self.validRepository(dto.id) else { return nil }
                let license = dto.cardData?.license ?? dto.tags?.first(where: { $0.hasPrefix("license:") }).map { String($0.dropFirst(8)) }
                return HFRepository(id: dto.id, revision: sha, gated: dto.gated?.value ?? false, license: license)
            }
        } catch { throw ModelLibraryError.invalidResponse }
    }

    public func listGGUFFiles(repositoryID: String, revision: String) async throws -> [HFGGUFFile] {
        guard Self.validRepository(repositoryID) else { throw ModelLibraryError.invalidRepository }
        guard Self.validRevision(revision) else { throw ModelLibraryError.invalidRevision }
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repositoryID)")!
        components.queryItems = [URLQueryItem(name: "revision", value: revision), URLQueryItem(name: "blobs", value: "true")]
        let (data, response) = try await http.data(for: URLRequest(url: components.url!))
        try Self.requireSuccess(response)
        let dto: DetailDTO
        do { dto = try JSONDecoder().decode(DetailDTO.self, from: data) } catch { throw ModelLibraryError.invalidResponse }
        guard dto.sha == revision else { throw ModelLibraryError.invalidResponse }
        let repo = HFRepository(id: dto.id, revision: revision, gated: dto.gated?.value ?? false, license: dto.cardData?.license ?? dto.tags?.first(where: { $0.hasPrefix("license:") }).map { String($0.dropFirst(8)) })
        return dto.siblings.compactMap { file in
            guard Self.safeGGUFName(file.rfilename), let size = file.lfs?.size ?? file.size else { return nil }
            return HFGGUFFile(repository: repo, name: file.rfilename, size: size, sha256: file.lfs?.sha256)
        }
    }

    public func download(_ file: HFGGUFFile, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> RegisteredModel {
        guard Self.validRepository(file.repository.id) else { throw ModelLibraryError.invalidRepository }
        guard Self.validRevision(file.repository.revision) else { throw ModelLibraryError.invalidRevision }
        guard Self.safeGGUFName(file.name) else { throw ModelLibraryError.unsafeFileName }
        guard !file.repository.gated else { throw ModelLibraryError.unsupportedFile("gated models require access credentials") }
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let required = file.size + max(64 * 1_024 * 1_024, file.size / 20)
        guard available >= required else { throw ModelLibraryError.insufficientDisk(required: required, available: available) }

        let staging = root.appending(path: ".staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appending(path: UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: staged) }
        let encodedName = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://huggingface.co/\(file.repository.id)/resolve/\(file.repository.revision)/\(encodedName)") else { throw ModelLibraryError.invalidResponse }
        let response = try await http.download(for: URLRequest(url: url), to: staged, progress: progress)
        try Self.requireSuccess(response)
        try Task.checkCancellation()
        let actualSize = try Self.fileSize(staged)
        guard actualSize == file.size else { throw ModelLibraryError.lengthMismatch(expected: file.size, actual: actualSize) }
        let digest = try await Self.sha256(staged)
        if let expected = file.sha256?.lowercased(), digest != expected { throw ModelLibraryError.checksumMismatch(expected: expected, actual: digest) }
        let metadata = try GGUFParser.parse(url: staged)
        return try install(staged: staged, name: file.name, metadata: metadata, size: actualSize, digest: digest, repository: file.repository)
    }

    public func importGGUF(from source: URL, copyIntoLibrary: Bool) async throws -> RegisteredModel {
        let source = source.standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { throw ModelLibraryError.sourceMissing }
        guard Self.safeGGUFName(source.lastPathComponent) else { throw ModelLibraryError.unsafeFileName }
        let metadata = try GGUFParser.parse(url: source)
        let size = try Self.fileSize(source)
        let digest = try await Self.sha256(source)
        if copyIntoLibrary {
            let staging = root.appending(path: ".staging", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let staged = staging.appending(path: UUID().uuidString + ".part")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: source, to: staged)
            return try install(staged: staged, name: source.lastPathComponent, metadata: metadata, size: size, digest: digest, repository: nil)
        }
        var model = Self.makeRecord(path: source, ownership: .external, name: source.lastPathComponent, metadata: metadata, size: size, digest: digest, repository: nil)
        records.append(model)
        try persist()
        model.availability = .available
        return model
    }

    public func models() -> [RegisteredModel] {
        records.map { record in
            var current = record
            current.availability = FileManager.default.fileExists(atPath: record.filePath) ? .available : .missing
            return current
        }
    }

    public func markInferenceVerified(id: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw ModelLibraryError.modelNotFound }
        guard FileManager.default.fileExists(atPath: records[index].filePath) else { throw ModelLibraryError.sourceMissing }
        records[index].inferenceVerification = .verified
        try persist()
    }

    public func unregister(id: UUID) throws {
        guard records.contains(where: { $0.id == id }) else { throw ModelLibraryError.modelNotFound }
        records.removeAll { $0.id == id }
        try persist()
    }

    private func install(staged: URL, name: String, metadata: GGUFMetadata, size: Int64, digest: String, repository: HFRepository?) throws -> RegisteredModel {
        let directory = root.appending(path: "Models/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: name)
        do { try FileManager.default.moveItem(at: staged, to: destination) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        let model = Self.makeRecord(path: destination, ownership: .managed, name: name, metadata: metadata, size: size, digest: digest, repository: repository)
        records.append(model)
        do { try persist() }
        catch { records.removeAll { $0.id == model.id }; try? FileManager.default.removeItem(at: directory); throw error }
        return model
    }

    private static func makeRecord(path: URL, ownership: ModelOwnership, name: String, metadata: GGUFMetadata, size: Int64, digest: String, repository: HFRepository?) -> RegisteredModel {
        RegisteredModel(id: UUID(), displayName: name, filePath: path.path, ownership: ownership, architecture: metadata.architecture, ggufVersion: metadata.version, byteSize: size, sha256: digest, sourceRepository: repository?.id, sourceRevision: repository?.revision, registeredAt: Date(), inferenceVerification: .unverified, availability: .available)
    }

    private func persist() throws {
        let registry = Registry(schemaVersion: Self.registrySchemaVersion, models: records)
        let data = try JSONEncoder.registry.encode(registry)
        try data.write(to: registryURL, options: .atomic)
    }

    private static func loadRegistry(at url: URL) throws -> [RegisteredModel] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let header: RegistryHeader
        do { header = try JSONDecoder().decode(RegistryHeader.self, from: data) } catch { throw ModelLibraryError.registryCorrupt }
        guard header.schemaVersion <= registrySchemaVersion else { throw ModelLibraryError.registrySchemaTooNew(header.schemaVersion) }
        do { return try JSONDecoder.registry.decode(Registry.self, from: data).models } catch { throw ModelLibraryError.registryCorrupt }
    }

    private static func sha256(_ url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let value = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }

    private static func requireSuccess(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw ModelLibraryError.httpStatus(response.statusCode) }
    }

    private static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }
    }

    private static func validRevision(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit }
    }

    private static func safeGGUFName(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("/"), value.lowercased().hasSuffix(".gguf") else { return false }
        let lower = value.lowercased()
        guard !lower.contains("mmproj"), !lower.contains("projector") else { return false }
        let splitPattern = try! NSRegularExpression(pattern: "-\\d{5}-of-\\d{5}\\.gguf$")
        return splitPattern.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) == nil
    }
}

private struct Registry: Codable { let schemaVersion: Int; let models: [RegisteredModel] }
private struct RegistryHeader: Decodable { let schemaVersion: Int }

private struct SearchDTO: Decodable {
    let id: String; let sha: String?; let gated: FlexibleBool?; let tags: [String]?; let cardData: CardData?
}
private struct DetailDTO: Decodable {
    let id: String; let sha: String; let gated: FlexibleBool?; let tags: [String]?; let cardData: CardData?; let siblings: [Sibling]
}
private struct CardData: Decodable { let license: String? }
private struct Sibling: Decodable { let rfilename: String; let size: Int64?; let lfs: LFS? }
private struct LFS: Decodable { let sha256: String?; let size: Int64? }
private enum FlexibleBool: Decodable {
    case bool(Bool); case string(String)
    var value: Bool { if case .bool(let value) = self { return value }; return true }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .string(try container.decode(String.self)) }
    }
}

private extension JSONEncoder {
    static var registry: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; value.dateEncodingStrategy = .iso8601; return value }
}
private extension JSONDecoder {
    static var registry: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
