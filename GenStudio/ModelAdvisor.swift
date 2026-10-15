import Foundation

/// How many workflow nodes use a model, and in which workflows.
struct ModelUsageSummary: Equatable, Sendable {
    var nodeCount = 0
    var workflowNames: [String] = []
}

/// GenStudio's advice for one installed model on this Mac.
struct ModelAdvice: Identifiable, Equatable, Sendable {
    enum Status: Int, Comparable, Sendable {
        case cannotRun, notNeeded, keep
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
    let id: String
    let name: String
    let kind: GenerationModelKind
    let status: Status
    /// One plain sentence: why it can or cannot be used, or why it is not needed.
    let reason: String
    /// The technical reason behind `reason`, when there is one (shown on hover).
    var detail: String? = nil
    /// The installed or installable recipe that does this job better here.
    let replacementRecipeID: String?
    let bytes: Int64
    let usage: ModelUsageSummary
    /// From this Mac's own run history, when there are at least three finished runs.
    let measured: String?
}

/// A workflow node pointing at a GenStudio catalogue model that is not installed: it cannot run until the
/// model is installed or another is chosen. Cloud routes and external text servers are never listed.
struct MissingModelReference: Identifiable, Equatable, Sendable {
    var id: String { modelID }
    let modelID: String
    let nodeCount: Int
    let workflowNames: [String]
    /// An installed model this Mac keeps that does the same kind of job.
    var replacementRecipeID: String? = nil
}

struct ModelAdviceReport: Equatable, Sendable {
    /// Cannot-run first, then not-needed, then keep; largest first within each.
    var advice: [ModelAdvice]
    var missing: [MissingModelReference]
    /// Recommended for this Mac and not installed yet.
    var toAdd: [ModelRecipe]
    /// Bytes held by models that are not kept. Shared components may make the real saving smaller.
    var reclaimableBytes: Int64
}

/// Decides, from this Mac's hardware, GenStudio's routes and recorded speed-and-quality verdicts, the
/// owner's workflows and this Mac's run history, what each installed model is worth here. Pure: it reads
/// nothing from disk and removes nothing; removal is always the owner's confirmed action.
enum ModelAdvisor {
    /// The models that meet the bar on the reference Mac and together cover every node type (Start Here).
    static let recommendedRecipeIDs: Set<String> = [
        MLXVLMModelCatalog.qwen38RecipeID, MediaModelCatalog.klein9BRecipeID, UpscaleCapabilityRegistry.realesrganX4PlusRecipeID,
        MLXVideoModelCatalog.fastMetal5BRecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID, SpeechModelCatalog.qwen3VoiceDesignRecipeID
    ]

    static func report(installed: [InstalledGenerationModel], hardware: HardwareProfile?, projects: [WorkflowProject], runs: [RunRecord],
                       catalog: [ModelRecipe] = ModelCatalog.recipes) -> ModelAdviceReport {
        let usage = usageByModel(projects)
        let installedIDs = Set(installed.map(\.id))
        let advice = installed.map { model in
            advise(model, installedIDs: installedIDs, installed: installed, hardware: hardware, catalog: catalog,
                   usage: usage[model.id] ?? .init(), measured: measuredLine(runs.filter { $0.snapshot.model == model.id }))
        }.sorted { $0.status != $1.status ? $0.status < $1.status : $0.bytes > $1.bytes }
        let known = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = advice.filter { $0.status == .keep }
        let missing = usage.filter { id, summary in known[id] != nil && !installedIDs.contains(id) && summary.nodeCount > 0 }
            .map { id, summary in
                let kind = known[id]?.kind
                let replacement = kept.first { $0.kind == kind && recommendedRecipeIDs.contains($0.id) } ?? kept.first { $0.kind == kind }
                return MissingModelReference(modelID: id, nodeCount: summary.nodeCount, workflowNames: summary.workflowNames, replacementRecipeID: replacement?.id)
            }
            .sorted { $0.nodeCount > $1.nodeCount }
        let toAdd = catalog.filter { recipe in
            guard recommendedRecipeIDs.contains(recipe.id), !installedIDs.contains(recipe.id) else { return false }
            guard let memory = hardware?.memoryBytes, memory > 0 else { return true }
            return recipe.minimumMemoryBytes <= memory
        }
        let reclaimable = advice.filter { $0.status != .keep }.reduce(Int64(0)) { $0 + $1.bytes }
        return .init(advice: advice, missing: missing, toAdd: toAdd, reclaimableBytes: reclaimable)
    }

    private static func advise(_ model: InstalledGenerationModel, installedIDs: Set<String>, installed: [InstalledGenerationModel],
                               hardware: HardwareProfile?, catalog: [ModelRecipe], usage: ModelUsageSummary, measured: String?) -> ModelAdvice {
        let recipe = model.recipeSnapshot ?? catalog.first { $0.id == model.id }
        func make(_ status: ModelAdvice.Status, _ reason: String, detail: String? = nil, replacement: String? = nil) -> ModelAdvice {
            ModelAdvice(id: model.id, name: displayName(model.id, catalog: catalog) ?? model.name, kind: model.kind, status: status, reason: reason,
                        detail: detail, replacementRecipeID: replacement, bytes: ModelLibraryViewModel.installedBytes(model), usage: usage, measured: measured)
        }
        guard model.available else { return make(.cannotRun, "Some of its files are missing, so it cannot run. Reinstall it, or remove it.") }
        if let recipe, let hardware, hardware.memoryBytes > 0, recipe.minimumMemoryBytes > hardware.memoryBytes {
            return make(.cannotRun, "Needs at least \(gigabytes(recipe.minimumMemoryBytes)) of memory; this Mac has \(gigabytes(hardware.memoryBytes)).")
        }
        if let base = recipe?.baseRecipeID, base != model.id, !model.canAttemptGeneration {
            let original = displayName(base, catalog: catalog) ?? installed.first { $0.id == base }?.name ?? base
            let kept = installedIDs.contains(base) ? " Your working copy is kept." : ""
            return make(.cannotRun, "An update copy of \(original) that GenStudio has no verified route for yet.\(kept)")
        }
        guard model.canAttemptGeneration else {
            let withdrawn = VideoCapabilityRegistry.shipped.lazy.compactMap { capability -> String? in
                guard capability.recipeID == model.id, case .unavailable(let reason) = capability.readiness else { return nil }
                return reason
            }.first
            if let withdrawn {
                return make(.cannotRun, "GenStudio can't run this model here: its route was withdrawn after it failed on this Mac.", detail: withdrawn)
            }
            return make(.cannotRun, "GenStudio has no way to run this model in this version.")
        }
        if let verdict = MacFitStandard.verdict(forSubject: "recipe:\(model.id)") ?? recipe?.baseRecipeID.flatMap({ MacFitStandard.verdict(forSubject: "recipe:\($0)") }) {
            switch verdict.status {
            case .meets, .expectedToMeet, .alternativeLook:
                return make(.keep, verdict.advice ?? "Meets this Mac's speed-and-quality bar.")
            case .finalQuality:
                return make(.keep, verdict.advice ?? "Final quality: slower here, but better output for the final render.")
            case .doesNotMeet:
                return make(.notNeeded, verdict.advice ?? verdict.speed, replacement: verdict.replacedBy)
            }
        }
        if recommendedRecipeIDs.contains(model.id) { return make(.keep, "Part of the recommended set for this Mac.") }
        return make(.notNeeded, "Not assessed for this Mac and not part of its recommended set.")
    }

    private static func usageByModel(_ projects: [WorkflowProject]) -> [String: ModelUsageSummary] {
        var result: [String: ModelUsageSummary] = [:]
        for project in projects {
            for node in project.nodes where !node.model.isEmpty {
                var entry = result[node.model] ?? .init()
                entry.nodeCount += 1
                if !entry.workflowNames.contains(project.name) { entry.workflowNames.append(project.name) }
                result[node.model] = entry
            }
        }
        return result
    }

    private static func measuredLine(_ runs: [RunRecord]) -> String? {
        let durations = runs.compactMap { run -> Double? in
            guard run.status == .succeeded, let start = run.startedAt, let end = run.finishedAt else { return nil }
            return end.timeIntervalSince(start)
        }.sorted()
        guard durations.count >= 3 else { return nil }
        return "Your \(durations.count) runs here took a median of \(spoken(durations[durations.count / 2]))."
    }

    /// Appended to a model's name in node pickers when it is below this Mac's speed-and-quality bar.
    /// Final-quality models carry their wait instead, so a slow pick is never a surprise.
    static func pickerNote(_ recipeID: String) -> String {
        if let text = FinalQualityBadge.text(recipeID: recipeID) { return " · ⏱ \(text)" }
        return MacFitStandard.verdict(forSubject: "recipe:\(recipeID)")?.status == .doesNotMeet ? " · not recommended here" : ""
    }

    /// A short name that keeps the version: "LTX-2.3 MLX Q4", "Wan 2.1 T2V 1.3B", "Qwen 3.8 27B". An update copy
    /// (`<base>-v-<digest>`) is named after its original. Nil for an id the catalogue does not know.
    static func displayName(_ recipeID: String, catalog: [ModelRecipe] = ModelCatalog.recipes) -> String? {
        if let range = recipeID.range(of: "-v-"), let base = displayName(String(recipeID[..<range.lowerBound]), catalog: catalog) {
            return base + " (update copy)"
        }
        guard let recipe = catalog.first(where: { $0.id == recipeID }) else { return nil }
        let title = ModelRecipePresentation.title(recipe).components(separatedBy: " · ").first ?? recipe.name
        if title.contains(where: \.isNumber) { return title }
        return recipe.name.components(separatedBy: " · ").first ?? recipe.name
    }

    static func spoken(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func gigabytes(_ bytes: UInt64) -> String { "\(Int((Double(bytes) / Double(1 << 30)).rounded())) GB" }
}
