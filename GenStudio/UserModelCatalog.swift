import Foundation
import CryptoKit

/// Runtime contracts that can be selected by a user-created manifest. A
/// contract describes how an already-downloaded file is passed to a bundled
/// engine; it does not execute publisher code or install Python dependencies.
enum UserModelRuntimeProfile: String, Codable, CaseIterable, Sendable {
    case stableDiffusionCheckpoint = "sd-checkpoint"

    var title: String { "Stable Diffusion checkpoint (stable-diffusion.cpp)" }
    var explanation: String { "Single .safetensors or .ckpt checkpoint. Supports text-to-image and whole-image image-to-image." }
}

struct UserModelManifest: Codable, Sendable {
    var name: String
    var provider: String
    var modelVersionID: Int?
    var downloadURL: URL
    var filename: String
    var sha256: String
    var byteSize: Int64
    var license: String
    var baseModel: String?
    var runtimeProfile: UserModelRuntimeProfile
    var tasks: [ImageTask]
}

struct ModelScoutResult: Identifiable, Sendable {
    private let stableID = UUID()
    let source: String
    let idText: String
    let summary: String
    let description: String?
    let versionID: Int?
    let isAdultContent: Bool
    let installable: Bool
    let reason: String
    let recipe: ModelRecipe?
    var id: UUID { stableID }
    init(source: String, id: String, summary: String, installable: Bool, reason: String, recipe: ModelRecipe?, versionID: Int? = nil, description: String? = nil, isAdultContent: Bool = false) {
        self.source = source; self.idText = id; self.summary = summary; self.installable = installable; self.reason = reason; self.recipe = recipe; self.versionID = versionID; self.description = description; self.isAdultContent = isAdultContent
    }
}

/// User-owned recipes are persisted separately from the shipped catalog. This
/// makes app updates safe: a new release can add curated recipes without
/// overwriting models the user discovered themselves.
enum UserModelCatalog {
    static func load(root: URL? = nil) -> [ModelRecipe] {
        let url = fileURL(root: root)
        guard let data = try? Data(contentsOf: url), let recipes = try? JSONDecoder().decode([ModelRecipe].self, from: data) else { return [] }
        return recipes.filter(isSupported)
    }

    static func save(_ recipe: ModelRecipe, root: URL? = nil) throws {
        guard isSupported(recipe) else { throw GenerationLibraryError.invalid("This manifest uses a runtime profile GenStudio does not support yet.") }
        let url = fileURL(root: root)
        var recipes = load(root: root).filter { $0.id != recipe.id }
        recipes.append(recipe)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recipes).write(to: url, options: .atomic)
    }

    static func recipe(from manifest: UserModelManifest) throws -> ModelRecipe {
        guard manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              manifest.byteSize > 0, manifest.sha256.count == 64, manifest.sha256.allSatisfy(\.isHexDigit),
              manifest.filename.hasSuffix(".safetensors") || manifest.filename.hasSuffix(".ckpt") else {
            throw GenerationLibraryError.invalid("The manifest needs a model name, file size, SHA-256 and a .safetensors or .ckpt file.")
        }
        let seed = "\(manifest.provider):\(manifest.modelVersionID.map(String.init) ?? manifest.downloadURL.absoluteString):\(manifest.sha256)"
        let id = "user-image-" + SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let revision = SHA256.hash(data: Data((seed + ":revision").utf8)).map { String(format: "%02x", $0) }.joined()
        let component = ModelComponent(id: "checkpoint", role: "checkpoint", repository: "user/\(id)", revision: String(revision.prefix(40)), filename: manifest.filename, byteSize: manifest.byteSize, sha256: manifest.sha256.lowercased(), license: manifest.license, sourceURL: manifest.downloadURL)
        return ModelRecipe(id: String(id), name: manifest.name, kind: .image, engineID: "stable-diffusion.cpp", components: [component], runtimeReady: false, minimumMemoryBytes: UInt64(max(4 * 1024 * 1024 * 1024, manifest.byteSize)).addingReportingOverflow(2 * 1024 * 1024 * 1024).partialValue, runtimeProfile: manifest.runtimeProfile.rawValue, provider: manifest.provider, sourceURL: manifest.downloadURL, supportedImageTasks: manifest.tasks)
    }

    static func manifestData(from recipe: ModelRecipe) throws -> Data {
        guard isSupported(recipe), let component = recipe.components.first, let url = component.sourceURL else { throw GenerationLibraryError.invalid("Only imported user image recipes can be exported as manifests.") }
        let manifest = UserModelManifest(name: recipe.name, provider: recipe.provider ?? "local", modelVersionID: nil, downloadURL: url, filename: component.filename, sha256: component.sha256, byteSize: component.byteSize, license: component.license, baseModel: nil, runtimeProfile: UserModelRuntimeProfile(rawValue: recipe.runtimeProfile ?? "") ?? .stableDiffusionCheckpoint, tasks: recipe.supportedImageTasks ?? [.textToImage, .imageToImage])
        return try JSONEncoder().encode(manifest)
    }

    static func isSupported(_ recipe: ModelRecipe) -> Bool {
        recipe.kind == .image && recipe.engineID == "stable-diffusion.cpp" && recipe.runtimeProfile == UserModelRuntimeProfile.stableDiffusionCheckpoint.rawValue && recipe.components.count == 1 && recipe.components[0].role == "checkpoint" && recipe.components[0].sourceURL != nil
    }

    private static func fileURL(root: URL?) -> URL {
        (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "GenStudio/ModelLibrary"))
            .appending(path: "user-recipes.json")
    }
}

enum CivitaiModelService {
    static func versionID(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(trimmed) { return id }
        guard let url = URL(string: trimmed), url.host?.contains("civitai.com") == true else { return nil }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "model-versions"), parts.indices.contains(index + 1) { return Int(parts[index + 1]) }
        if let last = parts.last, let id = Int(last) { return id }
        return nil
    }

    static func fetchManifest(versionID: Int) async throws -> UserModelManifest {
        let url = URL(string: "https://civitai.com/api/v1/model-versions/\(versionID)")!
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw GenerationLibraryError.invalid("Civitai model metadata could not be loaded (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              let files = object["files"] as? [[String: Any]],
              let file = files.first(where: { ($0["primary"] as? Bool) == true }) ?? files.first,
              let download = file["downloadUrl"] as? String, let downloadURL = URL(string: download),
              let filename = file["name"] as? String, let sizeKB = file["sizeKB"] as? NSNumber,
              let hashes = file["hashes"] as? [String: Any], let hash = (hashes["SHA256"] as? String)?.lowercased(), hash.count == 64 else {
            throw GenerationLibraryError.invalid("Civitai returned no primary checkpoint with a download URL, size and SHA-256.")
        }
        let base = object["baseModel"] as? String
        return UserModelManifest(name: "\(name) · Civitai \(versionID)", provider: "civitai", modelVersionID: versionID, downloadURL: downloadURL, filename: filename, sha256: hash, byteSize: Int64((sizeKB.doubleValue * 1024).rounded()), license: "Read the Civitai model page", baseModel: base, runtimeProfile: .stableDiffusionCheckpoint, tasks: [.textToImage, .imageToImage])
    }

    static func search(query: String, limit: Int) async throws -> [ModelScoutResult] {
        var components = URLComponents(string: "https://civitai.com/api/v1/models")!
        components.queryItems = [.init(name: "query", value: String(query.prefix(160))), .init(name: "types", value: "Checkpoint"), .init(name: "limit", value: String(min(20, max(1, limit)))), .init(name: "sort", value: "Most Downloaded")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item["name"] as? String, let versions = item["modelVersions"] as? [[String: Any]], let version = versions.first, let id = version["id"] as? NSNumber else { return nil }
            let description = ((item["description"] as? String) ?? (version["description"] as? String)).map { $0.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            let adult = (item["nsfw"] as? Bool) == true || (item["nsfwLevel"] as? String)?.localizedCaseInsensitiveContains("nsfw") == true
            return ModelScoutResult(source: "Civitai", id: "\(name) · version \(id.intValue)", summary: "Checkpoint · \(version["baseModel"] as? String ?? "base model not specified")", installable: false, reason: "Fetch the version metadata to verify a primary file, checksum and local runtime profile.", recipe: nil, versionID: id.intValue, description: description, isAdultContent: adult)
        }
    }
}
