import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

@MainActor
final class NodeInspectorTests: XCTestCase {
    func testModelRefreshKeepsUnavailableAndEmptyNodeSelections() async {
        let unavailable = StudioNode(kind: .textModel, label: "Unavailable", position: .init(x: 0, y: 0), model: "missing-model")
        let empty = StudioNode(kind: .textModel, label: "Empty", position: .init(x: 0, y: 1))
        let project = WorkflowProject(name: "Selections", nodes: [unavailable, empty], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id
        await model.refreshModels()
        XCTAssertEqual(model.models.map(\.name), ["stub"])
        XCTAssertEqual(model.currentProject?.nodes.map(\.model), ["missing-model", ""])
    }

    func testThumbnailIsBoundedAndMissingFilesFail() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "large.png")
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let cache = ImageThumbnailCache()
        let data = try await cache.thumbnail(source)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(image.width, 640); XCTAssertEqual(image.height, 320)
        let repeated = try await cache.thumbnail(source)
        XCTAssertEqual(repeated, data)
        do { _ = try await cache.thumbnail(root.appending(path: "missing.png")); XCTFail("Missing source must fail") } catch { }
    }
}
