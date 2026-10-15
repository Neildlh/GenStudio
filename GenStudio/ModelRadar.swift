import Foundation

// The radar's judgement lives here and nowhere else. Tier and fit are computed from the
// shipped capability rules and this Mac's hardware; a language model only ever writes
// wording around these results (see RadarWriter).

/// How far GenStudio can take a model, best first.
enum RadarTier: Int, Comparable, Codable, Sendable {
    /// A decoded local render has proven this route.
    case proven
    /// A route exists and is not withdrawn, but nothing has been rendered through it yet.
    case readyToTest
    /// Released upstream; GenStudio has no route for it.
    case watch

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .proven: "Proven"
        case .readyToTest: "Ready to test"
        case .watch: "Watch"
        }
    }
}

enum RadarFitLevel: String, Codable, Sendable {
    case comfortable, demanding, exceeds, unknown
}

struct RadarFit: Equatable, Sendable {
    let level: RadarFitLevel
    let label: String
    let detail: String
}

struct RadarEntry: Identifiable, Equatable, Sendable {
    /// `recipe:<recipe id>` for a GenStudio route, `watch:<family>:<generation>` for an upstream release.
    let id: String
    let familyID: String
    let category: RadarCategory
    let tier: RadarTier
    let title: String
    let generation: RadarGeneration?
    /// The GenStudio route. Nil for a Watch entry, which can never be installed.
    let recipeID: String?
    /// The upstream repository a Watch entry is about.
    let repository: String?
    let released: Date?
    let sizeBytes: Int64?
    let fit: RadarFit
    let installed: Bool
    /// Built-in wording, used whenever no writer produced a better sentence.
    let facts: String
    let gated: Bool
    /// Community Apple-Silicon (MLX) builds of a Watch entry's generation.
    let buildRepositories: [HubRepo]
    /// What the model is for, in GenStudio's own catalogue wording. Nil for a Watch entry, because
    /// the only description of an upstream release would be publisher text, which is untrusted.
    var purpose: String? = nil
    /// The speed-and-quality assessment behind showing this entry. Attached by `MacFitStandard.present`.
    var verdict: MacFitVerdict? = nil
}

struct RadarFamilyReport: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let category: RadarCategory
    /// Highest generation GenStudio can run for this family. Nil when it has no usable route.
    let runsUpTo: RadarGeneration?
    let newestUpstream: RadarGeneration?
    /// True when this family was checked successfully in the current snapshot.
    let checked: Bool
    let status: String
    let failure: String?
    let entries: [RadarEntry]
}

/// What the Hub said about one family at check time. Everything else is derived from this.
struct FamilyLive: Codable, Equatable, Sendable {
    let familyID: String
    let newest: NewestUpstream?
    /// Community MLX builds of `newest.generation`.
    let builds: [HubRepo]
    /// Total weight-file bytes per repository id, for the fit check.
    let sizes: [String: Int64]
    let error: String?
}

/// The persisted result of one check: live facts plus whatever the writer said about them.
struct RadarSnapshot: Codable, Equatable, Sendable {
    let fetchedAt: Date
    var families: [FamilyLive]
    var summary: String?
    /// Writer sentences keyed by `RadarEntry.id`.
    var blurbs: [String: String]
    /// Attribution for the wording, for example "Qwen 3.8 27B on this Mac".
    var writer: String?
    /// Ids of the entries the writer was shown. Notes are only valid for exactly that set, so a summary can never
    /// outlive the models it was about. Nil for a cache written before this existed.
    var writtenFor: [String]? = nil

    /// The writer's notes, but only if they were written about exactly the models visible now. Otherwise nil, and the
    /// built-in wording shows instead. This is what stops a stale summary naming a model that has since been hidden.
    func notes(forVisible visibleIDs: [String]) -> RadarNotes? {
        guard let writtenFor, Set(writtenFor) == Set(visibleIDs), summary != nil || !blurbs.isEmpty else { return nil }
        return RadarNotes(summary: summary, blurbs: blurbs, writer: writer)
    }
}

struct RadarNotes: Equatable, Sendable {
    let summary: String?
    let blurbs: [String: String]
    let writer: String?
}

/// Everything the radar needs to know about the app's current state. Closures keep the engine
/// testable without a running library or an installed MLX runtime.
struct RadarInputs {
    var recipe: (String) -> ModelRecipe?
    var assess: (ModelRecipe) -> ModelCompatibility.Assessment
    var proven: (ModelRecipe) -> Bool
    var installed: Set<String>
    var hardware: HardwareProfile?
}

enum ModelRadar {
    static func report(snapshot: RadarSnapshot?, families: [WatchFamily] = ModelWatchlist.families,
                       standalone: [(recipeID: String, category: RadarCategory)] = ModelWatchlist.standaloneRoutes, inputs: RadarInputs) -> [RadarFamilyReport] {
        families.map { family in
            report(for: family, live: snapshot?.families.first { $0.familyID == family.id }, inputs: inputs)
        } + standaloneReports(standalone, inputs: inputs)
    }

    /// Unversioned routes, one "Also a strong fit" group per category.
    private static func standaloneReports(_ routes: [(recipeID: String, category: RadarCategory)], inputs: RadarInputs) -> [RadarFamilyReport] {
        RadarCategory.allCases.compactMap { category in
            let entries = routes.filter { $0.category == category }.compactMap { route -> RadarEntry? in
                guard let recipe = inputs.recipe(route.recipeID) else { return nil }
                return routeEntry(recipe, familyID: "picks-\(category.rawValue)", category: category, generation: nil,
                                  title: ModelRecipePresentation.title(recipe), inputs: inputs)
            }
            guard !entries.isEmpty else { return nil }
            return RadarFamilyReport(id: "picks-\(category.rawValue)", title: "Also a strong fit", category: category, runsUpTo: nil,
                                     newestUpstream: nil, checked: false, status: "", failure: nil, entries: entries)
        }
    }

    private static func report(for family: WatchFamily, live: FamilyLive?, inputs: RadarInputs) -> RadarFamilyReport {
        var entries = routeEntries(for: family, inputs: inputs)
        let runsUpTo = entries.compactMap(\.generation).max()
        let checked = live != nil && live?.error == nil
        var newest: RadarGeneration?

        if let live, live.error == nil, let upstream = live.newest {
            newest = upstream.generation
            if runsUpTo.map({ upstream.generation > $0 }) ?? true {
                entries.append(watchEntry(for: family, live: live, upstream: upstream, inputs: inputs))
            }
        }

        entries.sort { lhs, rhs in
            let l = lhs.generation, r = rhs.generation
            if l != r { return (l ?? RadarGeneration("0")!) > (r ?? RadarGeneration("0")!) }
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.title < rhs.title
        }

        return RadarFamilyReport(id: family.id, title: family.title, category: family.category, runsUpTo: runsUpTo, newestUpstream: newest,
                                 checked: checked, status: status(family: family, live: live, runsUpTo: runsUpTo, newest: newest),
                                 failure: live?.error, entries: entries)
    }

    // MARK: GenStudio routes

    private static func routeEntries(for family: WatchFamily, inputs: RadarInputs) -> [RadarEntry] {
        family.coverage.compactMap { recipeID, generationText in
            guard let recipe = inputs.recipe(recipeID), let generation = RadarGeneration(generationText) else { return nil }
            // The friendly catalogue title can drop the version ("Wan · Video Generation"); a version
            // ladder needs it, so fall back to the recipe's own name when the title omits it.
            let friendly = ModelRecipePresentation.title(recipe)
            let title = friendly.contains(generation.text) ? friendly : recipe.name
            return routeEntry(recipe, familyID: family.id, category: family.category, generation: generation, title: title, inputs: inputs)
        }
    }

    private static func routeEntry(_ recipe: ModelRecipe, familyID: String, category: RadarCategory, generation: RadarGeneration?,
                                   title: String, inputs: RadarInputs) -> RadarEntry? {
        let assessment = inputs.assess(recipe)
        // A withdrawn or adapter-less route is not a route; it must never count as coverage.
        guard assessment.state != .unsupported, assessment.state != .needsValidation else { return nil }
        let tier: RadarTier = inputs.proven(recipe) ? .proven : .readyToTest
        let installed = inputs.installed.contains(recipe.id)
        return RadarEntry(id: "recipe:\(recipe.id)", familyID: familyID, category: category, tier: tier,
                          title: title, generation: generation, recipeID: recipe.id, repository: nil,
                          released: nil, sizeBytes: recipe.totalBytes, fit: fit(from: assessment), installed: installed,
                          facts: facts(tier: tier, installed: installed), gated: false, buildRepositories: [],
                          purpose: purpose(for: recipe))
    }

    /// The catalogue's fallback description for a video recipe with no `MediaModelCatalog` profile reads
    /// "GenStudio has no verified adapter for this package". That is false for a recipe that has a working
    /// route (LTX-2.3 MLX), and an entry that exists *because* a route exists must never carry text that
    /// contradicts it. Such text is withheld, so the built-in wording shows instead. The root cause is the
    /// fallback in `ModelRecipePresentation.purpose`, which is outside this feature.
    private static func purpose(for recipe: ModelRecipe) -> String? {
        let text = ModelRecipePresentation.purpose(recipe)
        return text.localizedCaseInsensitiveContains("no verified adapter") ? nil : text
    }

    private static func fit(from assessment: ModelCompatibility.Assessment) -> RadarFit {
        let level: RadarFitLevel
        switch assessment.state {
        case .supported: level = .comfortable
        case .demanding: level = assessment.eligible ? .demanding : .exceeds
        case .insufficientStorage, .incompatible: level = .exceeds
        case .unknownResources, .unsupported, .needsValidation: level = .unknown
        }
        // A supported route's own label is about adapter maturity ("Adapter available · not yet
        // verified"), which the tier chip already says. Every other state's label explains a
        // limit worth showing (storage, memory, platform) and is kept.
        let label = assessment.state == .supported ? "Fits this Mac" : assessment.label
        return RadarFit(level: level, label: label, detail: assessment.detail)
    }

    private static func facts(tier: RadarTier, installed: Bool) -> String {
        switch (tier, installed) {
        case (.proven, true): "Installed. A decoded local render has proven this route."
        case (.proven, false): "Runs in GenStudio. A decoded local render has proven this route."
        case (.readyToTest, true): "Installed. No decoded render has proven this route yet, so your first run is the test."
        case (.readyToTest, false): "GenStudio has a route for this. No decoded render has proven it yet, so your first run is the test."
        case (.watch, _): "GenStudio has no route for this yet."
        }
    }

    // MARK: upstream releases GenStudio cannot run

    private static func watchEntry(for family: WatchFamily, live: FamilyLive, upstream: NewestUpstream, inputs: RadarInputs) -> RadarEntry {
        let repository = upstream.repos.first
        // Fit follows what the user could actually download: the smallest surfaced Apple-Silicon
        // build. The upstream repository is often full-precision and far larger than any build.
        let size: Int64? = live.builds.isEmpty
            ? repository.flatMap { live.sizes[$0.id] }
            : live.builds.compactMap { live.sizes[$0.id] }.min()
        var sentence = "GenStudio has no route for this yet."
        if !live.builds.isEmpty { sentence += " Apple Silicon (MLX) builds already exist." }
        if let released = repository?.createdAt {
            sentence = "Released \(released.formatted(.dateTime.day().month(.abbreviated).year())). " + sentence
        }
        return RadarEntry(id: "watch:\(family.id):\(upstream.generation.text)", familyID: family.id, category: family.category, tier: .watch,
                          title: "\(family.title) \(upstream.generation.text)", generation: upstream.generation, recipeID: nil,
                          repository: repository?.id, released: repository?.createdAt, sizeBytes: size,
                          fit: watchFit(bytes: size, hardware: inputs.hardware), installed: false, facts: sentence,
                          gated: repository?.gated ?? false, buildRepositories: live.builds)
    }

    /// Published repository size against this Mac. Deliberately worded as published size, not an install plan.
    static func watchFit(bytes: Int64?, hardware: HardwareProfile?) -> RadarFit {
        guard let bytes, bytes > 0, let hardware, hardware.memoryBytes > 0 else {
            return RadarFit(level: .unknown, label: "Fit unknown", detail: "The published size or this Mac's memory could not be established, so GenStudio does not guess.")
        }
        let size = ModelLibraryViewModel.bytes(bytes)
        let usable = ModelLibraryViewModel.bytes(Int64(clamping: hardware.usableModelBytes))
        let comfortable = ModelLibraryViewModel.bytes(Int64(clamping: hardware.comfortableModelBytes))
        if UInt64(bytes) <= hardware.comfortableModelBytes {
            return RadarFit(level: .comfortable, label: "Would fit comfortably", detail: "Published files total \(size); this Mac holds about \(comfortable) comfortably. Published size is not an install plan.")
        }
        if UInt64(bytes) <= hardware.usableModelBytes {
            return RadarFit(level: .demanding, label: "Would be demanding", detail: "Published files total \(size); models can use about \(usable) here, leaving little headroom. Published size is not an install plan.")
        }
        return RadarFit(level: .exceeds, label: "Larger than this Mac can hold", detail: "Published files total \(size) but models can use about \(usable) here. A smaller quantised build may exist; published size is not an install plan.")
    }

    // MARK: wording

    private static func status(family: WatchFamily, live: FamilyLive?, runsUpTo: RadarGeneration?, newest: RadarGeneration?) -> String {
        let runs = runsUpTo.map { "\(family.title) \($0.text)" }
        if let error = live?.error, !error.isEmpty {
            return "Couldn't check for new \(family.title) releases · " + (runs.map { "GenStudio runs up to \($0)." } ?? "GenStudio has no route for this family yet.")
        }
        guard live != nil else {
            return "Not checked yet · " + (runs.map { "GenStudio runs up to \($0)." } ?? "GenStudio has no route for this family yet.")
        }
        guard let newest else { return "No new \(family.title) base releases found." + (runs.map { " GenStudio runs up to \($0)." } ?? "") }
        if let runsUpTo, runsUpTo >= newest { return "GenStudio runs the newest generation, \(family.title) \(newest.text)." }
        return "Newest upstream: \(family.title) \(newest.text) · " + (runsUpTo.map { "GenStudio runs up to \($0.text)." } ?? "GenStudio has no route for this family yet.")
    }
}
