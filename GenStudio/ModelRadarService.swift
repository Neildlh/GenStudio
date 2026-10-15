import Foundation

extension RadarSnapshot {
    /// True when no family could be checked at all: the caller should keep its previous snapshot.
    var isTotalFailure: Bool { !families.isEmpty && families.allSatisfy { $0.error != nil } }
}

/// Asks the Hugging Face API what each watched family has released, and caches the answer.
/// It reads listings and file sizes only. Nothing it fetches is executed, installed or written
/// anywhere except its own JSON cache, and a failure in one family never affects another.
actor ModelRadarService {
    private let transport: any DiscoveryTransport
    private let cacheRoot: URL

    init(transport: any DiscoveryTransport = HubDiscoveryTransport(), cacheRoot: URL? = nil) {
        self.transport = transport
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GenStudio/Radar", isDirectory: true)
    }

    // MARK: checking

    /// One live snapshot. Per-family failures are recorded in the result; only cancellation throws.
    func check(families: [WatchFamily] = ModelWatchlist.families) async throws -> RadarSnapshot {
        let results = try await withThrowingTaskGroup(of: (Int, FamilyLive).self) { group in
            for (index, family) in families.enumerated() {
                group.addTask { (index, try await self.live(for: family)) }
            }
            var collected: [(Int, FamilyLive)] = []
            for try await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return RadarSnapshot(fetchedAt: Date(), families: results, summary: nil, blurbs: [:], writer: nil)
    }

    private func live(for family: WatchFamily) async throws -> FamilyLive {
        do {
            let repos = try await listing(query: [.init(name: "author", value: family.publisher)], limit: 100)
            guard let newest = family.newest(in: repos) else {
                return FamilyLive(familyID: family.id, newest: nil, builds: [], sizes: [:], error: nil)
            }
            var builds: [HubRepo] = []
            if let search = family.appleSiliconQuery(generation: newest.generation) {
                do { builds = family.appleSiliconBuilds(in: try await listing(query: [.init(name: "search", value: search)], limit: 50), generation: newest.generation) }
                catch is CancellationError { throw CancellationError() }
                catch { builds = [] }   // the upstream result is still worth showing without builds
            }
            // Fit follows what could actually be downloaded: the builds if there are any, else the upstream repo.
            var sizes: [String: Int64] = [:]
            for repo in builds.isEmpty ? Array(newest.repos.prefix(1)) : builds {
                try Task.checkCancellation()
                if let bytes = try? await weightBytes(of: repo.id) { sizes[repo.id] = bytes }
            }
            try Task.checkCancellation()
            return FamilyLive(familyID: family.id, newest: newest, builds: builds, sizes: sizes, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return FamilyLive(familyID: family.id, newest: nil, builds: [], sizes: [:], error: error.localizedDescription)
        }
    }

    // MARK: Hub requests

    private func listing(query: [URLQueryItem], limit: Int) async throws -> [HubRepo] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = query + [.init(name: "sort", value: "createdAt"), .init(name: "direction", value: "-1"), .init(name: "limit", value: String(limit))]
        let response = try await transport.fetch(components.url!, maximumBytes: 4 * 1024 * 1024)
        guard let rows = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else {
            throw GenerationLibraryError.invalid("Hugging Face returned a listing GenStudio could not read.")
        }
        return rows.compactMap(Self.repo)
    }

    private func weightBytes(of repository: String) async throws -> Int64? {
        guard try ModelLibrary.parseHubLink(repository) == repository,
              let url = URL(string: "https://huggingface.co/api/models/\(repository)?blobs=true") else { return nil }
        let response = try await transport.fetch(url, maximumBytes: 4 * 1024 * 1024)
        return Self.weightBytes(in: try JSONSerialization.jsonObject(with: response.data))
    }

    // MARK: parsing (pure)

    /// Rows with an id that is not a plain `owner/name` are dropped: the Hub is untrusted input.
    nonisolated static func repo(_ row: [String: Any]) -> HubRepo? {
        guard let id = row["id"] as? String, (try? ModelLibrary.parseHubLink(id)) == id else { return nil }
        let gated: Bool
        if let flag = row["gated"] as? Bool { gated = flag } else { gated = row["gated"] is String }   // "auto" / "manual"
        return HubRepo(id: id, createdAt: (row["createdAt"] as? String).flatMap(date), downloads: (row["downloads"] as? NSNumber)?.intValue,
                       likes: (row["likes"] as? NSNumber)?.intValue, pipelineTag: row["pipeline_tag"] as? String, gated: gated)
    }

    nonisolated private static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Total weight bytes a repository publishes. `.safetensors` wins when present; a repository that
    /// offers only GGUF files lists alternative quantisations of one model, so its total would be
    /// meaningless and no size is reported.
    nonisolated static func weightBytes(in json: Any) -> Int64? {
        guard let object = json as? [String: Any], let siblings = object["siblings"] as? [[String: Any]] else { return nil }
        let files: [(name: String, bytes: Int64)] = siblings.compactMap { sibling in
            guard let name = sibling["rfilename"] as? String else { return nil }
            let bytes = (sibling["size"] as? NSNumber)?.int64Value ?? ((sibling["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value
            return bytes.map { (name, $0) }
        }
        func total(_ extensions: Set<String>) -> Int64? {
            let matching = files.filter { extensions.contains(URL(fileURLWithPath: $0.name).pathExtension.lowercased()) && $0.bytes > 0 }
            guard !matching.isEmpty else { return nil }
            var sum: Int64 = 0
            for file in matching {
                let next = sum.addingReportingOverflow(file.bytes)
                guard !next.overflow else { return nil }
                sum = next.partialValue
            }
            return sum
        }
        if let safetensors = total(["safetensors"]) { return safetensors }
        if files.contains(where: { $0.name.lowercased().hasSuffix(".gguf") }) { return nil }
        return total(["bin", "pth", "pt", "ckpt"])
    }

    // MARK: cache

    private var cacheURL: URL { cacheRoot.appendingPathComponent("snapshot.json") }

    /// The last saved snapshot, or nil when there is none or it cannot be read. The cache is
    /// regenerable, so a bad file is treated as absent rather than as an error.
    func loadCached() -> RadarSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RadarSnapshot.self, from: data)
    }

    /// Best effort: failing to cache must never break a check that already succeeded.
    func save(_ snapshot: RadarSnapshot) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
