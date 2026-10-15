import XCTest
@testable import GenStudio

/// The Brand Kit stores a business's name, offer, contact details, colours and logo once, so every new
/// End Card and Start Video Ad is already branded.
final class BrandKitStoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "brand-kit-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAKitSurvivesAReopen() throws {
        let root = try root()
        var kit = BrandKit(); kit.businessName = "Thabo's Barbershop"; kit.contact = "WhatsApp 082 123 4567"; kit.accentHex = "#DC2626"
        try kit.save(root: root)
        XCTAssertEqual(BrandKit.load(root: root), kit)
    }

    func testNoKitYetOrAnUnreadableOneIsEmptyNotAnError() throws {
        let root = try root()
        XCTAssertTrue(BrandKit.load(root: root).isEmpty)
        try Data("not json".utf8).write(to: root.appending(path: BrandKit.fileName))
        XCTAssertTrue(BrandKit.load(root: root).isEmpty)
    }

    func testTheLogoIsCopiedIntoTheAppSoMovingTheOriginalDoesNotBreakIt() throws {
        let root = try root()
        let source = try VideoFixtures.solidPNG((200, 20, 20), width: 64, height: 32, in: root, name: "my-logo")
        var kit = BrandKit()
        try kit.adoptLogo(from: source, root: root)
        try FileManager.default.removeItem(at: source)
        let kept = try XCTUnwrap(kit.logoURL(root: root))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: kept.path))
        XCTAssertEqual(kept.deletingLastPathComponent().lastPathComponent, "BrandKit")
    }

    func testFillingACardUsesOnlyWhatTheKitHas() {
        var kit = BrandKit(); kit.businessName = "Lerato's Salon"; kit.backgroundHex = "#14532D"
        var card = EndCardSettings(); card.offer = "Braids from R350"; card.contact = "Call 011 555 0101"
        kit.fill(&card)
        XCTAssertEqual(card.headline, "Lerato's Salon")
        XCTAssertEqual(card.offer, "Braids from R350", "An empty kit field never wipes the card's own text")
        XCTAssertEqual(card.contact, "Call 011 555 0101")
        XCTAssertEqual(card.backgroundHex, "#14532D")
    }

    func testACardCanBecomeTheKit() {
        var card = EndCardSettings(); card.headline = "Sipho Plumbing"; card.offer = "24-hour call-outs"; card.contact = "WhatsApp 072 000 1111"; card.website = "siphoplumbing.co.za"; card.accentHex = "#93C5FD"
        var kit = BrandKit()
        kit.take(card)
        XCTAssertEqual([kit.businessName, kit.offer, kit.contact, kit.website, kit.accentHex], ["Sipho Plumbing", "24-hour call-outs", "WhatsApp 072 000 1111", "siphoplumbing.co.za", "#93C5FD"])
    }
}

@MainActor
final class BrandKitWorkflowTests: XCTestCase {
    private func model(kit: BrandKit, logo: Bool = false) throws -> StudioModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "brand-kit-model-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var kit = kit
        if logo { try kit.adoptLogo(from: try VideoFixtures.solidPNG((10, 10, 200), width: 80, height: 40, in: root, name: "logo"), root: root) }
        try kit.save(root: root)
        return StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
    }

    func testANewEndCardIsAlreadyBranded() throws {
        var kit = BrandKit(); kit.businessName = "Thabo's Barbershop"; kit.offer = "Fresh cuts from R150"
        let model = try model(kit: kit)
        model.createProject()
        model.addNode(.endCard)
        let card = try XCTUnwrap(model.currentProject?.nodes.first { $0.kind == .endCard }?.endCardSettings)
        XCTAssertEqual(card.headline, "Thabo's Barbershop"); XCTAssertEqual(card.offer, "Fresh cuts from R150")
    }

    func testStartVideoAdUsesTheKitAndWiresItsLogo() throws {
        var kit = BrandKit(); kit.businessName = "Lerato's Salon"; kit.contact = "WhatsApp 083 222 3333"
        let model = try model(kit: kit, logo: true)
        model.createLocalVideoAdWorkflow()
        let project = try XCTUnwrap(model.currentProject)
        let card = try XCTUnwrap(project.nodes.first { $0.kind == .endCard })
        XCTAssertEqual(card.endCardSettings?.headline, "Lerato's Salon")
        XCTAssertEqual(card.endCardSettings?.contact, "WhatsApp 083 222 3333")
        let logoEdge = try XCTUnwrap(project.edges.first { $0.targetID == card.id && $0.targetPortID == "logo" })
        let logoNode = try XCTUnwrap(project.nodes.first { $0.id == logoEdge.sourceID })
        XCTAssertEqual(logoNode.kind, .imageInput)
        XCTAssertEqual(logoNode.imagePath, model.brandKit.logoURL(root: model.persistence.root)?.path)
    }

    func testSavingTheKitPersistsIt() throws {
        let model = try model(kit: BrandKit())
        model.brandKit.businessName = "Sipho Plumbing"
        model.saveBrandKit()
        XCTAssertEqual(BrandKit.load(root: model.persistence.root).businessName, "Sipho Plumbing")
    }
}
