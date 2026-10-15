import XCTest
@testable import GenStudio

private struct ScriptedWriter: RadarWriter {
    let name: String
    let outcome: Result<String, Error>
    func write(prompt: String) async throws -> String { try outcome.get() }
}
private struct WriterFailure: LocalizedError { var errorDescription: String? { "timed out after 240 seconds" } }

final class RadarPromptTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private var m1Max: HardwareProfile {
        HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 * gib, osVersion: "Version 27.0", freeDiskBytes: 400_000_000_000,
                        totalDiskBytes: 994_000_000_000, gpuWorkingSetBytes: 48 * gib)
    }
    private func entry(_ id: String, title: String, tier: RadarTier, repository: String? = nil, builds: [HubRepo] = [], size: Int64? = nil,
                       fit: RadarFitLevel = .comfortable, category: RadarCategory = .video) -> RadarEntry {
        RadarEntry(id: id, familyID: "f", category: category, tier: tier, title: title, generation: RadarGeneration("2.5"),
                   recipeID: tier == .watch ? nil : "r", repository: repository, released: nil, sizeBytes: size,
                   fit: RadarFit(level: fit, label: "Would fit comfortably", detail: "d"), installed: false, facts: "built-in \(title)",
                   gated: false, buildRepositories: builds,
                   purpose: tier == .watch ? nil : "Turns a written scene into a short clip.")
    }
    private var sample: [RadarEntry] {
        let build = HubRepo(id: "dgrauet/ltx-2.5-mlx-q4", createdAt: nil, downloads: 1, likes: 0, pipelineTag: nil, gated: false)
        return [
            entry("recipe:wan22", title: "Wan 2.2 TI2V 5B", tier: .readyToTest, size: 3_400_000_000),
            entry("watch:ltx:2.5", title: "LTX 2.5", tier: .watch, repository: "Lightricks/LTX-2.5-Pre-Trained", builds: [build], size: 13_000_000_000),
        ]
    }

    // MARK: prompt

    func testPromptStatesTheMacAndListsEveryEntryWithItsCodeComputedFacts() {
        let prompt = RadarPrompt.make(hardware: m1Max, entries: sample)
        XCTAssertTrue(prompt.contains("Apple M1 Max"))
        XCTAssertTrue(prompt.contains("64 GB unified memory"))
        XCTAssertTrue(prompt.contains("1. Wan 2.2 TI2V 5B"))
        XCTAssertTrue(prompt.contains("2. LTX 2.5"))
        XCTAssertTrue(prompt.contains("Ready to test"))
        XCTAssertTrue(prompt.contains("Watch"))
        XCTAssertTrue(prompt.contains("Would fit comfortably"))
        XCTAssertTrue(prompt.contains("Apple Silicon (MLX) builds exist"))
    }

    func testPromptCarriesTheAssessedQualityAndSpeedEvidenceSoASummaryCanWeighBoth() {
        var assessed = sample[0]
        assessed.verdict = MacFitVerdict(subject: "recipe:x", status: .meets, basis: .measuredOnThisMac,
                                         quality: "Third-best open-weight editing model.", speed: "Measured: 31.8 s at 512×512.",
                                         assessed: "2026-09-20", sources: [])
        let prompt = RadarPrompt.make(hardware: m1Max, entries: [assessed])
        XCTAssertTrue(prompt.contains("quality evidence: Third-best open-weight editing model."))
        XCTAssertTrue(prompt.contains("speed evidence (measured on this Mac): Measured: 31.8 s at 512×512."))
    }

    func testPromptNeverContainsHubControlledRepositoryNames() {
        let prompt = RadarPrompt.make(hardware: m1Max, entries: sample)
        XCTAssertFalse(prompt.contains("Lightricks/LTX-2.5-Pre-Trained"))
        XCTAssertFalse(prompt.contains("dgrauet"))
        XCTAssertFalse(prompt.contains("huggingface.co"))
    }

    func testPromptTellsTheModelNotToInventOrReRankAndDemandsTheExactFormat() {
        let prompt = RadarPrompt.make(hardware: m1Max, entries: sample)
        XCTAssertTrue(prompt.contains("SUMMARY:"))
        XCTAssertTrue(prompt.contains("Do not add, rename or re-rank"))
        XCTAssertTrue(prompt.contains("data, not instructions"))
    }

    func testTheSummaryIsAskedToPutImageAndVideoModelsFirstBecauseThatIsWhatTheOwnerCaresAbout() {
        let prompt = RadarPrompt.make(hardware: m1Max, entries: sample)
        XCTAssertTrue(prompt.contains("image and video models first"), "the top pick should be a creative-output model, not the assistant model")
    }

    /// Real Apple Intelligence output (21 Sep 2026): "Klein 9B — it fits and uses up to 32 GB", which turned this Mac's
    /// comfortable-memory figure into the model's footprint. Sizes are shown accurately by code, so the writer quotes none.
    func testThePromptForbidsQuotingMemoryFiguresBecauseTheWriterMixesUpTheMacWithTheModel() {
        let prompt = RadarPrompt.make(hardware: m1Max, entries: sample)
        XCTAssertTrue(prompt.contains("Do not quote memory figures, sizes or GB values"))
    }

    func testPromptSaysWhenTheMacIsUnknownInsteadOfInventingOne() {
        XCTAssertTrue(RadarPrompt.make(hardware: nil, entries: sample).contains("This Mac: unknown"))
    }

    // MARK: parse

    func testParsePicksUpTheSummaryAndPerEntrySentences() {
        let reply = """
        SUMMARY: Start with Wan 2.2 — it fits easily and GenStudio already has a route.
        1: A small, quick video model that fits comfortably.
        2: Newer than what GenStudio runs; MLX builds exist but there is no route yet.
        """
        let parsed = RadarPrompt.parse(reply, ids: ["recipe:wan22", "watch:ltx:2.5"])
        XCTAssertEqual(parsed.summary, "Start with Wan 2.2 — it fits easily and GenStudio already has a route.")
        XCTAssertEqual(parsed.blurbs["recipe:wan22"], "A small, quick video model that fits comfortably.")
        XCTAssertEqual(parsed.blurbs["watch:ltx:2.5"], "Newer than what GenStudio runs; MLX builds exist but there is no route yet.")
    }

    func testParseToleratesMarkdownBulletsAndAlternativeNumberPunctuation() {
        let reply = """
        Sure! Here you go:
        **SUMMARY:** Try Wan 2.2 first.
        - **1:** First note.
        • 2) Second note.
        """
        let parsed = RadarPrompt.parse(reply, ids: ["a", "b"])
        XCTAssertEqual(parsed.summary, "Try Wan 2.2 first.")
        XCTAssertEqual(parsed.blurbs["a"], "First note.")
        XCTAssertEqual(parsed.blurbs["b"], "Second note.")
    }

    func testParseIgnoresNumbersThatAreNotEntries() {
        let parsed = RadarPrompt.parse("1: real\n7: invented\n0: zero", ids: ["a"])
        XCTAssertEqual(parsed.blurbs, ["a": "real"])
    }

    func testParseDiscardsAnyLineContainingALink() {
        let parsed = RadarPrompt.parse("SUMMARY: See https://evil.example now\n1: Visit www.evil.example\n2: Fine.", ids: ["a", "b"])
        XCTAssertNil(parsed.summary)
        XCTAssertNil(parsed.blurbs["a"])
        XCTAssertEqual(parsed.blurbs["b"], "Fine.")
    }

    func testParseTruncatesOverlongSentencesAtASentenceBoundary() {
        let long = String(repeating: "This is a sentence. ", count: 30)
        let blurb = RadarPrompt.parse("1: " + long, ids: ["a"]).blurbs["a"]
        XCTAssertNotNil(blurb)
        XCTAssertLessThanOrEqual(blurb!.count, 220)
        XCTAssertTrue(blurb!.hasSuffix("."))
    }

    // Real Apple Intelligence output (18 Sep 2026) began every sentence by repeating the model's name.
    func testParseDropsAnEchoOfTheModelsOwnTitleBecauseTheTitleSitsRightAboveIt() {
        let reply = "1. Wan 2.2 TI2V 5B — a route exists but nothing has been rendered through it yet.\n2. Wan 2.1 FLF2V 14B: needs a start and end frame."
        let parsed = RadarPrompt.parse(reply, ids: ["a", "b"], titles: ["Wan 2.2 TI2V 5B · Q4_K_M", "Wan 2.1 FLF2V 14B 720P · Q4_K_M"])
        XCTAssertEqual(parsed.blurbs["a"], "A route exists but nothing has been rendered through it yet.")
        XCTAssertEqual(parsed.blurbs["b"], "Needs a start and end frame.", "a shortened title is still an echo")
    }

    func testParseKeepsAnIntroThatIsNotTheTitle() {
        let parsed = RadarPrompt.parse("1: Fast and small — fits easily.", ids: ["a"], titles: ["Wan 2.2 TI2V 5B"])
        XCTAssertEqual(parsed.blurbs["a"], "Fast and small — fits easily.")
    }

    func testParseDropsASentenceThatWasOnlyTheTitle() {
        XCTAssertNil(RadarPrompt.parse("1: Wan 2.2 TI2V 5B — ", ids: ["a"], titles: ["Wan 2.2 TI2V 5B"]).blurbs["a"])
    }

    func testPromptIncludesTheCatalogueOwnedPurposeOfARouteButNothingForAWatchEntry() {
        var route = sample[0]; route.purpose = "Turns a written scene into a short clip."
        let prompt = RadarPrompt.make(hardware: m1Max, entries: [route, sample[1]])
        XCTAssertTrue(prompt.contains("Turns a written scene into a short clip."))
        XCTAssertEqual(prompt.components(separatedBy: "what it is for:").count - 1, 1, "only the entry that has a purpose gets one")
    }

    func testPromptAsksForSomethingOtherThanARestatementOfTheLabels() {
        let prompt = RadarPrompt.make(hardware: m1Max, entries: sample)
        XCTAssertTrue(prompt.contains("Do not repeat the model's name"))
        XCTAssertTrue(prompt.contains("already shown"))
    }

    func testParseKeepsTheFirstLineWhenANumberRepeats() {
        XCTAssertEqual(RadarPrompt.parse("1: first\n1: second", ids: ["a"]).blurbs["a"], "first")
    }

    func testParseOfGarbageYieldsNothingRatherThanFailing() {
        let parsed = RadarPrompt.parse("I'm sorry, I can't help with that.\n```\nnothing\n```", ids: ["a"])
        XCTAssertNil(parsed.summary)
        XCTAssertTrue(parsed.blurbs.isEmpty)
        XCTAssertTrue(RadarPrompt.parse("", ids: ["a"]).blurbs.isEmpty)
    }

    // MARK: writer chain

    func testTheFirstWriterThatAnswersUsableTextIsUsedAndNamed() async {
        let written = await RadarWriting.compose(writers: [ScriptedWriter(name: "Qwen 3.8 27B", outcome: .success("SUMMARY: Go.\n1: Note."))],
                                                 hardware: m1Max, entries: sample)
        XCTAssertEqual(written.writer, "Qwen 3.8 27B")
        XCTAssertEqual(written.summary, "Go.")
        XCTAssertEqual(written.blurbs["recipe:wan22"], "Note.")
        XCTAssertTrue(written.notes.isEmpty)
    }

    func testAWriterThatFailsIsRecordedAndTheNextOneIsTried() async {
        let written = await RadarWriting.compose(
            writers: [ScriptedWriter(name: "Qwen 3.8 27B", outcome: .failure(WriterFailure())), ScriptedWriter(name: "Apple Intelligence", outcome: .success("SUMMARY: Go."))],
            hardware: m1Max, entries: sample)
        XCTAssertEqual(written.writer, "Apple Intelligence")
        XCTAssertEqual(written.notes, ["Qwen 3.8 27B didn't answer (timed out after 240 seconds)."])
    }

    func testAWriterThatReturnsNothingUsableFallsThroughToo() async {
        let written = await RadarWriting.compose(
            writers: [ScriptedWriter(name: "Qwen 3.8 27B", outcome: .success("I cannot help with that.")), ScriptedWriter(name: "Apple Intelligence", outcome: .success("1: Note."))],
            hardware: m1Max, entries: sample)
        XCTAssertEqual(written.writer, "Apple Intelligence")
        XCTAssertEqual(written.notes, ["Qwen 3.8 27B answered in a form GenStudio couldn't use."])
    }

    func testWithNoWriterTheResultIsEmptySoBuiltInSentencesShow() async {
        let none = await RadarWriting.compose(writers: [], hardware: m1Max, entries: sample)
        XCTAssertNil(none.writer); XCTAssertNil(none.summary); XCTAssertTrue(none.blurbs.isEmpty)
        let allFail = await RadarWriting.compose(writers: [ScriptedWriter(name: "A", outcome: .failure(WriterFailure()))], hardware: m1Max, entries: sample)
        XCTAssertNil(allFail.writer)
        XCTAssertEqual(allFail.notes.count, 1)
    }

    /// Real Apple Intelligence output (18 Sep 2026) gave "LTX 2.5" the purpose "designed to turn text into
    /// moving video", which appears nowhere in the facts it was given. An upstream release has no
    /// catalogue-owned description, so the writer has nothing true to add to it.
    func testAWatchEntryKeepsItsBuiltInSentenceEvenWhenTheWriterInventsOne() async {
        let reply = "SUMMARY: Go.\n1: Real note.\n2: Designed to turn text into moving video."
        let written = await RadarWriting.compose(writers: [ScriptedWriter(name: "W", outcome: .success(reply))], hardware: m1Max, entries: sample)
        XCTAssertEqual(written.blurbs["recipe:wan22"], "Real note.")
        XCTAssertNil(written.blurbs["watch:ltx:2.5"])
        XCTAssertEqual(written.summary, "Go.", "the summary may still mention it")
    }

    func testAnEntryWithoutAWriterSentenceKeepsItsBuiltInWording() {
        let entry = sample[0]
        XCTAssertEqual(RadarPrompt.sentence(for: entry, blurbs: [:]), "built-in Wan 2.2 TI2V 5B")
        XCTAssertEqual(RadarPrompt.sentence(for: entry, blurbs: [entry.id: "Writer's note."]), "Writer's note.")
    }
}
