import XCTest
@testable import GenStudio

/// The owner's rule: the suggestion system only mentions and works with models that meet a speed AND quality
/// bar on this Mac. Anything unassessed or failing is never shown, and never named.
final class MacFitStandardTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private var m1Max: HardwareProfile {
        HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 * gib, osVersion: "Version 27.0", freeDiskBytes: 400_000_000_000,
                        totalDiskBytes: 994_000_000_000, gpuWorkingSetBytes: 52 * gib, performanceCores: 8, efficiencyCores: 2, gpuCores: 32)
    }
    private func supported() -> ModelCompatibility.Assessment { .init(state: .supported, eligible: true, label: "Supported on this Mac", detail: "Fits.") }
    private func inputs(proven: Set<String> = []) -> RadarInputs {
        let hardware = m1Max
        return RadarInputs(recipe: { id in ModelCatalog.recipes.first { $0.id == id } },
                           assess: { $0.engineID.hasPrefix("mlx") ? self.supported() : ModelCompatibility.assess(recipe: $0, hardware: hardware) },
                           proven: { proven.contains($0.id) }, installed: [], hardware: hardware)
    }
    private func repo(_ id: String, _ day: String) -> HubRepo {
        HubRepo(id: id, createdAt: ISO8601DateFormatter().date(from: day + "T00:00:00Z"), downloads: 0, likes: 0, pipelineTag: nil, gated: false)
    }
    /// Live data as it was on 2026-09-20: newest LTX upstream is 2.5, newer than GenStudio's 2.3.
    private var snapshot: RadarSnapshot {
        RadarSnapshot(fetchedAt: Date(), families: [
            FamilyLive(familyID: "ltx", newest: NewestUpstream(generation: RadarGeneration("2.5")!, repos: [repo("Lightricks/LTX-2.5-Pre-Trained", "2026-08-10")]),
                       builds: [repo("mlx-community/ltx-2.5-mlx-q8", "2026-08-21")], sizes: ["mlx-community/ltx-2.5-mlx-q8": 23_900_000_000], error: nil),
            FamilyLive(familyID: "wan", newest: NewestUpstream(generation: RadarGeneration("2.2")!, repos: [repo("Wan-AI/Wan2.2-Animate-2-14B", "2026-07-14")]),
                       builds: [], sizes: [:], error: nil),
        ], summary: nil, blurbs: [:], writer: nil)
    }
    private func present(_ snap: RadarSnapshot? = nil) -> RadarPresentation {
        MacFitStandard.present(ModelRadar.report(snapshot: snap ?? snapshot, inputs: inputs()))
    }
    private var shownEntries: [RadarEntry] { present().families.flatMap(\.entries) }
    private func ids(_ p: RadarPresentation) -> Set<String> { Set(p.families.flatMap(\.entries).map(\.id)) }

    // MARK: who is shown

    func testOnlyAssessedModelsThatMeetTheBarAreShown() {
        let shown = ids(present())
        XCTAssertTrue(shown.contains("recipe:\(MediaModelCatalog.klein9BRecipeID)"), "Klein 9B meets the bar")
        XCTAssertTrue(shown.contains("recipe:\(MLXVideoModelCatalog.ltx23Q4RecipeID)"), "LTX-2.3 meets the bar")
        XCTAssertTrue(shown.contains("recipe:\(MLXVLMModelCatalog.qwen38RecipeID)"), "the local text+vision core meets the bar")
    }

    func testModelsThatFailTheBarAreNeverShown() {
        let shown = ids(present())
        XCTAssertFalse(shown.contains("recipe:\(MediaModelCatalog.kleinRecipeID)"), "Klein 4B fails on quality")
        XCTAssertFalse(shown.contains("recipe:\(VideoCapabilityRegistry.wanT2VRecipeID)"), "Wan 2.1 1.3B fails on quality")
    }

    func testUnassessedModelsFailClosed() {
        // Wan 2.1 FLF2V and Wan 2.2 5B have routes but no assessment: not shown.
        let shown = ids(present())
        XCTAssertFalse(shown.contains("recipe:\(MediaModelCatalog.wan22TI2VRecipeID)"))
        XCTAssertFalse(shown.contains("recipe:\(MediaModelCatalog.wan21FLFRecipeID)"))
    }

    func testAFamilyWithNothingToShowDisappearsEntirely() {
        XCTAssertFalse(present().families.contains { $0.id == "wan" })
    }

    func testANewerUpstreamReleaseWithoutAnAssessmentIsHiddenAndOnlyCounted() {
        let p = present()
        XCTAssertFalse(p.families.flatMap(\.entries).contains { $0.tier == .watch && $0.id.hasPrefix("watch:") })
        XCTAssertEqual(p.unassessedNewerReleases, 1, "LTX 2.5 is counted; Wan has no newer generation so it adds nothing")
    }

    func testHiddenModelsAreNeverNamedAnywhereInWhatIsShown() {
        let p = present()
        var text: [String] = []
        for f in p.families {
            text += [f.title, f.status, f.failure ?? ""]
            for e in f.entries { text += [e.title, e.facts, e.purpose ?? "", e.repository ?? "", e.verdict?.quality ?? "", e.verdict?.speed ?? "", e.verdict?.note ?? ""] }
        }
        let joined = text.joined(separator: " ").lowercased()
        for hidden in ["ltx 2.5", "ltx-2.5", "klein 4b", "wan 2", "wan2", "qwen-image", "qwen image", "minimax", "h3", "flux.2 dev", "flux.2 [dev]", "ideogram"] {
            XCTAssertFalse(joined.contains(hidden), "\"\(hidden)\" must not be mentioned")
        }
    }

    func testStatusLinesDoNotAnnounceUnassessedNewerGenerations() {
        for family in present().families {
            XCTAssertFalse(family.status.contains("Newest upstream"), family.status)
        }
    }

    // MARK: suggestions for models GenStudio cannot run yet

    func testZImageTurboGraduatedFromSuggestionToAnInstallableRoute() throws {
        XCTAssertFalse(ids(present()).contains("suggest:z-image-turbo"), "it is no longer \"not built into GenStudio\"")
        let z = try XCTUnwrap(shownEntries.first { $0.id == "recipe:\(MediaModelCatalog.zImageTurboRecipeID)" })
        XCTAssertEqual(z.tier, .readyToTest, "built, but its first run on this Mac is the test")
        XCTAssertEqual(z.recipeID, MediaModelCatalog.zImageTurboRecipeID, "a route entry carries the recipe its Install button installs")
        XCTAssertEqual(z.verdict?.status, .expectedToMeet)
        XCTAssertEqual(z.category, .image)
    }

    func testSuggestionLinksAreWellFormedHubRepositories() {
        for entry in MacFitStandard.suggestionEntries() {
            for repo in [entry.repository].compactMap({ $0 }) + entry.buildRepositories.map(\.id) {
                XCTAssertEqual(try? ModelLibrary.parseHubLink(repo), repo, "\(entry.id): \(repo)")
            }
        }
    }

    func testRejectedSuggestionsAreNotShown() {
        let shown = ids(present())
        XCTAssertFalse(shown.contains("suggest:qwen-image-2.1"))
        XCTAssertFalse(shown.contains("suggest:minimax-h3"))
        XCTAssertFalse(shown.contains("suggest:flux2-dev"))
    }

    // MARK: every visible claim carries its evidence

    func testEveryShownEntryCarriesQualityAndSpeedEvidence() {
        for entry in shownEntries {
            let v = entry.verdict
            XCTAssertNotNil(v, "\(entry.id) is shown without a verdict")
            XCTAssertFalse((v?.quality ?? "").isEmpty, "\(entry.id) quality")
            XCTAssertFalse((v?.speed ?? "").isEmpty, "\(entry.id) speed")
            XCTAssertTrue([.meets, .expectedToMeet, .alternativeLook, .finalQuality].contains(v?.status), "\(entry.id)")
        }
    }

    func testMeasuredClaimsAreMeasuredAndEstimatesAreSourced() {
        for verdict in MacFitStandard.verdicts {
            switch verdict.status {
            case .meets: XCTAssertEqual(verdict.basis, .measuredOnThisMac, "\(verdict.subject): 'meets' requires a measurement on this Mac")
            case .expectedToMeet:
                XCTAssertNotEqual(verdict.basis, .measuredOnThisMac, "\(verdict.subject)")
                XCTAssertFalse(verdict.sources.isEmpty, "\(verdict.subject): an estimate must cite its sources")
            case .finalQuality: XCTAssertFalse(verdict.sources.isEmpty || verdict.wait == nil, "\(verdict.subject)")
            case .alternativeLook: XCTAssertFalse(verdict.sources.isEmpty, "\(verdict.subject)")
            case .doesNotMeet: XCTAssertFalse(verdict.quality.isEmpty || verdict.speed.isEmpty, "\(verdict.subject) needs its reason recorded")
            }
            XCTAssertNotNil(ISO8601DateFormatter().date(from: verdict.assessed + "T00:00:00Z"), "\(verdict.subject) date")
        }
    }

    func testVerdictSubjectsAreUniqueAndRecipeSubjectsExist() {
        let subjects = MacFitStandard.verdicts.map(\.subject)
        XCTAssertEqual(subjects.count, Set(subjects).count)
        let known = Set(ModelCatalog.recipes.map(\.id))
        for s in subjects where s.hasPrefix("recipe:") { XCTAssertTrue(known.contains(String(s.dropFirst(7))), s) }
    }

    func testTheDecisionsAreRecordedSoTheyAreNotReLitigated() throws {
        func verdict(_ s: String) throws -> MacFitVerdict { try XCTUnwrap(MacFitStandard.verdict(forSubject: s), s) }
        XCTAssertEqual(try verdict("recipe:\(MediaModelCatalog.kleinRecipeID)").status, .doesNotMeet)
        XCTAssertEqual(try verdict("suggest:qwen-image-2.1").status, .doesNotMeet)
        XCTAssertEqual(try verdict("suggest:minimax-h3").status, .doesNotMeet)
        XCTAssertTrue(try verdict("suggest:qwen-image-2.1").speed.lowercased().contains("minutes"))
    }

    func testTheBarStatesBothSpeedAndQualityInNumbers() {
        let bar = MacFitStandard.barSummary
        XCTAssertTrue(bar.localizedCaseInsensitiveContains("quality"))
        XCTAssertTrue(bar.localizedCaseInsensitiveContains("speed"))
        XCTAssertTrue(bar.contains("60 s") && bar.contains("4 min") && bar.contains("5 min"), bar)
    }

    // MARK: robustness

    func testPresentingWithNoCheckStillShowsTheAssessedRoutes() {
        let p = MacFitStandard.present(ModelRadar.report(snapshot: nil, inputs: inputs()))
        XCTAssertFalse(p.families.isEmpty)
        XCTAssertEqual(p.unassessedNewerReleases, 0)
    }

    func testPresentationIsCheapEnoughToRunOnEveryRender() {
        let reports = ModelRadar.report(snapshot: snapshot, inputs: inputs())
        let start = Date()
        for _ in 0..<500 { _ = MacFitStandard.present(reports) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "500 presentations must take under a second")
    }
}
