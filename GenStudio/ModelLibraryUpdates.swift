import Foundation
import CryptoKit

struct ModelUpdateCheck: Sendable {
    let installedID: String
    let candidate: ModelRecipe?
    let changedComponentIDs: [String]
    let message: String
}

struct ModelRepositoryRevision: Sendable {
    struct File: Sendable {
        let filename: String
        let byteSize: Int64
        let sha256: String?
    }
    let revision: String
    let files: [File]
    let license: String?
}

protocol ModelUpdateMetadataProvider: Sendable {
    func head(repository: String) async throws -> ModelRepositoryRevision
    /// LFS model files include a publisher SHA-256 in Hub metadata. Small Git
    /// metadata files do not, so an update check may fetch and hash only those
    /// bounded files when their repository revision actually changed.
    func checksum(repository: String, revision: String, filename: String, expectedBytes: Int64) async throws -> String?
}

extension ModelUpdateMetadataProvider {
    func checksum(repository: String, revision: String, filename: String, expectedBytes: Int64) async throws -> String? { nil }
}

struct HubUpdateMetadataProvider: ModelUpdateMetadataProvider {
    func head(repository: String) async throws -> ModelRepositoryRevision {
        guard try ModelLibrary.parseHubLink(repository) == repository else { throw GenerationLibraryError.invalid("Invalid model repository.") }
        var url = URLComponents(string: "https://huggingface.co/api/models/\(repository)")!
        url.queryItems = [.init(name: "blobs", value: "true")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw GenerationLibraryError.invalid("Cannot check this repository for updates. It may be offline, private or require Hugging Face access. Your installed version is unchanged.") }
        struct Response: Decodable {
            struct File: Decodable {
                struct LFS: Decodable { let sha256: String; let size: Int64 }
                let rfilename: String; let size: Int64?; let lfs: LFS?
            }
            struct Card: Decodable { let license: String? }
            let sha: String; let siblings: [File]; let cardData: Card?
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        return .init(revision: result.sha, files: result.siblings.map { .init(filename: $0.rfilename, byteSize: $0.lfs?.size ?? $0.size ?? 0, sha256: $0.lfs?.sha256) }, license: result.cardData?.license)
    }

    func checksum(repository: String, revision: String, filename: String, expectedBytes: Int64) async throws -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let path = filename.split(separator: "/", omittingEmptySubsequences: false)
        guard try ModelLibrary.parseHubLink(repository) == repository,
              revision.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil,
              expectedBytes > 0, expectedBytes <= 32 * 1024 * 1024,
              !path.isEmpty,
              path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return nil
        }
        let encoded = path.map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }.joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(encoded)") else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, Int64(data.count) == expectedBytes else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelLibrary {
    /// Metadata only. Admission permits installation, not inference or automatic node replacement.
    func checkForUpdate(id: String) async throws -> ModelUpdateCheck {
        let original = try installedRecipe(id: id)
        var revisions: [String: ModelRepositoryRevision] = [:]
        for repository in Set(original.components.map(\.repository)).sorted() {
            try Task.checkCancellation()
            revisions[repository] = try await updateMetadata.head(repository: repository)
        }
        var components: [ModelComponent] = []
        var changed: [String] = []
        for old in original.components {
            guard let head = revisions[old.repository], Self.hex(head.revision, count: 40) else {
                throw GenerationLibraryError.invalid("The update repository did not provide a valid immutable revision. The existing version is unchanged.")
            }
            // Hugging Face supplies LFS SHA-256 values for model weights, but
            // not necessarily for ordinary Git metadata such as config JSON.
            // If the immutable revision is unchanged, preserve the frozen
            // component rather than rejecting an otherwise current model.
            guard head.revision.caseInsensitiveCompare(old.revision) != .orderedSame else {
                components.append(old)
                continue
            }
            let remoteFilename = old.sourceFilename ?? old.filename
            guard head.files.filter({ $0.filename == remoteFilename }).count == 1,
                  let file = head.files.first(where: { $0.filename == remoteFilename }), file.byteSize > 0 else {
                throw GenerationLibraryError.invalid("The update does not provide the exact component filename, size and SHA-256 needed for a verified installation. The existing version is unchanged.")
            }
            let digest: String?
            if let publisherDigest = file.sha256 {
                digest = publisherDigest
            } else {
                digest = try await updateMetadata.checksum(repository: old.repository, revision: head.revision, filename: remoteFilename, expectedBytes: file.byteSize)
            }
            guard let digest, Self.hex(digest, count: 64) else {
                throw GenerationLibraryError.invalid("The update does not provide the exact component filename, size and SHA-256 needed for a verified installation. The existing version is unchanged.")
            }
            let license = head.license ?? old.license
            if file.byteSize != old.byteSize || digest.lowercased() != old.sha256.lowercased() || Self.licenseIdentity(license) != Self.licenseIdentity(old.license) { changed.append(old.id) }
            components.append(.init(id: old.id, role: old.role, repository: old.repository, revision: head.revision.lowercased(), filename: old.filename, byteSize: file.byteSize, sha256: digest.lowercased(), license: license, sourceFilename: old.sourceFilename, sourceURL: old.sourceURL))
        }
        guard !changed.isEmpty else { return .init(installedID: id, candidate: nil, changedComponentIDs: [], message: "The selected component files are unchanged at the repository’s current revision. Your installed version remains pinned.") }
        let base = original.baseRecipeID ?? original.id
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Full component provenance creates stable, distinct IDs even for multi-repository recipes.
        let digest = SHA256.hash(data: try encoder.encode(components)).map { String(format: "%02x", $0) }.joined()
        let candidate = ModelRecipe(id: base + "-v-" + digest, name: original.name, kind: original.kind, engineID: original.engineID, components: components, runtimeReady: false, minimumMemoryBytes: original.minimumMemoryBytes, baseRecipeID: base, runtimeProfile: original.runtimeProfile, provider: original.provider, sourceURL: original.sourceURL, supportedImageTasks: original.supportedImageTasks, workflowCapabilities: original.workflowCapabilities)
        // Recheck after asynchronous metadata lookup: removal must not admit a dangling update.
        guard try installedRecipe(id: id) == original else { throw GenerationLibraryError.invalid("The installed model changed during this check. Check again.") }
        admittedUpdates[candidate.id] = candidate
        return .init(installedID: id, candidate: candidate, changedComponentIDs: changed, message: "New component revision available. Runtime compatibility is unverified; installation keeps the old version and does not change workflow selections.")
    }
    private static func licenseIdentity(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
    private static func hex(_ text: String, count: Int) -> Bool { text.count == count && text.allSatisfy(\.isHexDigit) }
}
