import XCTest
@testable import GenStudio

final class ModelWatchlistTests: XCTestCase {
    private func family(_ id: String) throws -> WatchFamily {
        try XCTUnwrap(ModelWatchlist.families.first { $0.id == id }, "no watchlist family \(id)")
    }
    private func repo(_ id: String, _ day: String, downloads: Int = 0) -> HubRepo {
        HubRepo(id: id, createdAt: ISO8601DateFormatter().date(from: day + "T00:00:00Z"), downloads: downloads, likes: 0, pipelineTag: nil, gated: false)
    }

    // MARK: generations compare numerically

    func testGenerationsCompareNumericallyPerComponentNotAsText() throws {
        XCTAssertTrue(try XCTUnwrap(RadarGeneration("2.10")) > XCTUnwrap(RadarGeneration("2.9")))
        XCTAssertTrue(try XCTUnwrap(RadarGeneration("2.2")) > XCTUnwrap(RadarGeneration("2")))
        XCTAssertEqual(try XCTUnwrap(RadarGeneration("2")), try XCTUnwrap(RadarGeneration("2.0")))
        XCTAssertEqual(RadarGeneration("3.8")?.text, "3.8")
        XCTAssertNil(RadarGeneration("beta"))
        XCTAssertNil(RadarGeneration(""))
    }

    // MARK: parsing repository names (real Hub names)

    func testBaseRepositoriesYieldTheirGeneration() throws {
        XCTAssertEqual(try family("wan").generation(ofRepository: "Wan-AI/Wan2.2-TI2V-5B")?.text, "2.2")
        XCTAssertEqual(try family("ltx").generation(ofRepository: "Lightricks/LTX-2.5-Pre-Trained")?.text, "2.5")
        XCTAssertEqual(try family("flux").generation(ofRepository: "black-forest-labs/FLUX.2-klein-4B")?.text, "2")
        XCTAssertEqual(try family("qwen").generation(ofRepository: "Qwen/Qwen3.8-27B")?.text, "3.8")
    }

    func testAdaptersAndFormatVariantsAreNotBaseModels() throws {
        XCTAssertNil(try family("ltx").generation(ofRepository: "Lightricks/LTX-2.5-22b-IC-LoRA-Deblur"))
        XCTAssertNil(try family("ltx").generation(ofRepository: "Lightricks/LTX-2.3-22b-IC-LoRA-Relight"))
        XCTAssertNil(try family("flux").generation(ofRepository: "black-forest-labs/FLUX.2-klein-4b-fp8"))
        XCTAssertNil(try family("flux").generation(ofRepository: "black-forest-labs/FLUX.2-klein-9b-kv"))
        XCTAssertNil(try family("wan").generation(ofRepository: "Wan-AI/Wan2.2-T2V-A14B-Diffusers"))
        XCTAssertNil(try family("qwen").generation(ofRepository: "Qwen/Qwen3.8-27B-FP8"))
    }

    func testRepositoriesWithoutAGenerationAreIgnored() throws {
        XCTAssertNil(try family("wan").generation(ofRepository: "Wan-AI/Wan-Dancer-14B"))
        XCTAssertNil(try family("qwen").generation(ofRepository: "Qwen/Qwen-Drive-1.0-4B"))
        XCTAssertNil(try family("qwen").generation(ofRepository: "Qwen/Qwen3-ASR-0.6B-hf"))
    }

    func testARepositoryFromAnotherPublisherIsNeverAccepted() throws {
        XCTAssertNil(try family("wan").generation(ofRepository: "someone-else/Wan2.2-TI2V-5B"))
    }

    // MARK: picking the newest generation out of a noisy feed

    /// Lightricks' twelve newest repositories on 2026-09-18: eleven adapters and one base model.
    private var lightricksFeed: [HubRepo] { [
        repo("Lightricks/LTX-2.5-22b-LoRA-Slow-Motion-Control", "2026-09-15"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Ingredients", "2026-09-10"),
        repo("Lightricks/LTX-2.5-22b-LoRA-Cinemagraph", "2026-09-10"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Colorization", "2026-09-10"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Decompression", "2026-09-10"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Deblur", "2026-09-09"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Clean-Plate", "2026-09-09"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Water-Simulation", "2026-09-09"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Day-To-Night", "2026-09-08"),
        repo("Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler", "2026-08-11"),
        repo("Lightricks/LTX-2.5-Pre-Trained", "2026-08-10", downloads: 371),
        repo("Lightricks/LTX-2.3-22b-IC-LoRA-Relight", "2026-07-27"),
    ] }

    func testLoRAFloodDoesNotHideTheNewestBaseModel() throws {
        let newest = try XCTUnwrap(family("ltx").newest(in: lightricksFeed))
        XCTAssertEqual(newest.generation.text, "2.5")
        XCTAssertEqual(newest.repos.map(\.id), ["Lightricks/LTX-2.5-Pre-Trained"])
    }

    func testOnlyTheHighestGenerationIsReportedAndNewestFirst() throws {
        let feed = [
            repo("Wan-AI/Wan2.2-Animate-2-14B", "2026-07-14"),
            repo("Wan-AI/Wan2.2-Animate-2-14B-Distilled-Diffusers", "2026-08-06"),
            repo("Wan-AI/Wan-Dancer-14B", "2026-07-10"),
            repo("Wan-AI/Wan2.2-Animate-14B", "2025-09-11"),
            repo("Wan-AI/Wan2.2-S2V-14B", "2025-08-25"),
            repo("Wan-AI/Wan2.2-I2V-A14B", "2025-07-24"),
            repo("Wan-AI/Wan2.1-T2V-14B", "2025-02-25"),
        ]
        let newest = try XCTUnwrap(family("wan").newest(in: feed))
        XCTAssertEqual(newest.generation.text, "2.2")
        XCTAssertEqual(newest.repos.map(\.id), ["Wan-AI/Wan2.2-Animate-2-14B", "Wan-AI/Wan2.2-Animate-14B", "Wan-AI/Wan2.2-S2V-14B"],
                       "at most three, newest first, no 2.1 repository, no Diffusers duplicate")
    }

    func testNoBaseRepositoriesMeansNothingIsReported() throws {
        XCTAssertNil(try family("ltx").newest(in: [repo("Lightricks/LTX-2.5-22b-LoRA-Cinemagraph", "2026-09-10")]))
        XCTAssertNil(try family("ltx").newest(in: []))
    }

    // MARK: community Apple-Silicon builds

    func testAppleSiliconBuildsMustBelongToTheNewestGenerationAndBeMLX() throws {
        let hits = [
            repo("dgrauet/ltx-2.5-mlx-q4", "2026-08-27", downloads: 0),
            repo("Karam98/ltx-2.5-mlx-q4", "2026-09-02", downloads: 188),
            repo("dgrauet/ltx-2.3-mlx-q4", "2026-05-01", downloads: 9000),      // older generation
            repo("someone/ltx-2.5-gguf", "2026-09-01", downloads: 50),          // not MLX
            repo("Vayden/LTX-2.5-MLX-Q8-Paged", "2026-09-09", downloads: 0),
        ]
        let builds = try family("ltx").appleSiliconBuilds(in: hits, generation: XCTUnwrap(RadarGeneration("2.5")))
        XCTAssertEqual(builds.map(\.id), ["Karam98/ltx-2.5-mlx-q4", "Vayden/LTX-2.5-MLX-Q8-Paged", "dgrauet/ltx-2.5-mlx-q4"],
                       "most-downloaded first, then newest; capped at three")
    }

    func testFamilyWithoutAnAppleSiliconSearchYieldsNoBuilds() throws {
        var noSearch = try family("flux"); noSearch.appleSiliconSearch = nil
        XCTAssertTrue(noSearch.appleSiliconBuilds(in: [repo("x/flux-mlx", "2026-01-01")], generation: RadarGeneration("2")!).isEmpty)
    }

    // MARK: the data itself

    func testWatchlistIsWellFormed() throws {
        let ids = ModelWatchlist.families.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "family ids must be unique")
        for family in ModelWatchlist.families {
            XCTAssertFalse(family.publisher.isEmpty, family.id)
            XCTAssertNoThrow(try NSRegularExpression(pattern: family.generationPattern), "\(family.id) generation pattern")
            XCTAssertNoThrow(try NSRegularExpression(pattern: family.excludePattern), "\(family.id) exclude pattern")
            XCTAssertEqual(family.generationPattern.contains("("), true, "\(family.id) pattern needs a capture group")
        }
    }

    func testEveryCoveredRecipeExistsInTheCatalogueWithAParsableGeneration() {
        let known = Set((ModelCatalog.recipes).map(\.id))
        for family in ModelWatchlist.families {
            XCTAssertFalse(family.coverage.isEmpty, "\(family.id) covers nothing")
            for (recipeID, generation) in family.coverage {
                XCTAssertTrue(known.contains(recipeID), "\(family.id) covers unknown recipe \(recipeID)")
                XCTAssertNotNil(RadarGeneration(generation), "\(family.id): \(recipeID) has unparsable generation \(generation)")
            }
        }
    }

    func testTheRequestedFamiliesAreWatched() {
        let byCategory = Dictionary(grouping: ModelWatchlist.families, by: \.category)
        XCTAssertEqual(Set((byCategory[.video] ?? []).map(\.id)), ["wan", "ltx"], "Video: Wan and LTX")
        XCTAssertNotNil(byCategory[.image])
        XCTAssertNotNil(byCategory[.textVision])
    }
}
