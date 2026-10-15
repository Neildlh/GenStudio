import XCTest
@testable import GenStudio

/// Runs the real service against the real Hugging Face API. Opt in with `RUN_RADAR_LIVE=1`
/// (pass it to xcodebuild as `TEST_RUNNER_RUN_RADAR_LIVE=1`). It only reads public listings and
/// file sizes, downloads no model, and writes its cache to a temporary folder.
///
/// It asserts on *shape*, never on which models currently exist, so it keeps passing as the Hub changes:
/// every watched family must resolve without error, and anything reported must be a well-formed base repo.
final class ModelRadarLiveTests: XCTestCase {
    func testLiveCheckAgainstHuggingFace() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RADAR_LIVE"] == "1" else {
            throw XCTSkip("Opt in with RUN_RADAR_LIVE=1 to query the live Hugging Face API.")
        }
        let cache = FileManager.default.temporaryDirectory.appending(path: "RadarLive-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = ModelRadarService(cacheRoot: cache)

        let snapshot = try await service.check()
        XCTAssertFalse(snapshot.isTotalFailure, "no family could be checked: \(snapshot.families.compactMap(\.error))")
        for live in snapshot.families {
            XCTAssertNil(live.error, "\(live.familyID): \(live.error ?? "")")
            let family = try XCTUnwrap(ModelWatchlist.families.first { $0.id == live.familyID })
            for repo in live.newest?.repos ?? [] {
                XCTAssertEqual(family.generation(ofRepository: repo.id), live.newest?.generation, "\(repo.id) is not a base repo of the reported generation")
            }
            for build in live.builds { XCTAssertTrue(build.id.lowercased().contains("mlx"), build.id) }
        }

        // Persist and reload through the real cache path.
        await service.save(snapshot)
        let reloaded = await service.loadCached()
        XCTAssertEqual(reloaded?.families, snapshot.families)

        try await printReport(for: snapshot)
    }

    /// The prompt and parser were designed against an assumed reply format. This is the check that
    /// a real on-device model's actual output survives them. Skipped where Apple Intelligence is unavailable.
    func testAppleIntelligenceReplyParsesIntoNotes() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RADAR_LIVE"] == "1" else {
            throw XCTSkip("Opt in with RUN_RADAR_LIVE=1 to query the live Hugging Face API.")
        }
        guard AppleIntelligenceRadarWriter.isAvailable else { throw XCTSkip("Apple Intelligence is unavailable on this Mac.") }
        let cache = FileManager.default.temporaryDirectory.appending(path: "RadarLive-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let snapshot = try await ModelRadarService(cacheRoot: cache).check()
        let mac = HardwareProfile.current()
        let inputs = RadarInputs(recipe: { id in ModelCatalog.recipes.first { $0.id == id } },
                                 assess: { ModelCompatibility.assess(recipe: $0, hardware: mac) },
                                 proven: { $0.id == VideoCapabilityRegistry.wanT2VRecipeID }, installed: [], hardware: mac)
        let entries = ModelRadar.report(snapshot: snapshot, inputs: inputs).flatMap(\.entries)
        XCTAssertFalse(entries.isEmpty)

        let prompt = RadarPrompt.make(hardware: mac, entries: entries)
        let raw = try await AppleIntelligenceRadarWriter().write(prompt: prompt)
        print("RADAR RAW REPLY >>>\n\(raw)\n<<<")
        let parsed = RadarPrompt.parse(raw, ids: entries.map(\.id))
        print("RADAR PARSED summary: \(parsed.summary ?? "nil")")
        for entry in entries { print("RADAR PARSED \(entry.title): \(parsed.blurbs[entry.id] ?? "(no sentence, built-in wording would show)")") }

        XCTAssertNotNil(parsed.summary, "the model's reply had no usable SUMMARY line")
        XCTAssertGreaterThan(parsed.blurbs.count, entries.count / 2, "fewer than half the entries got a sentence")
        for text in [parsed.summary].compactMap({ $0 }) + Array(parsed.blurbs.values) {
            XCTAssertFalse(text.lowercased().contains("http"))
        }
    }

    /// The owner's rule, end to end and for real: a genuine check against the live Hub with a genuine on-device
    /// writer, then everything that would reach the screen (and everything the writer said) is scanned for models that
    /// did not meet the speed-and-quality bar. Opt in with RUN_RADAR_LIVE=1.
    @MainActor
    func testWholeCheckThroughTheStoreNeverNamesAModelThatMissedTheBar() async throws {
        guard ProcessInfo.processInfo.environment["RUN_RADAR_LIVE"] == "1" else {
            throw XCTSkip("Opt in with RUN_RADAR_LIVE=1 to query the live Hugging Face API.")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "RadarLiveStore-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        store.hardware = HardwareProfile.current(storageURL: root)
        store.radar = ModelRadarStore(host: store, service: ModelRadarService(cacheRoot: root.appending(path: "radar", directoryHint: .isDirectory)))

        store.radar.check()
        for _ in 0..<600 where store.radar.checking { try await Task.sleep(for: .milliseconds(500)) }
        XCTAssertFalse(store.radar.checking, "the check did not finish within five minutes")
        XCTAssertNil(store.radar.failure, store.radar.failure ?? "")

        let presentation = store.radar.presentation
        let entries = presentation.families.flatMap(\.entries)
        XCTAssertFalse(entries.isEmpty, "at least the assessed suggestion should be shown")
        for entry in entries { XCTAssertNotNil(entry.verdict, "\(entry.id) was shown without a verdict") }

        var words = [store.radar.snapshot?.summary ?? ""] + Array((store.radar.snapshot?.blurbs ?? [:]).values)
        for family in presentation.families { words += [family.title, family.status]; for e in family.entries { words += [e.title, e.facts, e.verdict?.quality ?? "", e.verdict?.speed ?? ""] } }
        let screen = words.joined(separator: " ").lowercased()
        print("LIVE STORE: shown =", entries.map(\.id), "| newer-but-unassessed =", presentation.unassessedNewerReleases, "| writer =", store.radar.snapshot?.writer ?? "none")
        print("LIVE STORE summary:", store.radar.snapshot?.summary ?? "(none)")
        for hidden in ["ltx 2.5", "ltx-2.5", "klein 4b", "qwen-image", "qwen image", "minimax", "flux.2 dev", "flux.2 [dev]", "ideogram", "hidream", "wan 2", "wan2"] {
            XCTAssertFalse(screen.contains(hidden), "\"\(hidden)\" reached the screen or the writer's text")
        }
    }

    private func printReport(for snapshot: RadarSnapshot) async throws {
        // Print what the radar would tell the user, for a human to read in the test log.
        let mac = HardwareProfile.current()
        let inputs = RadarInputs(recipe: { id in ModelCatalog.recipes.first { $0.id == id } },
                                 assess: { ModelCompatibility.assess(recipe: $0, hardware: mac) },
                                 proven: { _ in false }, installed: [], hardware: mac)
        for report in ModelRadar.report(snapshot: snapshot, inputs: inputs) {
            print("RADAR [\(report.category.title)] \(report.title): \(report.status)")
            for entry in report.entries {
                let size = entry.sizeBytes.map { ModelLibraryViewModel.bytes($0) } ?? "size unknown"
                print("RADAR    · \(entry.tier.title) — \(entry.title) — \(entry.fit.label) — \(size)"
                      + (entry.buildRepositories.isEmpty ? "" : " — builds: " + entry.buildRepositories.map(\.id).joined(separator: ", ")))
            }
        }
    }
}
