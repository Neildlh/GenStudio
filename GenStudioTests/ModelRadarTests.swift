import XCTest
@testable import GenStudio

final class ModelRadarTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private let gb: Int64 = 1_000_000_000

    private var m1Max: HardwareProfile {
        HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 * gib, osVersion: "Version 27.0 (Build 27A5001a)",
                        freeDiskBytes: 400 * gb, totalDiskBytes: 994 * gb, gpuWorkingSetBytes: 48 * gib,
                        performanceCores: 8, efficiencyCores: 2, gpuCores: 32)
    }
    private func date(_ day: String) -> Date { ISO8601DateFormatter().date(from: day + "T00:00:00Z")! }
    private func repo(_ id: String, _ day: String, downloads: Int = 0, gated: Bool = false) -> HubRepo {
        HubRepo(id: id, createdAt: date(day), downloads: downloads, likes: 0, pipelineTag: nil, gated: gated)
    }
    private func supported() -> ModelCompatibility.Assessment {
        .init(state: .supported, eligible: true, label: "Supported on this Mac", detail: "Fits.")
    }

    /// The real recipe catalogue and the real compatibility rules for stable-diffusion.cpp recipes.
    /// MLX recipes depend on whether a managed runtime is installed on the machine running the
    /// tests, so those are answered by a fixed stand-in.
    private func inputs(proven: Set<String> = [], installed: Set<String> = [], hardware: HardwareProfile? = nil) -> RadarInputs {
        let hardware = hardware ?? m1Max
        return RadarInputs(
            recipe: { id in ModelCatalog.recipes.first { $0.id == id } },
            assess: { recipe in
                recipe.engineID.hasPrefix("mlx") ? self.supported() : ModelCompatibility.assess(recipe: recipe, hardware: hardware)
            },
            proven: { proven.contains($0.id) },
            installed: installed, hardware: hardware)
    }

    private func snapshot(_ families: [FamilyLive]) -> RadarSnapshot {
        RadarSnapshot(fetchedAt: date("2026-09-18"), families: families, summary: nil, blurbs: [:], writer: nil)
    }
    private var wanLive: FamilyLive {
        FamilyLive(familyID: "wan", newest: NewestUpstream(generation: RadarGeneration("2.2")!, repos: [repo("Wan-AI/Wan2.2-Animate-2-14B", "2026-07-14")]),
                   builds: [], sizes: [:], error: nil)
    }
    private var ltxLive: FamilyLive {
        FamilyLive(familyID: "ltx", newest: NewestUpstream(generation: RadarGeneration("2.5")!, repos: [repo("Lightricks/LTX-2.5-Pre-Trained", "2026-08-10")]),
                   builds: [repo("dgrauet/ltx-2.5-mlx-q4", "2026-08-27")], sizes: ["dgrauet/ltx-2.5-mlx-q4": 13 * gb], error: nil)
    }
    private func report(_ id: String, _ reports: [RadarFamilyReport]) throws -> RadarFamilyReport {
        try XCTUnwrap(reports.first { $0.id == id }, "no report for \(id)")
    }
    private func entry(_ recipeID: String, in report: RadarFamilyReport) -> RadarEntry? {
        report.entries.first { $0.recipeID == recipeID }
    }

    // MARK: tiers

    func testWan22IsReadyToTestBecauseARouteExistsButHasNoDecodedProof() throws {
        let reports = ModelRadar.report(snapshot: snapshot([wanLive]), inputs: inputs(proven: [VideoCapabilityRegistry.wanT2VRecipeID]))
        let wan = try report("wan", reports)
        let wan22 = try XCTUnwrap(entry(MediaModelCatalog.wan22TI2VRecipeID, in: wan))
        XCTAssertEqual(wan22.tier, .readyToTest)
        XCTAssertEqual(wan22.generation?.text, "2.2")
        XCTAssertEqual(entry(VideoCapabilityRegistry.wanT2VRecipeID, in: wan)?.tier, .proven)
    }

    func testWanIsUpToDateSoItHasNoWatchEntry() throws {
        let wan = try report("wan", ModelRadar.report(snapshot: snapshot([wanLive]), inputs: inputs()))
        XCTAssertFalse(wan.entries.contains { $0.tier == .watch })
        XCTAssertEqual(wan.runsUpTo?.text, "2.2")
        XCTAssertEqual(wan.status, "GenStudio runs the newest generation, Wan 2.2.")
    }

    func testEveryRouteTitleNamesItsGenerationSoTheLadderIsReadable() throws {
        // The catalogue's friendly title for the Wan 2.1 route is just "Wan · Video Generation".
        // Beside "Wan 2.2 TI2V 5B" that hides which generation it is.
        // Unversioned "Also a strong fit" routes have no ladder, so only versioned families are checked.
        for family in ModelRadar.report(snapshot: snapshot([wanLive, ltxLive]), standalone: [], inputs: inputs()) {
            for entry in family.entries where entry.recipeID != nil {
                let generation = try XCTUnwrap(entry.generation).text
                XCTAssertTrue(entry.title.contains(generation), "\"\(entry.title)\" does not name generation \(generation)")
            }
        }
    }

    /// The catalogue's fallback purpose for a video recipe without a MediaModelCatalog profile says
    /// "GenStudio has no verified adapter for this package". LTX-2.3 MLX has no such profile yet has a
    /// working adapter, so passing that text on would contradict the route the entry itself represents.
    func testNoRouteEntryCarriesAPurposeThatContradictsHavingARoute() throws {
        let reports = ModelRadar.report(snapshot: snapshot([wanLive, ltxLive]), inputs: inputs())
        for entry in reports.flatMap(\.entries) where entry.recipeID != nil {
            XCTAssertFalse(entry.purpose?.localizedCaseInsensitiveContains("no verified adapter") ?? false, "\(entry.title): \(entry.purpose ?? "")")
        }
        let ltx = try report("ltx", reports)
        XCTAssertNil(try XCTUnwrap(entry(MLXVideoModelCatalog.ltx23Q4RecipeID, in: ltx)).purpose, "no honest purpose text exists for it yet")
        let wan = try report("wan", reports)
        XCTAssertNotNil(try XCTUnwrap(entry(VideoCapabilityRegistry.wanT2VRecipeID, in: wan)).purpose, "a recipe with a real description keeps it")
    }

    func testWatchEntriesCarryNoPurposeBecauseTheOnlyDescriptionWouldBePublisherText() throws {
        let ltx = try report("ltx", ModelRadar.report(snapshot: snapshot([ltxLive]), inputs: inputs()))
        XCTAssertNil(try XCTUnwrap(ltx.entries.first { $0.tier == .watch }).purpose)
    }

    func testFitLineDescribesFitNotRouteStatus() throws {
        let wan = try report("wan", ModelRadar.report(snapshot: snapshot([wanLive]), inputs: inputs()))
        let wan22 = try XCTUnwrap(entry(MediaModelCatalog.wan22TI2VRecipeID, in: wan))
        XCTAssertEqual(wan22.fit.level, .comfortable)
        XCTAssertEqual(wan22.fit.label, "Fits this Mac", "route status (\"Adapter available · not yet verified\") belongs to the tier chip, not the fit line")
        XCTAssertFalse(wan22.fit.detail.isEmpty)
    }

    func testEntriesAreOrderedNewestGenerationFirstThenByTier() throws {
        let wan = try report("wan", ModelRadar.report(snapshot: snapshot([wanLive]), inputs: inputs(proven: [VideoCapabilityRegistry.wanT2VRecipeID])))
        let generations = wan.entries.compactMap(\.generation)
        XCTAssertEqual(generations, generations.sorted(by: >), "newest generation first")
    }

    func testWithdrawnLTX25RouteIsNeverListedAsReady() throws {
        let ltx = try report("ltx", ModelRadar.report(snapshot: snapshot([ltxLive]), inputs: inputs()))
        XCTAssertNil(entry(VideoCapabilityRegistry.ltx25RecipeID, in: ltx), "the disabled stable-diffusion.cpp route must not appear")
        XCTAssertEqual(ltx.runsUpTo?.text, "2.3", "the withdrawn 2.5 route must not count as coverage")
    }

    func testLTXGetsAWatchEntryForTheNewerUpstreamGeneration() throws {
        let ltx = try report("ltx", ModelRadar.report(snapshot: snapshot([ltxLive]), inputs: inputs()))
        let watch = try XCTUnwrap(ltx.entries.first { $0.tier == .watch })
        XCTAssertEqual(watch.generation?.text, "2.5")
        XCTAssertEqual(watch.id, "watch:ltx:2.5")
        XCTAssertNil(watch.recipeID, "a Watch entry is never installable")
        XCTAssertEqual(watch.repository, "Lightricks/LTX-2.5-Pre-Trained")
        XCTAssertEqual(watch.buildRepositories.map(\.id), ["dgrauet/ltx-2.5-mlx-q4"])
        XCTAssertEqual(ltx.status, "Newest upstream: LTX 2.5 · GenStudio runs up to 2.3.")
        XCTAssertTrue(watch.facts.contains("Apple Silicon"), "the built-in sentence should mention that MLX builds exist")
    }

    func testAFamilyWithNoRouteAtAllSaysSo() throws {
        let hardware = HardwareProfile(chip: "Intel Core i9", memoryBytes: 16 * gib, osVersion: "Version 27.0", freeDiskBytes: 100 * gb)
        let nothing = RadarInputs(recipe: { _ in nil }, assess: { _ in fatalError("no recipe, nothing to assess") },
                                  proven: { _ in false }, installed: [], hardware: hardware)
        let ltx = try report("ltx", ModelRadar.report(snapshot: snapshot([ltxLive]), inputs: nothing))
        XCTAssertNil(ltx.runsUpTo)
        XCTAssertEqual(ltx.status, "Newest upstream: LTX 2.5 · GenStudio has no route for this family yet.")
        XCTAssertEqual(ltx.entries.filter { $0.tier == .watch }.count, 1)
    }

    func testTiersUpdateWithoutRefetchingWhenAModelBecomesProven() throws {
        let live = snapshot([ltxLive])
        let before = try report("ltx", ModelRadar.report(snapshot: live, inputs: inputs()))
        XCTAssertEqual(entry(MLXVideoModelCatalog.ltx23Q4RecipeID, in: before)?.tier, .readyToTest)
        let after = try report("ltx", ModelRadar.report(snapshot: live, inputs: inputs(proven: [MLXVideoModelCatalog.ltx23Q4RecipeID], installed: [MLXVideoModelCatalog.ltx23Q4RecipeID])))
        let entry = try XCTUnwrap(self.entry(MLXVideoModelCatalog.ltx23Q4RecipeID, in: after))
        XCTAssertEqual(entry.tier, .proven)
        XCTAssertTrue(entry.installed)
    }

    // MARK: before and around a check

    func testWithoutASnapshotTheLocalTiersStillShowAndNothingIsClaimedAboutUpstream() throws {
        let reports = ModelRadar.report(snapshot: nil, inputs: inputs())
        let wan = try report("wan", reports)
        XCTAssertFalse(wan.entries.isEmpty)
        XCTAssertFalse(wan.checked)
        XCTAssertEqual(wan.status, "Not checked yet · GenStudio runs up to Wan 2.2.")
        XCTAssertTrue(reports.flatMap(\.entries).allSatisfy { $0.tier != .watch }, "no Watch entry without live data")
    }

    func testOneFailedFamilyDoesNotAffectTheOthers() throws {
        let failed = FamilyLive(familyID: "wan", newest: nil, builds: [], sizes: [:], error: "The Hugging Face request was rate-limited (HTTP 429).")
        let reports = ModelRadar.report(snapshot: snapshot([failed, ltxLive]), inputs: inputs())
        let wan = try report("wan", reports)
        XCTAssertEqual(wan.failure, "The Hugging Face request was rate-limited (HTTP 429).")
        XCTAssertFalse(wan.entries.isEmpty, "local routes still listed")
        XCTAssertTrue(try report("ltx", reports).entries.contains { $0.tier == .watch })
    }

    func testFamilyReportsAreReturnedInWatchlistOrderAndGroupedByCategory() {
        let reports = ModelRadar.report(snapshot: nil, inputs: inputs())
        XCTAssertEqual(reports.map(\.id), ModelWatchlist.families.map(\.id) + ["picks-image"], "versioned families first, then unversioned picks")
        XCTAssertEqual(Set(reports.map(\.category)), [.video, .image, .textVision])
    }

    // MARK: fit for Watch entries

    func testWatchFitThresholdsFollowThisMacsMemory() {
        // M1 Max / 64 GB: comfortable up to 32 GiB, usable up to 48 GiB.
        XCTAssertEqual(ModelRadar.watchFit(bytes: 13 * gb, hardware: m1Max).level, .comfortable)
        XCTAssertEqual(ModelRadar.watchFit(bytes: 40 * gb, hardware: m1Max).level, .demanding)
        XCTAssertEqual(ModelRadar.watchFit(bytes: 60 * gb, hardware: m1Max).level, .exceeds)
    }

    func testWatchFitIsUnknownRatherThanOptimisticWhenSizeOrMachineIsMissing() {
        XCTAssertEqual(ModelRadar.watchFit(bytes: nil, hardware: m1Max).level, .unknown)
        XCTAssertEqual(ModelRadar.watchFit(bytes: 0, hardware: m1Max).level, .unknown)
        XCTAssertEqual(ModelRadar.watchFit(bytes: 13 * gb, hardware: nil).level, .unknown)
    }

    func testWatchFitExplainsItIsPublishedSizeNotAnInstallPlan() {
        let fit = ModelRadar.watchFit(bytes: 60 * gb, hardware: m1Max)
        XCTAssertTrue(fit.detail.contains("published"), fit.detail)
        XCTAssertTrue(fit.detail.contains("smaller"), "should point at quantised builds: \(fit.detail)")
    }

    func testWatchEntryFitUsesTheSmallestSurfacedBuildNotTheHugeUpstreamRepo() throws {
        var live = ltxLive
        live = FamilyLive(familyID: "ltx", newest: live.newest, builds: live.builds,
                          sizes: ["Lightricks/LTX-2.5-Pre-Trained": 90 * gb, "dgrauet/ltx-2.5-mlx-q4": 13 * gb], error: nil)
        let ltx = try report("ltx", ModelRadar.report(snapshot: snapshot([live]), inputs: inputs()))
        XCTAssertEqual(try XCTUnwrap(ltx.entries.first { $0.tier == .watch }).fit.level, .comfortable)
    }

    // MARK: notes are only valid for the models they were written about

    private func notedSnapshot(writtenFor: [String]?) -> RadarSnapshot {
        var s = snapshot([wanLive])
        s.summary = "Try Klein 9B first."; s.blurbs = ["recipe:a": "Note A."]; s.writer = "Apple Intelligence"; s.writtenFor = writtenFor
        return s
    }

    func testNotesAreShownOnlyWhenWrittenForExactlyTheModelsNowVisible() throws {
        let notes = try XCTUnwrap(notedSnapshot(writtenFor: ["recipe:b", "recipe:a"]).notes(forVisible: ["recipe:a", "recipe:b"]))
        XCTAssertEqual(notes.summary, "Try Klein 9B first.")
        XCTAssertEqual(notes.blurbs["recipe:a"], "Note A.")
        XCTAssertEqual(notes.writer, "Apple Intelligence")
    }

    func testNotesFromBeforeTheBarExistedAreNotShown() {
        XCTAssertNil(notedSnapshot(writtenFor: nil).notes(forVisible: ["recipe:a"]), "a legacy cache has no record of who it was written about")
    }

    func testNotesAreDroppedWhenAModelIsHiddenOrNewlyShown() {
        XCTAssertNil(notedSnapshot(writtenFor: ["recipe:a", "recipe:gone"]).notes(forVisible: ["recipe:a"]), "a model it named is no longer shown")
        XCTAssertNil(notedSnapshot(writtenFor: ["recipe:a"]).notes(forVisible: ["recipe:a", "recipe:new"]), "a model it never saw is now shown")
    }

    func testASnapshotWithoutNotesYieldsNone() {
        XCTAssertNil(snapshot([wanLive]).notes(forVisible: []))
    }

    // MARK: persistence

    func testSnapshotSurvivesAJSONRoundTrip() throws {
        var original = snapshot([wanLive, ltxLive])
        original.summary = "Try LTX 2.3 first."
        original.blurbs = ["watch:ltx:2.5": "MLX builds exist."]
        original.writer = "Qwen 3.8 27B"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(RadarSnapshot.self, from: encoder.encode(original)), original)
    }
}
