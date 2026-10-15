import AVFoundation
import XCTest
@testable import GenStudio

/// Text Overlay: a caption (an offer, a price, "Book now") over a clip, for the whole clip or a time window,
/// rendered locally. Sound and timing are untouched.
final class TextOverlayTests: XCTestCase {
    private func grey(_ root: URL, seconds: Int = 2, audio: Bool = false) async throws -> URL {
        let clip = try await VideoFixtures.colorClip((128, 128, 128), frames: seconds * 10, fps: 10, width: 180, height: 320, in: root, name: "grey")
        return audio ? try await VideoFixtures.withTone(clip, seconds: Double(seconds), in: root, name: "grey-tone") : clip
    }
    private func caption(_ position: TextOverlaySettings.Position = .middle) -> TextOverlaySettings {
        var settings = TextOverlaySettings(); settings.text = "From R150"; settings.subtext = "This weekend only"; settings.position = position
        return settings
    }

    func testTheCaptionShowsOnlyInItsWindowAndKeepsLengthAndSound() async throws {
        let root = try VideoFixtures.root("overlay"); defer { try? FileManager.default.removeItem(at: root) }
        var settings = caption(); settings.startSeconds = 0.6; settings.durationSeconds = 0.8
        let output = try await TextOverlayRenderer.render(settings, source: try await grey(root, audio: true), to: root.appending(path: "out.mov"))
        let probe = try await VideoProbe.inspect(output)
        XCTAssertEqual(probe.duration, 2, accuracy: 0.1); XCTAssertEqual(probe.width, 180); XCTAssertEqual(probe.height, 320)
        XCTAssertTrue(probe.hasAudio, "The clip's sound is kept")
        func centre(_ t: Double) -> [Int] { probe.frames.min { abs($0.time - t) < abs($1.time - t) }!.centerRGB }
        XCTAssertTrue(VideoFixtures.close(centre(0.2), (128, 128, 128)), "Before the window: \(centre(0.2))")
        XCTAssertFalse(VideoFixtures.close(centre(1.0), (128, 128, 128), tolerance: 20), "Caption over the centre: \(centre(1.0))")
        XCTAssertTrue(VideoFixtures.close(centre(1.8), (128, 128, 128)), "After the window: \(centre(1.8))")
    }

    func testAWholeClipCaptionStaysOnUntilTheEnd() async throws {
        let root = try VideoFixtures.root("overlay-whole"); defer { try? FileManager.default.removeItem(at: root) }
        let output = try await TextOverlayRenderer.render(caption(), source: try await grey(root), to: root.appending(path: "out.mov"))
        let probe = try await VideoProbe.inspect(output)
        XCTAssertFalse(VideoFixtures.close(probe.frames.last!.centerRGB, (128, 128, 128), tolerance: 20))
    }

    func testCaptionsStayInsideTheSafeAreaAtEveryPosition() {
        for size in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)] {
            let safe = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.06, dy: size.height * 0.05)
            var previous: CGFloat = -1
            for position in TextOverlaySettings.Position.allCases {
                var settings = caption(position); settings.text = "Fresh cuts, hot towel shaves and beard trims from R150 this weekend"
                let layout = TextOverlayLayout.make(settings, size: size)
                XCTAssertTrue(safe.contains(layout.band), "\(position) \(layout.band) on \(size)")
                XCTAssertGreaterThan(layout.band.midY, previous, "Top, middle, lower third run down the frame")
                previous = layout.band.midY
            }
        }
    }

    func testTheNodeRunsInAGraphAndRejectsAnEmptyCaption() async throws {
        let root = try VideoFixtures.root("overlay-graph"); defer { try? FileManager.default.removeItem(at: root) }
        let input = StudioNode(kind: .videoInput, label: "Shot", position: .init(x: 0, y: 0), videoPath: try await grey(root).path)
        var overlay = StudioNode(kind: .textOverlay, label: "Price", position: .init(x: 1, y: 0))
        XCTAssertEqual(overlay.inputPorts.map(\.id), ["video"]); XCTAssertEqual(overlay.outputPorts.map(\.id), ["video"])
        let project = WorkflowProject(name: "o", nodes: [input, overlay], edges: [VideoFixtures.edge(input, "video", overlay, "video", .video)])
        XCTAssertThrowsError(try GraphValidator().validate(project)) { XCTAssertTrue($0.localizedDescription.contains("Price"), $0.localizedDescription) }

        overlay.textOverlaySettings = caption()
        let ready = WorkflowProject(name: "o", nodes: [input, overlay], edges: project.edges)
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: ready, targetID: overlay.id)
        guard case .video(let url)? = result.values[.init(nodeID: overlay.id, portID: "video")] else { return XCTFail("Overlay output") }
        let probe = try await VideoProbe.inspect(url)
        XCTAssertEqual(probe.duration, 2, accuracy: 0.1)
        let decoded = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(overlay))
        XCTAssertEqual(decoded.textOverlaySettings?.text, "From R150")
    }

    func testTheBrandKitColoursTheCaption() {
        var kit = BrandKit(); kit.textHex = "#111827"; kit.accentHex = "#A3E635"
        var settings = TextOverlaySettings()
        kit.fill(&settings)
        XCTAssertEqual(settings.textHex, "#111827"); XCTAssertEqual(settings.accentHex, "#A3E635")
    }
}

/// One export node, four delivery shapes: Reels/Status, feed, square and landscape.
final class DeliveryFormatTests: XCTestCase {
    func testEachFormatHasItsPlatformSize() {
        XCTAssertEqual(DeliveryFormat.allCases.map { [$0.width, $0.height] }, [[1080, 1920], [1080, 1350], [1080, 1080], [1920, 1080]])
    }

    func testExportRendersTheChosenShapeAndOlderNodesStayVertical() async throws {
        let root = try VideoFixtures.root("formats"); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.colorClip((40, 120, 200), frames: 10, fps: 24, width: 320, height: 180, in: root, name: "wide")
        for format in [DeliveryFormat.square, .feed, .landscape] {
            let url = try await InstagramReelExporter.run(sourceVideo: clip, scratchRoot: root.appending(path: format.rawValue), fps: 24, format: format)
            let probe = try await VideoProbe.inspect(url)
            XCTAssertEqual([probe.width, probe.height], [format.width, format.height], format.rawValue)
        }
        let node = try JSONDecoder().decode(StudioNode.self, from: Data(#"{"kind":"instagramExport","label":"Reel","position":{"x":0,"y":0}}"#.utf8))
        XCTAssertEqual(node.format, .vertical)
    }
}
