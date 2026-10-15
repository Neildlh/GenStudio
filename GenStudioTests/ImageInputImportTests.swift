import XCTest
@testable import GenStudio

@MainActor
final class ImageInputImportTests: XCTestCase {
    func testSetInputImagePointsNodeAtFile() {
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: nil)
        let node = StudioNode(kind: .imageInput, label: "Reference", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Import", nodes: [node], edges: [])
        model.projects = [project]
        model.currentProjectID = project.id

        let url = URL(fileURLWithPath: "/tmp/reference.png")
        model.setInputImage(url, for: node.id)

        XCTAssertEqual(model.currentProject?.nodes.first?.imagePath, url.path)
    }
}

@MainActor
final class DroppedMediaImportTests: XCTestCase {
    private func makeModel() -> StudioModel {
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: nil)
        let project = WorkflowProject(name: "Drop", nodes: [], edges: [])
        model.projects = [project]
        model.currentProjectID = project.id
        return model
    }

    func testClassifiesImagesAndVideosByExtension() {
        XCTAssertEqual(DroppedMedia.nodeKind(for: URL(fileURLWithPath: "/tmp/a.PNG")), .imageInput)
        XCTAssertEqual(DroppedMedia.nodeKind(for: URL(fileURLWithPath: "/tmp/a.heic")), .imageInput)
        XCTAssertEqual(DroppedMedia.nodeKind(for: URL(fileURLWithPath: "/tmp/a.mov")), .videoInput)
        XCTAssertEqual(DroppedMedia.nodeKind(for: URL(fileURLWithPath: "/tmp/a.mp4")), .videoInput)
        XCTAssertNil(DroppedMedia.nodeKind(for: URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertNil(DroppedMedia.nodeKind(for: URL(string: "https://example.com/a.png")!))
    }

    func testDroppedFilesBecomeInputNodesInOrderAsOneUndoStep() {
        let model = makeModel()
        let urls = [URL(fileURLWithPath: "/tmp/hero shot.png"), URL(fileURLWithPath: "/tmp/notes.txt"), URL(fileURLWithPath: "/tmp/clip.mov")]

        let ids = model.importDroppedMedia(urls, at: .init(x: 200, y: 120))

        let nodes = model.currentProject?.nodes ?? []
        XCTAssertEqual(ids, nodes.map(\.id))
        XCTAssertEqual(nodes.map(\.kind), [.imageInput, .videoInput])
        XCTAssertEqual(nodes.map(\.label), ["hero shot", "clip"])
        XCTAssertEqual(nodes[0].imagePath, "/tmp/hero shot.png")
        XCTAssertEqual(nodes[1].videoPath, "/tmp/clip.mov")
        XCTAssertEqual(nodes[0].position, .init(x: 200, y: 120))
        XCTAssertEqual(nodes[1].position.x, 200)
        XCTAssertGreaterThan(nodes[1].position.y, nodes[0].position.y + NodeLayout.cardHeight(nodes[0]))
        XCTAssertEqual(model.selectedNodeID, ids.last)

        model.undo()
        XCTAssertEqual(model.currentProject?.nodes.count, 0)
    }

    func testDroppingOnlyUnsupportedFilesExplainsWhatCanBeImported() {
        let model = makeModel()

        let ids = model.importDroppedMedia([URL(fileURLWithPath: "/tmp/notes.txt")], at: .init(x: 0, y: 0))

        XCTAssertTrue(ids.isEmpty)
        XCTAssertEqual(model.currentProject?.nodes.count, 0)
        XCTAssertNotNil(model.alertMessage)
    }
}
