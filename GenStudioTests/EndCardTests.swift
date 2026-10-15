import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import GenStudio

/// End Card: the closing frame of an advert (logo, headline, offer, contact) rendered locally with no model,
/// as a short clip that joins the generated shots, plus the still for posters and WhatsApp status.
final class EndCardTests: XCTestCase {
    private func card() -> EndCardSettings {
        var settings = EndCardSettings()
        settings.headline = "Thabo's Barbershop"
        settings.offer = "Fresh cuts from R150"
        settings.contact = "WhatsApp 082 123 4567"
        settings.website = "@thabosbarber · Soweto"
        return settings
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
    private func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 24) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    func testRendersAVerticalClipOfTheChosenLengthAndItsStill() async throws {
        let root = try VideoFixtures.root("end-card"); defer { try? FileManager.default.removeItem(at: root) }
        var settings = card(); settings.durationSeconds = 3; settings.fps = 24

        let result = try await EndCardRenderer.render(settings, logo: nil, background: nil, video: root.appending(path: "card.mov"), still: root.appending(path: "card.png"))

        XCTAssertEqual(result.probe.width, 1080); XCTAssertEqual(result.probe.height, 1920)
        XCTAssertEqual(result.probe.frameCount, 72)
        XCTAssertEqual(result.probe.duration, 3, accuracy: 0.05)
        XCTAssertEqual(result.probe.nominalFPS, 24, accuracy: 0.1)
        XCTAssertGreaterThan(result.probe.distinctFrameCount, 4, "The text animates in")
        let still = try FrameSequenceEncoder.loadImage(root.appending(path: "card.png"))
        XCTAssertEqual(still.width, 1080); XCTAssertEqual(still.height, 1920)
    }

    func testTextStaysInsideTheSafeAreaInReadingOrder() throws {
        var settings = card()
        settings.headline = "Thabo's Barbershop and Grooming Lounge for Gentlemen of Distinction in Soweto"
        for size in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1080)] {
            let layout = EndCardLayout.make(settings, size: size, logoAspect: 2.0)
            let safe = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.06, dy: size.height * 0.05)
            let blocks = layout.blocks
            XCTAssertEqual(blocks.map(\.role), [.logo, .headline, .offer, .contact, .website])
            for block in blocks { XCTAssertTrue(safe.contains(block.frame), "\(block.role) at \(block.frame) leaves \(safe) on \(size)") }
            for (upper, lower) in zip(blocks, blocks.dropFirst()) {
                XCTAssertLessThanOrEqual(upper.frame.maxY, lower.frame.minY + 0.5, "\(upper.role) sits above \(lower.role) on \(size)")
            }
        }
    }

    func testEmptyLinesTakeNoSpace() {
        var settings = EndCardSettings(); settings.headline = "Book now"
        XCTAssertEqual(EndCardLayout.make(settings, size: .init(width: 1080, height: 1920), logoAspect: nil).blocks.map(\.role), [.headline])
    }

    func testTheLogoIsDrawnAboveTheHeadlineOnTheChosenColour() async throws {
        let root = try VideoFixtures.root("end-card-logo"); defer { try? FileManager.default.removeItem(at: root) }
        let logo = try VideoFixtures.solidPNG((220, 30, 30), width: 400, height: 200, in: root, name: "logo")
        var settings = card(); settings.backgroundHex = "#1E3A8A"; settings.animate = false
        _ = try await EndCardRenderer.render(settings, logo: logo, background: nil, video: root.appending(path: "c.mov"), still: root.appending(path: "c.png"))
        let still = try FrameSequenceEncoder.loadImage(root.appending(path: "c.png"))
        let layout = EndCardLayout.make(settings, size: .init(width: 1080, height: 1920), logoAspect: 2)
        let logoFrame = try XCTUnwrap(layout.blocks.first { $0.role == .logo }?.frame)
        XCTAssertTrue(close(try pixel(still, x: Int(logoFrame.midX), y: Int(logoFrame.midY)), (220, 30, 30)), "Logo pixels")
        XCTAssertTrue(close(try pixel(still, x: 20, y: 20), (0x1E, 0x3A, 0x8A)), "Background colour in the corner")
    }

    func testABackgroundPictureIsDimmedSoTheTextReads() async throws {
        let root = try VideoFixtures.root("end-card-bg"); defer { try? FileManager.default.removeItem(at: root) }
        let white = try VideoFixtures.solidPNG((255, 255, 255), width: 540, height: 960, in: root, name: "bg")
        var settings = card(); settings.backgroundDim = 0.5; settings.animate = false
        _ = try await EndCardRenderer.render(settings, logo: nil, background: white, video: root.appending(path: "c.mov"), still: root.appending(path: "c.png"))
        let corner = try pixel(try FrameSequenceEncoder.loadImage(root.appending(path: "c.png")), x: 10, y: 10)
        XCTAssertTrue(close(corner, (128, 128, 128), tolerance: 20), "\(corner)")
    }

    func testColoursParseFromHex() {
        XCTAssertNotNil(EndCardSettings.color("#F5B700")); XCTAssertNotNil(EndCardSettings.color("f5b700"))
        XCTAssertNil(EndCardSettings.color("#GG0000")); XCTAssertNil(EndCardSettings.color("#123"))
    }

    func testOlderDocumentsAndNewEndCardsBothDecode() throws {
        let node = StudioNode(kind: .endCard, label: "End Card", position: .init(x: 0, y: 0))
        XCTAssertNotNil(node.endCardSettings)
        XCTAssertEqual(node.inputPorts.map(\.id), ["logo", "background"])
        XCTAssertTrue(node.inputPorts.allSatisfy { !$0.required })
        XCTAssertEqual(node.outputPorts.map(\.id), ["video", "image"])
        var edited = node; edited.endCardSettings?.offer = "From R150"
        let decoded = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(decoded.endCardSettings?.offer, "From R150")
        let partial = try JSONDecoder().decode(EndCardSettings.self, from: Data(#"{"headline":"Book now"}"#.utf8))
        XCTAssertEqual(partial.headline, "Book now"); XCTAssertEqual(partial.width, 1080)
    }

    func testTheNodeRunsLocallyAndJoinsAnAssembly() async throws {
        let root = try VideoFixtures.root("end-card-graph"); defer { try? FileManager.default.removeItem(at: root) }
        let shot = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((40, 160, 90), frames: 24, fps: 24, width: 108, height: 192, in: root, name: "shot"), seconds: 1, in: root, name: "shot-tone")
        let input = StudioNode(kind: .videoInput, label: "Shot", position: .init(x: 0, y: 0), videoPath: shot.path)
        var card = StudioNode(kind: .endCard, label: "End Card", position: .init(x: 0, y: 1))
        card.endCardSettings = self.card(); card.endCardSettings?.durationSeconds = 2
        var assemble = StudioNode(kind: .assembleVideo, label: "Assemble", position: .init(x: 1, y: 0))
        assemble.assembly = .init(width: 1080, height: 1920, fps: 24, audio: .preserve)
        let export = StudioNode(kind: .instagramExport, label: "Export", position: .init(x: 2, y: 0))
        let project = WorkflowProject(name: "Ad", nodes: [input, card, assemble, export], edges: [
            VideoFixtures.edge(input, "video", assemble, assemble.dynamicInputs[0].id, .video),
            VideoFixtures.edge(card, "video", assemble, assemble.dynamicInputs[1].id, .video),
            VideoFixtures.edge(assemble, "video", export, "video", .video)
        ])
        XCTAssertNoThrow(try GraphValidator().validate(project))

        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: export.id)

        guard case .video(let cardClip)? = result.values[.init(nodeID: card.id, portID: "video")],
              case .image? = result.values[.init(nodeID: card.id, portID: "image")],
              case .video(let ad)? = result.values[.init(nodeID: export.id, portID: "video")] else { return XCTFail("End card and export outputs") }
        let cardProbe = try await VideoProbe.inspect(cardClip)
        XCTAssertEqual(cardProbe.duration, 2, accuracy: 0.05)
        let adProbe = try await VideoProbe.inspect(ad)
        XCTAssertEqual(adProbe.width, 1080); XCTAssertEqual(adProbe.height, 1920)
        XCTAssertEqual(adProbe.duration, 3, accuracy: 0.1, "1 s shot + 2 s end card")
        XCTAssertEqual(adProbe.nominalFPS, 24, accuracy: 0.5, "A 24 fps ad stays 24 fps; no duplicated frames")
        XCTAssertTrue(adProbe.hasAudio, "The shot's sound survives the end card and the export")
        let artifacts = try await StudioPersistence(root: root).loadExecutionArtifacts()
        XCTAssertEqual(artifacts.first?.mediaProvenance?[card.id]?.operation, .endCard)
    }
}

final class InstagramFrameRateTests: XCTestCase {
    func testCommonDeliveryRatesAreKeptAndDraftRatesAreNot() {
        XCTAssertEqual(InstagramReelExporter.deliveryFPS(sourceFPS: 24), 24)
        XCTAssertEqual(InstagramReelExporter.deliveryFPS(sourceFPS: 23.976), 24)
        XCTAssertEqual(InstagramReelExporter.deliveryFPS(sourceFPS: 25), 25)
        XCTAssertEqual(InstagramReelExporter.deliveryFPS(sourceFPS: 30), 30)
        XCTAssertNil(InstagramReelExporter.deliveryFPS(sourceFPS: 8), "An 8 fps draft would stutter; interpolate first")
        XCTAssertNil(InstagramReelExporter.deliveryFPS(sourceFPS: 16))
    }
}

final class EndCardFlowTests: XCTestCase {
    func testAIBuiltFlowsCanWriteTheCard() throws {
        let keys = Set(FlowSettingCatalog.settings(for: .endCard).map(\.key))
        XCTAssertTrue(["headline", "offer", "contact", "website", "durationSeconds"].allSatisfy(keys.contains), "\(keys)")
        var node = StudioNode(kind: .endCard, label: "Card", position: .init(x: 0, y: 0))
        let offer = try XCTUnwrap(FlowSettingCatalog.settings(for: .endCard).first { $0.key == "offer" })
        try offer.set(&node, .string("Braids from R350"))
        XCTAssertEqual(node.endCardSettings?.offer, "Braids from R350")
    }
}

final class EndCardValidationTests: XCTestCase {
    func testAnEmptyCardIsCaughtBeforeRunning() {
        var card = StudioNode(kind: .endCard, label: "Closing card", position: .init(x: 0, y: 0))
        card.endCardSettings = EndCardSettings(); card.endCardSettings?.headline = "  "
        XCTAssertThrowsError(try GraphValidator().validate(WorkflowProject(name: "t", nodes: [card], edges: []))) {
            XCTAssertTrue($0.localizedDescription.contains("Closing card"), $0.localizedDescription)
            XCTAssertTrue($0.localizedDescription.contains("at least one line"), $0.localizedDescription)
        }
    }

    func testTheCanvasCardTakesTheEndCardsShape() {
        var card = StudioNode(kind: .endCard, label: "Card", position: .init(x: 0, y: 0))
        let portrait = NodeLayout.previewHeight(card)
        card.endCardSettings?.width = 1920; card.endCardSettings?.height = 1080
        XCTAssertGreaterThan(portrait, NodeLayout.previewHeight(card) * 2, "A 9:16 card previews tall, a 16:9 card wide")
    }
}
