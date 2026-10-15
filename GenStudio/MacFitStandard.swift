import Foundation

// The owner's rule for the suggestion system: only mention and work with models that meet BOTH a speed and a
// quality bar on this Mac. Everything here is data plus one filter. A model with no verdict is unassessed and is
// never shown (fail closed); a model that fails the bar is recorded so the decision is not re-litigated, and is
// never shown either. Nothing in this file installs, downloads or runs anything.

enum MacFitStatus: String, Codable, Sendable {
    /// Measured on this Mac and clears the bar.
    case meets
    /// Not measured here, but independent evidence and this Mac's own measurements clear the bar with margin.
    case expectedToMeet
    /// Fast enough here and a different look from the leading model (not a lower-quality copy of it). Suggested and kept,
    /// labelled with how it differs, so the user can choose the look they want.
    case alternativeLook
    /// Misses the speed bar, but evidence shows it beats the fast model for the same job. Kept and offered as the
    /// final render, always labelled with its wait so the user chooses it knowingly. Draft with `draftWith` first.
    case finalQuality
    /// Assessed and rejected. Recorded, never shown.
    case doesNotMeet
}

enum MacFitBasis: String, Codable, Sendable {
    case measuredOnThisMac, scaledFromMeasured, thirdPartyReport

    var label: String {
        switch self {
        case .measuredOnThisMac: "measured on this Mac"
        case .scaledFromMeasured: "estimate scaled from this Mac's measurements"
        case .thirdPartyReport: "third-party report"
        }
    }
}

struct MacFitVerdict: Codable, Equatable, Sendable {
    /// `recipe:<recipe id>` for a GenStudio route, `suggest:<key>` for a model GenStudio cannot run yet.
    let subject: String
    let status: MacFitStatus
    let basis: MacFitBasis
    let quality: String
    let speed: String
    /// ISO date (yyyy-MM-dd) the assessment was made.
    let assessed: String
    /// URLs or repository paths of the evidence.
    let sources: [String]
    var note: String? = nil
    /// One plain sentence for the installed-model advisor ("Too slow here: …"). Falls back to `speed`.
    var advice: String? = nil
    /// The recipe that does this job better on this Mac, offered when this one is not needed.
    var replacedBy: String? = nil
    /// Final-quality models only: the typical wait on this Mac, short enough for a badge ("about 25 min a clip").
    var wait: String? = nil
    /// Final-quality models only: the fast recipe to draft and check with before committing to the wait.
    var draftWith: String? = nil
    /// Final-quality models only: the evidence that it beats `draftWith` for the same job.
    var outranksDraft: String? = nil

    var suggestable: Bool { status != .doesNotMeet }
}

/// What the Model Library shows: only assessed models, plus a count (never names) of newer releases still waiting.
struct RadarPresentation: Equatable, Sendable {
    var families: [RadarFamilyReport]
    var unassessedNewerReleases: Int
}

/// A model that meets the bar but has no GenStudio route yet.
struct MacSuggestion: Sendable {
    let key: String
    let title: String
    let category: RadarCategory
    let repository: String
    /// Repositories holding runnable builds, for links only.
    let builds: [String]
    let routeNote: String
}

enum MacFitStandard {
    /// Shown under the section so the bar is never hidden from the person relying on it.
    static let barSummary = "Fast models are shown only if they meet both. A model that misses the speed bar is offered only as a Final-quality model, marked with an amber clock and its wait, and only if evidence shows it beats the fast model for the same job. Quality: in the leading group (roughly the top third) of open-weight models in independent blind votes for its task, or a result decoded and inspected on this Mac. Speed: a still in ≤ 60 s at 512² and ≤ 4 min at 1024²; a 5-second video clip in ≤ 5 min; an assistant answer about an image in ≤ 30 s. Anything not yet assessed is not shown."

    private static let aaText = "https://artificialanalysis.ai/image/leaderboard/text-to-image/open-weights"
    private static let aaEdit = "https://artificialanalysis.ai/image/leaderboard/editing/open-weights"
    private static let aaVideo = "https://artificialanalysis.ai/video/leaderboard/text-to-video/open-weights"
    private static let evidenceMLX = "docs/evidence/mlx-m1max-2026-09-19.md"
    private static let evidenceEngine = "docs/evidence/engine-benchmark-m1max-2026-09-18.md"
    private static let evidenceVideo = "docs/evidence/video-benchmark-m1max-2026-09-18.md"
    private static let evidenceFastVideo = "docs/evidence/fast-local-video-m1max-2026-10-12.md"
    private static let evidenceAudit = "docs/evidence/app-efficiency-audit-2026-10-12.md"

    static let verdicts: [MacFitVerdict] = [
        // MARK: meets — measured on this Mac
        MacFitVerdict(
            subject: "recipe:\(MediaModelCatalog.klein9BRecipeID)", status: .meets, basis: .measuredOnThisMac,
            quality: "Third-best open-weight model for image editing in independent blind votes (Elo 1014) and 17th for text-to-image (Elo 940). Artificial Analysis, July 2026 data.",
            speed: "Measured on this Mac: 31.8 s for a 512×512 image (4 steps). About 2 minutes at 1024×1024, scaled from the measured step time.",
            assessed: "2026-09-20", sources: [aaEdit, aaText, evidenceEngine],
            note: "FLUX Non-Commercial License: not for commercial work without a separate licence from Black Forest Labs."),
        MacFitVerdict(
            subject: "recipe:\(MLXVideoModelCatalog.ltx23Q4RecipeID)", status: .meets, basis: .measuredOnThisMac,
            quality: "4th-ranked open-weight text-to-video model in independent blind votes (Elo 975, March 2026 data). Inspected here: a coherent 5-second clip, stable geometry, 121 distinct frames out of 121; float16 compute renders the same shot as before.",
            speed: "Measured on this Mac: 2 min 53 s for a 5-second 768×448 clip with the float16 runtime (was 3 min 55 s on the previous runtime), peak memory 22 GB (was 53 GB). The Mac was moderately busy.",
            assessed: "2026-10-12", sources: [aaVideo, evidenceFastVideo, evidenceMLX]),
        MacFitVerdict(
            subject: "recipe:\(MLXVideoModelCatalog.fastMetal5BRecipeID)", status: .meets, basis: .measuredOnThisMac,
            quality: "A quantization-aware distilled Wan 2.2 TI2V 5B, not ranked separately in blind votes. Inspected here: coherent scenes, stable geometry and lighting, smooth camera motion at 832×480 and 1280×704; the fast draft is slightly softer. The draft engine; LTX-2.3 stays the final and image-to-video route.",
            speed: "Measured on this Mac: a 5-second clip in 88 s at 832×480 (46 s as a fast draft) and 319 s at 1280×704 (134 s as a fast draft); 11.4 GiB peak. A new prompt adds about 37 s once.",
            assessed: "2026-10-12", sources: [evidenceFastVideo, "https://haoailab.com/blogs/fastmetal/"],
            note: "Text-to-video only. Apache-2.0."),
        MacFitVerdict(
            subject: "recipe:\(MLXVLMModelCatalog.qwen38RecipeID)", status: .meets, basis: .measuredOnThisMac,
            quality: "The local text and vision core. In a 14-prompt check on this Mac it gave accurate image descriptions, valid JSON and coherent answers to a 5,000-token prompt.",
            speed: "Measured on this Mac: about 18 tokens/s, and an answer about an image in about 10–12 s of model time.",
            assessed: "2026-09-20", sources: [evidenceMLX]),
        MacFitVerdict(
            subject: "recipe:\(SpeechModelCatalog.qwen3VoiceDesignRecipeID)", status: .meets, basis: .measuredOnThisMac,
            quality: "Qwen3-TTS Voice Design: the voice is described in plain words. Produced clear, natural speech with sentence pauses here; the requested South African accent is approximate, so listen before publishing.",
            speed: "Measured on this Mac: about 6 s of speech in 10 s including loading (real-time factor 1.0), 7.7 GB peak; a whole Voiceover node run on a 7.5 s video in 13 s.",
            assessed: "2026-10-12", sources: [evidenceFastVideo],
            note: "Voiceover only. Apache-2.0."),

        // MARK: expected to meet — route built, first run measures it
        MacFitVerdict(
            subject: "recipe:\(MediaModelCatalog.zImageTurboRecipeID)", status: .expectedToMeet, basis: .scaledFromMeasured,
            quality: "Text-to-image Elo 942 in independent blind votes, level with FLUX.2 Klein 9B (940). Artificial Analysis, July 2026 data.",
            speed: "Estimated 1.7–2.7 minutes for a 1024×1024 image (8 steps) and about 40 s at 512×512. Two estimates agree: one Apple Silicon report of about 105 s on an M4 Pro, and about 160 s scaled from this Mac's measured Klein 9B step time. Not measured here.",
            assessed: "2026-09-20",
            sources: [aaText, "https://huggingface.co/Tongyi-MAI/Z-Image-Turbo", "https://github.com/miroleon/z-image-turbo-benchmark", "https://huggingface.co/leejet/Z-Image-Turbo-GGUF", evidenceEngine],
            note: "Apache-2.0 licence, which allows commercial use. Text to image only. Your first image on this Mac is the measured trial."),

        // MARK: does not meet — recorded, never shown (MiniMax-H3 above is the final-quality exception)
        MacFitVerdict(
            subject: "recipe:\(MediaModelCatalog.kleinRecipeID)", status: .doesNotMeet, basis: .thirdPartyReport,
            quality: "Text-to-image Elo 864 (about 30th of the open-weight board) and editing Elo 950 (10th): far below the 9B, and reported as poor in use.",
            speed: "Measured: 17.2 s at 512×512. Fast, but speed does not offset the quality gap.",
            assessed: "2026-09-20", sources: [aaText, aaEdit, evidenceEngine],
            advice: "Lower quality than FLUX.2 Klein 9B, which does the same jobs well here.", replacedBy: MediaModelCatalog.klein9BRecipeID),
        MacFitVerdict(
            subject: "recipe:\(VideoCapabilityRegistry.wanT2VRecipeID)", status: .doesNotMeet, basis: .measuredOnThisMac,
            quality: "Soft, low-resolution clips with morphing and flicker at 320×192, as measured here.",
            speed: "89.3 s for a 1.1-second clip at 320×192 (about 79 s per video-second) at a fraction of the resolution of the LTX route.",
            assessed: "2026-09-20", sources: [evidenceVideo],
            advice: "Soft, flickering low-resolution clips. FastMetal 5B makes sharper 5-second drafts in about 1½ minutes.",
            replacedBy: MLXVideoModelCatalog.fastMetal5BRecipeID),
        MacFitVerdict(
            subject: "recipe:\(MediaModelCatalog.minimaxH3RecipeID)", status: .finalQuality, basis: .measuredOnThisMac,
            quality: "Highest-ranked open-weight video model in independent blind votes (Elo 1220).",
            speed: "Measured on this Mac from its own runs: 24–26 minutes for a 1.6-second 320×576 start/end clip and 18–32 minutes for image-to-video. Misses the 5-minute bar.",
            assessed: "2026-10-12", sources: [aaVideo, evidenceAudit],
            note: "The highest-quality start/end and image-to-video route here. Draft the shot with LTX-2.3 first, then render the final with this.",
            advice: "Final quality, about 25 min a clip: the highest-ranked open-weight video model. Draft with LTX-2.3 first.",
            wait: "about 25 min a clip", draftWith: MLXVideoModelCatalog.ltx23Q4RecipeID,
            outranksDraft: "Elo 1220 against LTX-2.3's 975 in the same independent text-to-video blind votes."),
        MacFitVerdict(
            subject: "recipe:\(MediaModelCatalog.juggernautXLRecipeID)", status: .alternativeLook, basis: .thirdPartyReport,
            quality: "SDXL family: ranks below FLUX.2 Klein 9B in blind text-to-image votes (Elo 677 against 940), but it is a photographic-look specialist, so its output differs rather than simply being worse.",
            speed: "Measured on this Mac from its own runs: about 72 s for 1024×576 at 35 steps. Fast enough.",
            assessed: "2026-10-12", sources: [aaText, evidenceAudit],
            note: "Pick it for a photographic SDXL look; FLUX.2 Klein 9B scores higher overall.",
            advice: "A photographic SDXL look. FLUX.2 Klein 9B scores higher overall, but this one looks different."),
        MacFitVerdict(
            subject: "recipe:\(MediaModelCatalog.wan22TI2VRecipeID)", status: .doesNotMeet, basis: .scaledFromMeasured,
            quality: "The same Wan 2.2 TI2V 5B base model as FastMetal 5B, without its distillation.",
            speed: "FastMetal 5B renders a 5-second 832×480 clip here in 88 s with 3 steps; this GGUF route needs about 20 steps on the slower engine with CPU offload, so several times slower. Not measured directly.",
            assessed: "2026-10-12", sources: [evidenceFastVideo, "docs/research/2026-09-20-speed-quality-standard.md"],
            advice: "Replaced by FastMetal 5B: the same base model, distilled to run in a fraction of the time here.",
            replacedBy: MLXVideoModelCatalog.fastMetal5BRecipeID),
        MacFitVerdict(
            subject: "suggest:qwen-image-2.1", status: .doesNotMeet, basis: .scaledFromMeasured,
            quality: "Not yet ranked in independent blind votes; the published examples look strong.",
            speed: "Estimated 4.5–16 minutes for a 1024×1024 image (40 steps, no few-step version): about 4.5 minutes if an MLX build matches an M5 Max's step time scaled to this Mac, about 16 minutes on the bundled engine scaled from measured Klein step times. Misses the 4-minute bar.",
            assessed: "2026-09-20", sources: ["https://github.com/filipstrand/mflux/pull/736", "https://huggingface.co/Qwen/Qwen-Image-2.1", evidenceEngine],
            note: "Qwen Research License: non-commercial. Revisit if a few-step version ships."),
        MacFitVerdict(
            subject: "suggest:minimax-h3", status: .doesNotMeet, basis: .thirdPartyReport,
            quality: "Highest-ranked open-weight video model in independent blind votes (Elo 1220).",
            speed: "About 10 minutes for a 3-second, 0.2-megapixel clip on an M1 Max (a builder's report), and 456 s for a 5-second 832×480 clip on an M4 Max. Misses the 5-minute bar on this Mac.",
            assessed: "2026-09-20", sources: [aaVideo, "docs/research/2026-09-minimax-h3-local-assessment.md"]),
        MacFitVerdict(
            subject: "suggest:flux2-dev", status: .doesNotMeet, basis: .scaledFromMeasured,
            quality: "Top open-weight image quality (Elo 1000 for both text-to-image and editing).",
            speed: "A 32-billion-parameter model: an estimated tens of minutes per 1024×1024 image on this Mac. Misses the 4-minute bar.",
            assessed: "2026-09-20", sources: [aaText, aaEdit, evidenceEngine]),
    ]

    /// Models that meet the bar but have no GenStudio route. Z-Image Turbo graduated to a recipe on 2026-10-14.
    static let suggestions: [MacSuggestion] = []

    private static let verdictIndex: [String: MacFitVerdict] = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.subject, $0) })

    static func verdict(forSubject subject: String) -> MacFitVerdict? { verdictIndex[subject] }

    /// The final-quality verdict for a recipe, or nil for a fast or unassessed one. An update copy inherits its original's.
    static func finalQuality(recipeID: String) -> MacFitVerdict? {
        let id = recipeID.range(of: "-v-").map { String(recipeID[..<$0.lowerBound]) } ?? recipeID
        guard let verdict = verdictIndex["recipe:\(id)"], verdict.status == .finalQuality else { return nil }
        return verdict
    }

    /// Suggestions that meet the bar, as radar entries. They can never be installed from here.
    static func suggestionEntries() -> [RadarEntry] {
        suggestions.compactMap { suggestion in
            guard let verdict = verdictIndex["suggest:\(suggestion.key)"], verdict.suggestable else { return nil }
            return RadarEntry(
                id: "suggest:\(suggestion.key)", familyID: "suggested", category: suggestion.category, tier: .watch,
                title: suggestion.title, generation: nil, recipeID: nil, repository: suggestion.repository, released: nil, sizeBytes: nil,
                fit: RadarFit(level: .unknown, label: verdict.basis == .measuredOnThisMac ? "Measured" : "Estimated, not yet measured here", detail: verdict.speed),
                installed: false, facts: suggestion.routeNote, gated: false,
                buildRepositories: suggestion.builds.map { HubRepo(id: $0, createdAt: nil, downloads: nil, likes: nil, pipelineTag: nil, gated: false) },
                purpose: nil, verdict: verdict)
        }
    }

    /// The only path from radar results to the screen. Fail closed: no verdict, no entry.
    static func present(_ reports: [RadarFamilyReport]) -> RadarPresentation {
        var newerWaiting = 0
        var families: [RadarFamilyReport] = []
        for report in reports {
            var shown: [RadarEntry] = []
            for entry in report.entries {
                if let verdict = verdictIndex[entry.id], verdict.suggestable {
                    var assessed = entry; assessed.verdict = verdict; shown.append(assessed)
                } else if entry.tier == .watch {
                    newerWaiting += 1   // counted, never named
                }
            }
            guard !shown.isEmpty else { continue }
            // The family status line would announce unassessed newer generations, so it is dropped.
            families.append(RadarFamilyReport(id: report.id, title: report.title, category: report.category, runsUpTo: report.runsUpTo,
                                              newestUpstream: nil, checked: report.checked, status: "", failure: report.failure, entries: shown))
        }
        let suggested = suggestionEntries()
        for category in RadarCategory.allCases {
            let entries = suggested.filter { $0.category == category }
            guard !entries.isEmpty else { continue }
            families.append(RadarFamilyReport(id: "suggested-\(category.rawValue)", title: "Also a strong fit", category: category, runsUpTo: nil,
                                              newestUpstream: nil, checked: false, status: "Not built into GenStudio yet", failure: nil, entries: entries))
        }
        return RadarPresentation(families: families, unassessedNewerReleases: newerWaiting)
    }
}
