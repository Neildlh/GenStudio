import AppKit
import SwiftUI
import XCTest
@testable import GenStudio

/// Renders the two new surfaces offscreen with real hardware values and canned radar data. Set
/// `RADAR_RENDER_DIR` to keep the PNGs for a visual check; without it the images are only checked
/// for being non-empty, which still proves the views build a body with realistic input.
@MainActor
final class RadarViewSmokeTests: XCTestCase {
    /// A fresh test case instance per test gives each test its own folder; a `let` is safe to read from the
    /// nonisolated `tearDown`.
    private let root = FileManager.default.temporaryDirectory.appending(path: "RadarViewTests-\(UUID())", directoryHint: .isDirectory)

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func store() -> ModelLibraryViewModel {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        store.hardware = HardwareProfile.current(storageURL: root)
        return store
    }

    private func png<V: View>(_ view: V, width: CGFloat, name: String) throws -> NSImage {
        let framed = view.frame(width: width).padding(16).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "\(name) did not render")
        XCTAssertGreaterThan(image.size.width, 100); XCTAssertGreaterThan(image.size.height, 40)
        if let directory = ProcessInfo.processInfo.environment["RADAR_RENDER_DIR"],
           let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: directory).appending(path: name + ".png"))
        }
        return image
    }

    func testThisMacCardShowsTheRealHardwareOfTheMachineRunningTheTests() throws {
        let store = store()
        let hardware = try XCTUnwrap(store.hardware)
        let summary = HardwareSummary(hardware)
        // Printed so the real probes (core counts, Metal budget) can be checked against the machine.
        print("THIS MAC:", summary.chip, "|", summary.cores ?? "no core info", "|", summary.memory ?? "-", "|", summary.modelBudget ?? "-", "|", summary.disk ?? "-", "|", summary.system)
        XCTAssertTrue(summary.chip.hasPrefix("Apple M"), "expected an Apple Silicon test machine, got \(summary.chip)")
        XCTAssertNotNil(summary.memory)
        XCTAssertNotNil(summary.disk)
        // Not wrapped in a List: ImageRenderer draws AppKit-backed views as a "prohibited" placeholder.
        _ = try png(VStack(alignment: .leading, spacing: 6) {
            Text("THIS MAC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ThisMacCard(store: store)
        }, width: 250, name: "this-mac-card")
    }

    func testWatchDetailOffersLinksOutAndNoInstallAction() throws {
        let build = HubRepo(id: "dgrauet/ltx-2.5-mlx-q4", createdAt: nil, downloads: 188, likes: 0, pipelineTag: nil, gated: false)
        let entry = RadarEntry(id: "watch:ltx:2.5", familyID: "ltx", category: .video, tier: .watch, title: "LTX 2.5",
                               generation: RadarGeneration("2.5"), recipeID: nil, repository: "Lightricks/LTX-2.5-Pre-Trained",
                               released: Date(), sizeBytes: 13_000_000_000,
                               fit: ModelRadar.watchFit(bytes: 13_000_000_000, hardware: store().hardware), installed: false,
                               facts: "Released 10 Aug 2026. GenStudio has no route for this yet. Apple Silicon (MLX) builds already exist.",
                               gated: true, buildRepositories: [build])
        _ = try png(RadarWatchDetail(entry: entry, sentence: entry.facts), width: 640, name: "radar-watch-detail")
        XCTAssertEqual(RadarWatchDetail.hubURL("Lightricks/LTX-2.5-Pre-Trained")?.absoluteString, "https://huggingface.co/Lightricks/LTX-2.5-Pre-Trained")
        XCTAssertNil(RadarWatchDetail.hubURL("../etc/passwd"), "a tampered cache entry must not become a link")
        XCTAssertNil(RadarWatchDetail.hubURL("https://evil.example/x"))
    }

    func testThisMacCardHasAFallbackBeforeHardwareIsRead() throws {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        _ = try png(ThisMacCard(store: store), width: 240, name: "this-mac-card-loading")
    }

    func testRadarSectionRendersCheckedResultsWithWriterNotes() async throws {
        let store = store()
        let cacheRoot = root.appending(path: "radar", directoryHint: .isDirectory)
        let service = ModelRadarService(transport: HubDiscoveryTransport(), cacheRoot: cacheRoot)
        let repo = { (id: String, day: String, downloads: Int) in
            HubRepo(id: id, createdAt: ISO8601DateFormatter().date(from: day + "T00:00:00Z"), downloads: downloads, likes: 0, pipelineTag: nil, gated: false)
        }
        func live(_ id: String, _ generation: String, upstream: String, builds: [HubRepo] = [], sizes: [String: Int64] = [:]) -> FamilyLive {
            FamilyLive(familyID: id, newest: NewestUpstream(generation: RadarGeneration(generation)!, repos: [repo(upstream, "2026-08-10", 371)]),
                       builds: builds, sizes: sizes, error: nil)
        }
        var snapshot = RadarSnapshot(fetchedAt: Date(), families: [
            live("wan", "2.2", upstream: "Wan-AI/Wan2.2-Animate-2-14B"),
            live("ltx", "2.5", upstream: "Lightricks/LTX-2.5-Pre-Trained", builds: [repo("Karam98/ltx-2.5-mlx-q4", "2026-09-02", 188), repo("dgrauet/ltx-2.5-mlx-q4", "2026-08-27", 0)],
                 sizes: ["Karam98/ltx-2.5-mlx-q4": 13_000_000_000, "dgrauet/ltx-2.5-mlx-q4": 13_000_000_000]),
            live("flux", "2", upstream: "black-forest-labs/FLUX.2-klein-4B"),
            live("qwen", "3.8", upstream: "Qwen/Qwen3.8-27B"),
        ], summary: nil, blurbs: [:], writer: nil)
        // 1. A cache with notes but no record of who they were written about (how every cache looked before the bar existed)
        //    must show no notes at all, even though its text is well-formed.
        snapshot.summary = "Start with Wan 2.2 5B: it is small enough. LTX 2.5 is out."
        snapshot.blurbs = ["recipe:\(MediaModelCatalog.klein9BRecipeID)": "Stale note about a model."]
        snapshot.writer = "Notes written by an old version."
        await service.save(snapshot)
        store.radar = ModelRadarStore(host: store, service: service)
        await store.radar.loadCached()
        XCTAssertNotNil(store.radar.snapshot)
        XCTAssertNil(store.radar.notes, "notes written before the bar existed must never be shown")

        // 2. Notes written for exactly the models shown now are displayed.
        let visible = store.radar.presentation.families.flatMap(\.entries).map(\.id)
        XCTAssertFalse(visible.isEmpty)
        snapshot.summary = "Start with LTX-2.3 for video and Klein 9B for images."
        snapshot.blurbs = ["recipe:\(MediaModelCatalog.klein9BRecipeID)": "Strong at editing; the first run doubles as the test."]
        snapshot.writer = "Notes written by Qwen 3.8 27B (on this Mac)."
        snapshot.writtenFor = visible
        await service.save(snapshot)
        store.radar = ModelRadarStore(host: store, service: service)
        await store.radar.loadCached()
        XCTAssertNotNil(store.radar.notes)
        XCTAssertFalse(store.radar.reports.isEmpty)
        _ = try png(ModelRadarSection(store: store) { _ in }, width: 760, name: "radar-section")
    }

    func testRadarSectionRendersBeforeAnyCheck() throws {
        _ = try png(ModelRadarSection(store: store()) { _ in }, width: 760, name: "radar-section-unchecked")
    }
}
