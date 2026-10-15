import Foundation

enum RadarCategory: String, Codable, CaseIterable, Sendable {
    case video, image, textVision

    var title: String {
        switch self {
        case .video: "Video"
        case .image: "Image"
        case .textVision: "Text & vision"
        }
    }

    var systemImage: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .textVision: "text.viewfinder"
        }
    }
}

/// A model family's version, such as `2.2` or `3.8`. Compared numerically per component so
/// `2.10` is newer than `2.9`; trailing zeros are insignificant, so `2` equals `2.0`.
struct RadarGeneration: Comparable, Hashable, Codable, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let parsed = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(nil) else { return nil }
        var numbers = parsed.compactMap { $0 }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        components = numbers
    }

    var text: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

/// A repository as listed by the Hugging Face API. Only the fields the radar needs.
struct HubRepo: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let createdAt: Date?
    let downloads: Int?
    let likes: Int?
    let pipelineTag: String?
    let gated: Bool
}

/// The newest generation a publisher has released, with its most recent base repositories.
struct NewestUpstream: Codable, Hashable, Sendable {
    let generation: RadarGeneration
    let repos: [HubRepo]
}

/// One model line the radar follows. Adding a family is adding one entry to `ModelWatchlist.families`.
struct WatchFamily: Sendable {
    let id: String
    let title: String
    let category: RadarCategory
    /// Hugging Face author whose releases define "newest".
    let publisher: String
    /// Matched against the repository name (the part after `owner/`). Capture group 1 is the generation.
    let generationPattern: String
    /// Repositories matching this are adapters or format re-builds of a base model, not new generations.
    let excludePattern: String
    /// GenStudio recipe → the generation it lets the user run.
    let coverage: [String: String]
    /// Name stem (lowercase) that community Apple-Silicon builds of this family carry, for example `ltx-`.
    /// Nil when this family has no MLX builds worth looking for.
    var appleSiliconSearch: String?

    /// The generation a repository belongs to, or nil for another publisher's repository, an
    /// adapter or format variant, or a name with no version in it.
    func generation(ofRepository repository: String) -> RadarGeneration? {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].caseInsensitiveCompare(publisher) == .orderedSame else { return nil }
        let name = String(parts[1])
        guard name.range(of: excludePattern, options: .regularExpression) == nil,
              let pattern = try? NSRegularExpression(pattern: generationPattern),
              let match = pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: name) else { return nil }
        return RadarGeneration(String(name[range]))
    }

    /// The highest generation present in `repos`, with up to three of its base repositories, newest first.
    func newest(in repos: [HubRepo]) -> NewestUpstream? {
        let known = repos.compactMap { repo in generation(ofRepository: repo.id).map { (generation: $0, repo: repo) } }
        guard let top = known.map(\.generation).max() else { return nil }
        let inTop = known.filter { $0.generation == top }.map(\.repo).sorted(by: Self.newestFirst)
        return NewestUpstream(generation: top, repos: Array(inTop.prefix(3)))
    }

    /// The Hub search that looks for community MLX builds of `generation`, e.g. `ltx-2.5 mlx`.
    func appleSiliconQuery(generation: RadarGeneration) -> String? {
        appleSiliconSearch.map { "\($0)\(generation.text) mlx" }
    }

    /// MLX repositories of exactly this generation, most downloaded first, at most three.
    func appleSiliconBuilds(in repos: [HubRepo], generation: RadarGeneration) -> [HubRepo] {
        guard let stem = appleSiliconSearch else { return [] }
        let token = NSRegularExpression.escapedPattern(for: stem + generation.text)
        let matching = repos.filter { repo in
            let name = (repo.id.split(separator: "/").last.map(String.init) ?? repo.id).lowercased()
            return name.contains("mlx") && name.range(of: token + "(?![0-9])", options: .regularExpression) != nil
        }
        return Array(matching.sorted { lhs, rhs in
            if (lhs.downloads ?? 0) != (rhs.downloads ?? 0) { return (lhs.downloads ?? 0) > (rhs.downloads ?? 0) }
            return Self.newestFirst(lhs, rhs)
        }.prefix(3))
    }

    private static func newestFirst(_ lhs: HubRepo, _ rhs: HubRepo) -> Bool {
        if lhs.createdAt != rhs.createdAt { return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast) }
        return lhs.id < rhs.id
    }
}

/// The model lines GenStudio follows. Chosen from live Hub data on 2026-09-18; the recipe
/// coverage is checked against the shipped catalogue by `ModelWatchlistTests`.
enum ModelWatchlist {
    static let families: [WatchFamily] = [
        WatchFamily(
            id: "wan", title: "Wan", category: .video, publisher: "Wan-AI",
            generationPattern: #"^Wan(\d+(?:\.\d+)*)-"#,
            excludePattern: "(?i)(lora|diffusers|distilled|fp8|nvfp4|gguf|mlx)",
            coverage: [VideoCapabilityRegistry.wanT2VRecipeID: "2.1", MediaModelCatalog.wan21FLFRecipeID: "2.1", MediaModelCatalog.wan22TI2VRecipeID: "2.2"],
            appleSiliconSearch: "wan"),
        WatchFamily(
            id: "ltx", title: "LTX", category: .video, publisher: "Lightricks",
            generationPattern: #"^LTX-(\d+(?:\.\d+)*)"#,
            excludePattern: "(?i)(lora|fp8|nvfp4|gguf|mlx)",
            coverage: [MLXVideoModelCatalog.ltx23Q4RecipeID: "2.3", VideoCapabilityRegistry.ltx25RecipeID: "2.5"],
            appleSiliconSearch: "ltx-"),
        WatchFamily(
            id: "flux", title: "FLUX", category: .image, publisher: "black-forest-labs",
            generationPattern: #"^FLUX\.(\d+(?:\.\d+)*)"#,
            excludePattern: "(?i)(lora|fp8|nvfp4|gguf|mlx|decoder|-kv)",
            coverage: [MediaModelCatalog.kleinRecipeID: "2", MediaModelCatalog.klein9BRecipeID: "2"],
            appleSiliconSearch: nil),
        WatchFamily(
            id: "qwen", title: "Qwen", category: .textVision, publisher: "Qwen",
            generationPattern: #"^Qwen(\d+(?:\.\d+)*)-"#,
            excludePattern: "(?i)(fp8|nvfp4|gguf|mlx|awq|gptq|int4|int8|asr|aligner|embedding|reranker|tts)",
            coverage: [MLXVLMModelCatalog.qwen38RecipeID: "3.8"],
            appleSiliconSearch: nil),
    ]

    /// GenStudio routes with no version ladder to follow (Z-Image Turbo has no version number). They are
    /// listed under "Also a strong fit" with an install action; the speed-and-quality bar still decides
    /// whether they show.
    static let standaloneRoutes: [(recipeID: String, category: RadarCategory)] = [
        (MediaModelCatalog.zImageTurboRecipeID, .image),
    ]
}
