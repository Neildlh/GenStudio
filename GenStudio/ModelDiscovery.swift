import Foundation
import CryptoKit
import CoreFoundation

// API contract: huggingface_hub/hf_api.py list_models/model_info; no repository code is executed.
enum DiscoveryTask: String, Codable, CaseIterable, Sendable {
    case all = "", text = "text-generation", vision = "image-text-to-text"
    case image = "text-to-image", imageEditing = "image-to-image", video = "text-to-video"
    case imageToVideo = "image-to-video", audio = "text-to-audio"
    case speech = "text-to-speech", transcription = "automatic-speech-recognition"
    case textAnalysis = "text-classification", textExtraction = "token-classification"
    case questionAnswering = "question-answering", similarity = "sentence-similarity"
    case summarization = "summarization", translation = "translation"
    case imageCaptioning = "image-to-text", visualQuestions = "visual-question-answering"
    case documents = "document-question-answering", audioAnalysis = "audio-classification"
    case audioEditing = "audio-to-audio"
}
enum DiscoverySort: String, Codable, CaseIterable, Sendable {
    case latest = "createdAt", downloads = "downloads", trending = "trendingScore"
}
enum DiscoveryAudienceFilter: String, Codable, CaseIterable, Sendable {
    case all, general, adult

    var title: String {
        switch self {
        case .all: "All content"
        case .general: "General"
        case .adult: "NSFW / adult"
        }
    }
}
struct DiscoveryModel: Codable, Sendable, Identifiable {
    let id: String
    let sha: String?
    let pipelineTag: String?
    let library: String?
    let license: String?
    let gated: Bool
    let downloads: Int?
    let likes: Int?
    let createdAt: String?
    let lastModified: String?
    let tags: [String]
    var publisherDescription: String? = nil
    /// Publisher card `base_model` values. Optional so previously cached pages still decode.
    var baseModels: [String]? = nil
    /// Publisher card `instance_prompt` values (LoRA trigger phrases); display-only help text.
    var instancePrompts: [String]? = nil
    var purposes: [ModelPurpose] { ModelPurpose.declared(pipelineTag: pipelineTag, tags: tags) }
    /// Hugging Face publishers can explicitly mark mature repositories. Do not infer this
    /// classification from a model's name or prose: a missing tag is not a safety guarantee.
    var isAdultContent: Bool {
        let markers: Set<String> = [
            "not-for-all-audiences", "nsfw", "adult", "nudity", "explicit",
            "sexual-content", "content-rating:adult", "content_rating:adult"
        ]
        return tags.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { markers.contains($0) }
    }
    var taskSummary: String {
        purposes.map { purpose in
            if purpose == .textWriting && pipelineTag == "summarization" {
                return "Condenses longer text into a shorter summary."
            }
            return purpose.summary
        }.joined(separator: " ")
    }
}
struct DiscoveryFile: Codable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let bytes: Int64?
    let sha256: String?
    var format: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
}
struct DiscoveryPage: Codable, Sendable {
    let models: [DiscoveryModel]
    let nextCursor: String?
    let fetchedAt: Date
    var isCached: Bool
}
struct DiscoveryDetail: Codable, Sendable {
    let model: DiscoveryModel
    let files: [DiscoveryFile]
    let architectures: [String]
    let modelType: String?
    let contextLength: Int?
    let requiresCustomCode: Bool
    let configNote: String?
    let ggufArchitectureHint: String?
    /// Candidates require local GGUF header, architecture and template validation before import.
    var experimentalTextFiles: [DiscoveryFile] {
        guard model.pipelineTag == "text-generation", !requiresCustomCode else { return [] }
        // A LoRA or other adapter GGUF modifies a base model; it is never offered as a standalone text model.
        guard ![ModelPackageClassification.Kind.lora, .adapter].contains(ModelPackageClassification.classify(model: model, files: files).kind) else { return [] }
        if let hint = ggufArchitectureHint, !GGUFTextInspector.architectures.contains(hint) { return [] }
        return files.filter { $0.format == "gguf" && ($0.bytes ?? 0) > 0 && $0.sha256?.count == 64 && !$0.path.lowercased().contains("mmproj") && !$0.path.contains("-of-") }
    }
    /// A runnable MLX VLM is a package, never an individual safetensors shard.
    /// Keep this conservative: root-level metadata plus every model shard, all
    /// with Hub-provided size and SHA-256, and no custom remote code.
    var mlxVLMFiles: [DiscoveryFile] {
        guard !model.gated, !requiresCustomCode,
              files.contains(where: { $0.path == "config.json" }),
              files.contains(where: { $0.path.hasSuffix(".safetensors") }) else { return [] }
        let allowedMetadata: Set<String> = ["config.json", "generation_config.json", "preprocessor_config.json", "processor_config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "chat_template.json", "chat_template.jinja", "model.safetensors.index.json"]
        let chosen = files.filter { allowedMetadata.contains($0.path) || ($0.path.hasPrefix("model") && $0.path.hasSuffix(".safetensors")) }
        guard chosen.contains(where: { $0.path == "config.json" }),
              chosen.contains(where: { $0.path.hasSuffix(".safetensors") }),
              chosen.allSatisfy({ ($0.bytes ?? 0) > 0 }) else { return [] }
        return chosen.sorted { $0.path < $1.path }
    }
    let fetchedAt: Date
    var isCached: Bool
    var publisherExcerpt: String? = nil
    var formats: [String] { Array(Set(files.map(\.format).filter { !$0.isEmpty })).sorted() }
    /// Repository inventory may contain alternative quantizations; this is NOT an install plan or RAM requirement.
    var knownRepositoryBytes: Int64 { files.reduce(0) { value, file in
        let sum = value.addingReportingOverflow(max(0, file.bytes ?? 0)); return sum.overflow ? Int64.max : sum.partialValue
    } }
    var inventorySizeComplete: Bool { !files.isEmpty && files.allSatisfy { $0.bytes != nil } }
}
struct DiscoveryAssessment: Sendable {
    enum Guidance: String, Sendable { case recommended, demanding, incompatible, unknown }
    let hardware: Guidance
    let runtimeSupported: Bool
    let exactRecipeIDs: [String]
    let explanation: String
    let storageExplanation: String
}
struct DiscoveryResponse: Sendable { let data: Data; let nextLink: String? }
protocol DiscoveryTransport: Sendable {
    func fetch(_ url: URL) async throws -> DiscoveryResponse
    func fetch(_ url: URL, maximumBytes: Int) async throws -> DiscoveryResponse
}
extension DiscoveryTransport {
    func fetch(_ url: URL, maximumBytes: Int) async throws -> DiscoveryResponse {
        let response = try await fetch(url)
        guard response.data.count <= maximumBytes else { throw GenerationLibraryError.invalid("Model card exceeds the size limit.") }
        return response
    }
}
struct HubDiscoveryTransport: DiscoveryTransport {
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        try await fetch(url, maximumBytes: 12 * 1024 * 1024)
    }
    func fetch(_ url: URL, maximumBytes: Int) async throws -> DiscoveryResponse {
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue(url.path.hasSuffix(".md") ? "text/plain" : "application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GenerationLibraryError.hub(status: (response as? HTTPURLResponse)?.statusCode ?? 0, action: "The Hugging Face request")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < maximumBytes else { throw GenerationLibraryError.invalid("Model metadata exceeds the size limit.") }
            data.append(byte)
        }
        return .init(data: data, nextLink: http.value(forHTTPHeaderField: "Link"))
    }
}
actor ModelDiscovery {
    private let root: URL
    private let transport: any DiscoveryTransport
    private var activeSizeRequests = 0
    private var sizeWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    private struct CachedSize: Codable { let summary: ModelSizeSummary; let fetchedAt: Date }
    init(cacheRoot: URL? = nil, transport: any DiscoveryTransport = HubDiscoveryTransport()) {
        root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GenStudio/Discovery")
        self.transport = transport
    }
    /// One bounded metadata request for a visible search result. No model card, config or weights are fetched.
    func modelSize(repository: String, revision: String?) async throws -> ModelSizeSummary {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw GenerationLibraryError.invalid("Invalid Hugging Face model identifier.")
        }
        if let revision, revision.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) == nil {
            throw GenerationLibraryError.invalid("Model size requires an immutable revision.")
        }
        let suffix = revision.map { "/revision/\($0)" } ?? ""
        let url = URL(string: "https://huggingface.co/api/models/\(repository)\(suffix)?blobs=true")!
        let key = "model-size-v2:" + url.absoluteString
        if let saved: CachedSize = try? cached(key), revision != nil || Date().timeIntervalSince(saved.fetchedAt) < 6 * 60 * 60 {
            return saved.summary
        }
        try await acquireSizeRequest()
        defer { releaseSizeRequest() }
        try Task.checkCancellation()
        // Another visible row may have completed the same lookup while this request was queued.
        if let saved: CachedSize = try? cached(key), revision != nil || Date().timeIntervalSince(saved.fetchedAt) < 6 * 60 * 60 {
            return saved.summary
        }
        let response = try await transport.fetch(url, maximumBytes: 4 * 1024 * 1024)
        try Task.checkCancellation()
        guard let row = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let model = Self.model(row), model.id == repository,
              revision == nil || model.sha == revision,
              let siblings = row["siblings"] as? [[String: Any]] else {
            throw GenerationLibraryError.invalid("Model file metadata did not match the requested revision.")
        }
        let files = siblings.compactMap(Self.file)
        let summary = ModelSizeSummary.summarize(repository: repository, revision: model.sha, files: files)
        try? save(CachedSize(summary: summary, fetchedAt: Date()), key: key)
        return summary
    }

    private func acquireSizeRequest() async throws {
        try Task.checkCancellation()
        if activeSizeRequests < 4 { activeSizeRequests += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sizeWaiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelSizeWaiter(id) }
        }
    }
    private func cancelSizeWaiter(_ id: UUID) {
        guard let index = sizeWaiters.firstIndex(where: { $0.0 == id }) else { return }
        sizeWaiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func releaseSizeRequest() {
        if sizeWaiters.isEmpty { activeSizeRequests -= 1 }
        else { sizeWaiters.removeFirst().1.resume() }
    }
    /// Queries every task in a selected category at the hub, retaining independent pagination.
    /// Trending pages are interleaved by upstream rank so one task cannot bury the other tasks.
    func browse(query: String, category: DiscoveryCategory, task: DiscoveryTask = .all,
                sort: DiscoverySort = .trending, streams: [DiscoveryStream]? = nil,
                offline: Bool = false) async throws -> DiscoveryFeedPage {
        let tasks = category.tasks(for: task)
        let current = streams ?? tasks.map { DiscoveryStream(task: $0) }
        guard current.map(\.task) == tasks else { throw GenerationLibraryError.invalid("Search filters changed. Start a new search.") }
        struct Outcome: Sendable {
            let index: Int
            let page: DiscoveryPage?
            let error: String?
        }
        let outcomes = try await withThrowingTaskGroup(of: Outcome.self) { group in
            for (index, stream) in current.enumerated() where !stream.finished {
                group.addTask {
                    do {
                        let page = try await self.search(query: query, task: stream.task, sort: sort, cursor: stream.cursor, offline: offline)
                        try Task.checkCancellation()
                        return Outcome(index: index, page: page, error: nil)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        return Outcome(index: index, page: nil, error: error.localizedDescription)
                    }
                }
            }
            var result: [Outcome] = []
            for try await outcome in group { result.append(outcome) }
            return result.sorted { $0.index < $1.index }
        }
        try Task.checkCancellation()
        var next = current
        var warnings: [String] = []
        for outcome in outcomes {
            if let page = outcome.page {
                next[outcome.index].cursor = page.nextCursor
                next[outcome.index].finished = page.nextCursor == nil
            } else {
                warnings.append("\(current[outcome.index].task.rawValue.isEmpty ? "Explore" : current[outcome.index].task.rawValue): \(outcome.error ?? "Request unavailable"). Load more to retry this part of the search.")
            }
        }
        let pages = outcomes.compactMap(\.page)
        var interleaved: [DiscoveryModel] = []
        for rank in 0..<(pages.map { $0.models.count }.max() ?? 0) {
            for page in pages where rank < page.models.count { interleaved.append(page.models[rank]) }
        }
        return DiscoveryFeedPage(models: Self.mergedModels(interleaved, sort: sort), streams: next,
            fetchedAt: pages.map(\.fetchedAt).min() ?? Date(), isCached: pages.contains(where: \.isCached), warnings: warnings, successfulRequests: pages.count)
    }

    nonisolated static func mergedModels(_ models: [DiscoveryModel], sort: DiscoverySort) -> [DiscoveryModel] {
        var seen = Set<String>()
        let unique = models.filter { seen.insert($0.id).inserted }
        switch sort {
        case .trending: return unique // Preserve the task feeds' upstream rank and stable interleaving.
        case .downloads: return unique.sorted { $0.downloads == $1.downloads ? $0.id < $1.id : ($0.downloads ?? -1) > ($1.downloads ?? -1) }
        case .latest: return unique.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        }
    }
    func search(query: String, task: DiscoveryTask = .all, sort: DiscoverySort = .latest, cursor: String? = nil, offline: Bool = false) async throws -> DiscoveryPage {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [.init(name: "search", value: String(query.prefix(256))), .init(name: "sort", value: sort.rawValue), .init(name: "direction", value: "-1"), .init(name: "limit", value: "30"), .init(name: "full", value: "true"), .init(name: "cardData", value: "true")]
        if task != .all { components.queryItems?.append(.init(name: "pipeline_tag", value: task.rawValue)) }
        let url = try cursor.map(Self.validCursor) ?? components.url!
        if offline { var page: DiscoveryPage = try cached(url.absoluteString); page.isCached = true; return page }
        do {
            let response = try await transport.fetch(url)
            guard let rows = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else { throw GenerationLibraryError.invalid("Invalid model search response.") }
            let page = DiscoveryPage(models: rows.compactMap(Self.model), nextCursor: Self.nextCursor(response.nextLink), fetchedAt: Date(), isCached: false)
            try? save(page, key: url.absoluteString); return page
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if var page: DiscoveryPage = try? cached(url.absoluteString) { page.isCached = true; return page }
            throw error
        }
    }
    func detail(repository: String, offline: Bool = false) async throws -> DiscoveryDetail {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { throw GenerationLibraryError.invalid("Enter a Hugging Face owner/model identifier.") }
        let url = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true")!
        if offline { var result: DiscoveryDetail = try cached(url.absoluteString); result.isCached = true; return result }
        do {
            let response = try await transport.fetch(url)
            guard let row = try JSONSerialization.jsonObject(with: response.data) as? [String: Any], let model = Self.model(row) else { throw GenerationLibraryError.invalid("Invalid model detail response.") }
            let files = (row["siblings"] as? [[String: Any]] ?? []).compactMap(Self.file)
            var config = row["config"] as? [String: Any] ?? [:]
            var note: String?
            if files.contains(where: { $0.path == "config.json" }), let sha = model.sha, sha.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil {
                do {
                    let configResponse = try await transport.fetch(URL(string: "https://huggingface.co/\(repository)/resolve/\(sha)/config.json")!)
                    guard let decoded = try JSONSerialization.jsonObject(with: configResponse.data) as? [String: Any] else { throw GenerationLibraryError.invalid("Invalid config JSON") }
                    config = decoded
                } catch { if Task.isCancelled { throw CancellationError() }; note = "Configuration unavailable; architecture and context metadata may be incomplete." }
            }
            var publisherExcerpt: String?
            if files.contains(where: { $0.path == "README.md" && ($0.bytes ?? 0) <= Int64(PublisherModelDescription.maximumCardBytes) }),
               let sha = model.sha, sha.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil {
                do {
                    let card = try await transport.fetch(URL(string: "https://huggingface.co/\(repository)/resolve/\(sha)/README.md")!, maximumBytes: PublisherModelDescription.maximumCardBytes)
                    if let markdown = String(data: card.data, encoding: .utf8) { publisherExcerpt = PublisherModelDescription.excerpt(from: markdown) }
                } catch { if error is CancellationError || Task.isCancelled { throw CancellationError() } }
            }
            let result = DiscoveryDetail(model: model, files: files, architectures: config["architectures"] as? [String] ?? [], modelType: config["model_type"] as? String, contextLength: config["max_position_embeddings"] as? Int, requiresCustomCode: config["auto_map"] != nil, configNote: note, ggufArchitectureHint: (row["gguf"] as? [String: Any])?["architecture"] as? String, fetchedAt: Date(), isCached: false, publisherExcerpt: publisherExcerpt)
            try? save(result, key: url.absoluteString); return result
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if var result: DiscoveryDetail = try? cached(url.absoluteString) { result.isCached = true; return result }
            throw error
        }
    }
    nonisolated static func assess(detail: DiscoveryDetail, hardware: HardwareProfile, recipes: [ModelRecipe] = ModelCatalog.recipes) -> DiscoveryAssessment {
        // `runtimeReady` alone is not the readiness signal for image/video recipes (their adapter
        // presence lives in the capability registries; see ModelCompatibility's own note on this).
        // Using it here excluded every media recipe from this Mac's guidance and storage check even
        // when GenStudio has an exact, pinned, adapter-backed component plan for it. Mirrors
        // ModelLibraryViewModel.hasAdapter, kept local here (nonisolated) to avoid a MainActor hop.
        let hasAdapter: (ModelRecipe) -> Bool = { recipe in
            recipe.runtimeReady || (recipe.kind == .video && VideoCapabilityRegistry.hasUsableAdapter(recipe.id)) || (recipe.kind == .image && ImageCapabilityRegistry.hasUsableAdapter(recipe.id)) || (recipe.kind == .upscaler && UpscaleCapabilityRegistry.hasUsableAdapter(recipe.id))
        }
        let matches = recipes.filter { recipe in
            // A usable recipe may span multiple repositories. An inspected repository only
            // needs to supply one or more of its components; the complete route is shown below
            // in the detail sheet and is what the installer evaluates.
            let own = recipe.components.filter { $0.repository.caseInsensitiveCompare(detail.model.id) == .orderedSame }
            return hasAdapter(recipe) && !own.isEmpty && own.allSatisfy { component in
                component.revision == detail.model.sha && detail.files.contains { $0.path == component.filename && $0.bytes == component.byteSize && $0.sha256 == component.sha256 }
            }
        }
        let storage: String
        if let minimum = matches.map(\.totalBytes).min() {
            storage = hardware.freeDiskBytes > 0 ? (minimum > hardware.freeDiskBytes ? "Insufficient free storage for this verified recipe." : "Verified recipe fits available storage; installer checks staging space separately.") : "Available storage is unknown."
        } else { storage = "Repository sizes include alternative files and are not an installation requirement. A verified component plan is needed." }
        guard let memory = matches.map(\.minimumMemoryBytes).min() else {
            return .init(hardware: .unknown, runtimeSupported: false, exactRecipeIDs: [], explanation: "Discovered model; no exact verified bundled recipe. Format or model family alone does not prove runnable support. Performance on this Mac is unmeasured.", storageExplanation: storage)
        }
        // The packaged executables are arm64 and target macOS 26. Unknown strings are not evidence of incompatibility.
        let intel = hardware.chip.lowercased().contains("intel")
        let explicitOS = hardware.osVersion.range(of: #"^(?:Version |macOS )?([0-9]+)(?:\.|$)"#, options: .regularExpression).map { String(hardware.osVersion[$0]) }
        let major = explicitOS.flatMap { Int($0.filter { $0.isNumber }) }
        if intel || (major != nil && major! < 26) {
            return .init(hardware: .incompatible, runtimeSupported: false, exactRecipeIDs: matches.map(\.id), explanation: "Bundled engines require Apple Silicon and macOS 26 or later.", storageExplanation: storage)
        }
        let guidance: DiscoveryAssessment.Guidance = hardware.memoryBytes == 0 || !hardware.chip.hasPrefix("Apple ") || major == nil ? .unknown : hardware.memoryBytes / 2 < memory ? .demanding : .recommended
        return .init(hardware: guidance, runtimeSupported: true, exactRecipeIDs: matches.map(\.id), explanation: "Exact recipe files match a bundled adapter. Memory guidance uses the recipe minimum; speed on this Mac is not inferred from file size.", storageExplanation: storage)
    }
    nonisolated static func validCursor(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host == "huggingface.co", url.path == "/api/models", url.port == nil, url.user == nil, url.password == nil else { throw GenerationLibraryError.invalid("Invalid Hugging Face pagination link.") }
        return url
    }
    private nonisolated static func nextCursor(_ link: String?) -> String? {
        for part in (link ?? "").components(separatedBy: ",") where part.contains("rel=\"next\"") {
            if let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end {
                let value = String(part[part.index(after: start)..<end]); return (try? validCursor(value))?.absoluteString
            }
        }
        return nil
    }
    private nonisolated static func file(_ item: [String: Any]) -> DiscoveryFile? {
        guard let path = item["rfilename"] as? String else { return nil }
        let lfs = item["lfs"] as? [String: Any]
        let number = item["size"] as? NSNumber ?? lfs?["size"] as? NSNumber
        // Reject Boolean, fractional, negative and overflowing sizes instead of wrapping or truncating them.
        let bytes = number.flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() ? Int64($0.stringValue) : nil }.flatMap { $0 >= 0 ? $0 : nil }
        return DiscoveryFile(path: path, bytes: bytes, sha256: lfs?["sha256"] as? String)
    }
    private nonisolated static func model(_ row: [String: Any]) -> DiscoveryModel? {
        guard let id = row["id"] as? String ?? row["modelId"] as? String else { return nil }
        let card = row["cardData"] as? [String: Any] ?? [:]
        // Publisher metadata may be in the card rather than duplicated in list-level fields.
        // Only exact recognized task tags are interpreted by ModelPurpose; names/prose are never guessed.
        var tags = row["tags"] as? [String] ?? []
        for tag in (card["tags"] as? [String] ?? []) where !tags.contains(tag) { tags.append(tag) }
        if let cardTask = card["pipeline_tag"] as? String, !tags.contains(cardTask) { tags.append(cardTask) }
        let pipeline = (row["pipeline_tag"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? card["pipeline_tag"] as? String
        let description = (card["description"] as? String).flatMap { PublisherModelDescription.excerpt(from: $0) }
        func strings(_ value: Any?) -> [String]? {
            let values = (value as? String).map { [$0] } ?? (value as? [Any])?.compactMap { $0 as? String }
            return values.flatMap { $0.isEmpty ? nil : Array($0.prefix(16)) }
        }
        return .init(id: id, sha: row["sha"] as? String, pipelineTag: pipeline, library: row["library_name"] as? String, license: card["license"] as? String ?? tags.first(where: { $0.hasPrefix("license:") }).map { String($0.dropFirst(8)) }, gated: (row["gated"] as? Bool ?? false) || ((row["gated"] as? String).map { $0 != "false" } ?? false), downloads: row["downloads"] as? Int, likes: row["likes"] as? Int, createdAt: row["createdAt"] as? String, lastModified: row["lastModified"] as? String, tags: tags, publisherDescription: description, baseModels: strings(card["base_model"]), instancePrompts: strings(card["instance_prompt"]))
    }
    private func location(_ key: String) -> URL { root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json") }
    private func cached<T: Decodable>(_ key: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(contentsOf: location(key))) }
    private func save<T: Encodable>(_ value: T, key: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: location(key), options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "json" }
        if files.count > 100 {
            let oldest = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for file in oldest.prefix(files.count - 100) { try? FileManager.default.removeItem(at: file) }
        }
    }
}
