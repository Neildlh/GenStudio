import AppKit
import SwiftUI
import XCTest
@testable import GenStudio

final class CanvasVideoPreviewTests: XCTestCase {
    func testVideoCardStartsAtItsRequestedShape() {
        var node = StudioNode(kind: .imageToVideo, label: "Image to Video", position: .init(x: 0, y: 0))
        node.video.width = 512; node.video.height = 768
        let width = NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2
        XCTAssertEqual(NodeLayout.previewHeight(node), width * 1.5, accuracy: 0.01, "A 2:3 request previews 2:3 before it runs")
    }

    @MainActor
    func testVideoCardTakesTheMeasuredShapeOfItsClip() async throws {
        let root = try VideoFixtures.root("canvas-video-shape")
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.colorClip((40, 120, 200), frames: 4, fps: 8, width: 90, height: 160, in: root, name: "portrait")
        var node = StudioNode(kind: .videoUpscale, label: "Upscale", position: .init(x: 0, y: 0))
        node.video.width = 768; node.video.height = 512
        let width = NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2
        XCTAssertEqual(NodeLayout.previewHeight(node, output: .video(clip)), width / 1.5, accuracy: 0.01, "Unmeasured clips fall back to the node's dimensions")

        let loaded = await CanvasVideoPosterCache.load(clip)
        let poster = try XCTUnwrap(loaded)
        XCTAssertEqual(Double(poster.width) / Double(poster.height), 90.0 / 160.0, accuracy: 0.02)
        NodeLayout.videoAspectRatios.record(Double(poster.width) / Double(poster.height), for: clip)
        XCTAssertEqual(NodeLayout.previewHeight(node, output: .video(clip)), width * 160 / 90, accuracy: 4, "A downstream card reshapes to the clip it actually holds")
    }

    func testVideoInputCardTakesItsFilesShapeOnceMeasured() throws {
        let root = try VideoFixtures.root("canvas-video-input")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "imported.mov")
        try Data([0]).write(to: path)
        var node = StudioNode(kind: .videoInput, label: "Video Input", position: .init(x: 0, y: 0))
        node.videoPath = path.path
        NodeLayout.videoAspectRatios.record(9.0 / 16.0, for: path)
        let width = NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2
        XCTAssertEqual(NodeLayout.previewHeight(node), width * 16 / 9, accuracy: 0.01)
        XCTAssertEqual(NodeCardPreview.videoURL(node: node, output: nil), path, "An imported clip plays before the node runs")
    }

    func testOnlyReadableClipsArePlayedInPlace() throws {
        let node = StudioNode(kind: .imageToVideo, label: "Image to Video", position: .init(x: 0, y: 0))
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).mov")
        XCTAssertNil(NodeCardPreview.videoURL(node: node, output: .video(missing)))
        XCTAssertNil(NodeCardPreview.videoURL(node: node, output: nil))
    }

    @MainActor
    func testOffscreenVideoCardEvidence() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["GENSTUDIO_VIDEO_CARD_EVIDENCE"] else { throw XCTSkip("Set GENSTUDIO_VIDEO_CARD_EVIDENCE to write an offscreen video node image.") }
        let root = try VideoFixtures.root("canvas-video-evidence")
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.colorClip((196, 160, 120), frames: 8, fps: 8, width: 512, height: 768, in: root, name: "take")
        var node = StudioNode(kind: .imageToVideo, label: "Image to Video", position: .init(x: 0, y: 0))
        node.video.width = 512; node.video.height = 768
        var progress = NodeExecutionProgress()
        progress.status = .completed; progress.stage = "Done"; progress.queuedAt = Date().addingTimeInterval(-214); progress.finishedAt = Date()
        let card = NodeCard(node: node, output: .video(clip), progress: progress, runModel: {}, selected: true, activeWire: nil, move: { _, _ in }, wire: { _, _, _, _ in })
            .frame(width: NodeLayout.cardWidth(node), height: NodeLayout.cardHeight(node, output: .video(clip)))
            .padding(.horizontal, 130).padding(.vertical, 24).background(Color(white: 0.08))
        let size = NSSize(width: NodeLayout.cardWidth(node) + 260, height: NodeLayout.cardHeight(node, output: .video(clip)) + 48)
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: outputPath))
    }
}
