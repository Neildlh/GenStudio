import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

final class LocalWorkflowToolsTests: XCTestCase {
    func testTextArrayOrderRoundTripSelectionAndBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: " first |second|| fourth ")
        var array = StudioNode(kind: .textArray, label: "Array", position: .init(x: 1, y: 0)); array.arrayDelimiter = "|"
        var select = StudioNode(kind: .listSelect, label: "Select", position: .init(x: 2, y: 0)); select.listIndex = 4
        let preview = StudioNode(kind: .textPreview, label: "Preview", position: .init(x: 3, y: 0))
        let edges = [StudioEdge(sourceID: prompt.id, sourcePortID: "text", targetID: array.id, targetPortID: "text", type: .text), StudioEdge(sourceID: array.id, sourcePortID: "items", targetID: select.id, targetPortID: "items", type: .textArray), StudioEdge(sourceID: select.id, sourcePortID: "text", targetID: preview.id, targetPortID: "text", type: .text)]
        let project = WorkflowProject(name: "Array", nodes: [prompt, array, select, preview], edges: edges)
        let store = StudioPersistence(root: root); try await store.saveProject(project)
        let loaded = try await store.loadProjects(); let reopened = try XCTUnwrap(loaded.first)
        XCTAssertEqual(reopened.nodes[1].arrayDelimiter, "|")
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: reopened, targetID: preview.id)
        XCTAssertEqual(result.values[.init(nodeID: array.id, portID: "items")], .textArray(["first", "second", "", "fourth"]))
        XCTAssertEqual(result.values[.init(nodeID: preview.id, portID: "text")], .text("fourth"))
        let artifacts = try await store.loadExecutionArtifacts()
        XCTAssertEqual(artifacts.first?.values[.init(nodeID: array.id, portID: "items")], .textArray(["first", "second", "", "fourth"]))
        var invalid = reopened; invalid.nodes[2].listIndex = 5
        do { _ = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: invalid, targetID: preview.id); XCTFail("Out of range must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("out of range")) }
        XCTAssertEqual(try TextArrayOperations.split("", delimiter: "|", trim: true), [])
        XCTAssertEqual(try TextArrayOperations.split(" a \nb", delimiter: "\\n", trim: false), [" a ", "b"])
        XCTAssertThrowsError(try TextArrayOperations.split("a", delimiter: "", trim: true))
        XCTAssertThrowsError(try TextArrayOperations.split(Array(repeating: "x", count: 257).joined(separator: "|"), delimiter: "|", trim: true))
    }

    func testRunPlanDeduplicatesSharedAncestorsAndSeparatesUnknownTimings() {
        let text = StudioNode(kind: .textModel, label: "Shared", position: .init(x: 0, y: 0), model: "qwen25-05b-q4km")
        var images = (0..<4).map { StudioNode(kind: .imageGenerator, label: "Image\($0)", position: .init(x: Double($0), y: 1), model: "sd15-q4") }
        let target = StudioNode(kind: .imageBlend, label: "Target", position: .init(x: 0, y: 2))
        let left = StudioNode(kind: .imageBlend, label: "Left", position: .init(x: 0, y: 2))
        let right = StudioNode(kind: .imageBlend, label: "Right", position: .init(x: 1, y: 2))
        var edges = images.map { StudioEdge(sourceID: text.id, sourcePortID: "text", targetID: $0.id, targetPortID: "prompt", type: .text) }
        for (index, image) in images.enumerated() {
            edges.append(.init(sourceID: image.id, sourcePortID: "image", targetID: index < 2 ? left.id : right.id, targetPortID: index.isMultiple(of: 2) ? "background" : "foreground", type: .image))
        }
        edges.append(.init(sourceID: left.id, sourcePortID: "image", targetID: target.id, targetPortID: "background", type: .image))
        edges.append(.init(sourceID: right.id, sourcePortID: "image", targetID: target.id, targetPortID: "foreground", type: .image))
        var project = WorkflowProject(name: "Plan", nodes: [text] + images + [left, right, target], edges: edges)
        let plan = RunPlan.make(project: project, target: target.id)
        XCTAssertEqual(plan.textGenerations, 1); XCTAssertEqual(plan.imageGenerations, 4)
        XCTAssertEqual(plan.knownImageBaselineSeconds, 376.56, accuracy: 0.001)
        XCTAssertEqual(plan.unknownGenerations, 1); XCTAssertTrue(plan.requiresConfirmation)
        images[0].width = 768; project.nodes = [text] + images + [left, right, target]
        let changed = RunPlan.make(project: project, target: target.id)
        XCTAssertEqual(changed.unknownGenerations, 2); XCTAssertFalse(changed.requiresConfirmation)
    }

    @MainActor
    func testRunConfirmationCapturesProjectAndTargetWithoutStartingGeneration() async {
        let nodes = (0..<4).map { StudioNode(kind: .imageGenerator, label: "Image\($0)", position: .init(x: Double($0), y: 0), model: "sd15-q4") }
        let target = StudioNode(kind: .imageBlend, label: "Target", position: .init(x: 0, y: 2))
        let project = WorkflowProject(name: "Captured", nodes: nodes + [target], edges: nodes.map { .init(sourceID: $0.id, sourcePortID: "image", targetID: target.id, targetPortID: "background", type: .image) })
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: engine)
        model.projects = [project]; model.currentProjectID = project.id; model.selectedNodeID = target.id
        model.runSelected()
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.pendingRun?.targetID, target.id)
        XCTAssertEqual(model.pendingRun?.project, project)
        model.projects[0].nodes[0].width = 768; model.selectedNodeID = nodes[0].id
        XCTAssertEqual(model.pendingRun?.project.nodes[0].width, 512)
        XCTAssertEqual(model.pendingRun?.targetID, target.id)
        model.pendingRun = nil
        let calls = await engine.capturedPrompts(); XCTAssertTrue(calls.isEmpty)
    }

    func testSpatialImageTransformsAt512PixelsAndColdTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 0, 0, 1]))); context.fill(CGRect(x: 0, y: 0, width: 256, height: 512))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0, 0, 1, 1]))); context.fill(CGRect(x: 256, y: 0, width: 256, height: 512))
        let url = root.appending(path: "spatial.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let media = MediaProcessor(root: root)
        var start = Date(); let flip = try await media.rotateFlip(url, quarterTurns: 0, horizontal: true, vertical: false); let flipSeconds = Date().timeIntervalSince(start)
        start = Date(); let rotate = try await media.rotateFlip(url, quarterTurns: 1, horizontal: false, vertical: false); let rotateSeconds = Date().timeIntervalSince(start)
        start = Date(); let inverse = try await media.invert(url); let invertSeconds = Date().timeIntervalSince(start)
        start = Date(); let blur = try await media.blur(url, radius: 8); let blurSeconds = Date().timeIntervalSince(start)
        print("DETERMINISTIC_512_COLD_SECONDS flip=\(flipSeconds) rotate=\(rotateSeconds) invert=\(invertSeconds) blur=\(blurSeconds)")
        let flipped = try await media.validateImage(flip), rotated = try await media.validateImage(rotate), inverted = try await media.validateImage(inverse), blurred = try await media.validateImage(blur)
        XCTAssertEqual(flipped.width, 512); XCTAssertEqual(rotated.height, 512)
        XCTAssertGreaterThan(try pixel(flipped, x: 64, y: 64)[2], 0.95)
        XCTAssertGreaterThan(try pixel(rotated, x: 64, y: 64)[0], 0.95)
        XCTAssertGreaterThan(try pixel(rotated, x: 64, y: 448)[2], 0.95)
        let cyan = try pixel(inverted, x: 64, y: 64)
        XCTAssertLessThan(cyan[0], 0.05); XCTAssertGreaterThan(cyan[1], 0.95); XCTAssertGreaterThan(cyan[2], 0.95); XCTAssertEqual(cyan[3], 1, accuracy: 0.01)
        let edge = try pixel(blurred, x: 255, y: 64)
        XCTAssertGreaterThan(edge[0], 0.1); XCTAssertGreaterThan(edge[2], 0.1); XCTAssertEqual(edge[3], 1, accuracy: 0.01)
        XCTAssertEqual(Set([flip, rotate, inverse, blur]).count, 4)
    }
    func testRectangularQuarterTurnsHaveExactDimensionsAndPixelPositions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 4, height = 2
        // Every position has a distinct red-channel value, so orientation and padding are observable.
        let pixels: [UInt8] = (0..<8).flatMap { [UInt8(($0 + 1) * 28), UInt8(0), UInt8(0), UInt8(255)] }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let original = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = root.appending(path: "rectangle.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let processor = MediaProcessor(root: root)
        for turns in 0...3 {
            let url = try await processor.rotateFlip(source, quarterTurns: turns, horizontal: false, vertical: false)
            let result = try await processor.validateImage(url)
            XCTAssertEqual(result.width, turns.isMultiple(of: 2) ? width : height)
            XCTAssertEqual(result.height, turns.isMultiple(of: 2) ? height : width)
            for y in 0..<height {
                for x in 0..<width {
                    let destination: (x: Int, y: Int) = switch turns {
                    case 1: (height - 1 - y, x)
                    case 2: (width - 1 - x, height - 1 - y)
                    case 3: (y, width - 1 - x)
                    default: (x, y)
                    }
                    let actual = try pixel(result, x: destination.x, y: destination.y)
                    XCTAssertEqual(actual[0], Double(pixels[(y * width + x) * 4]) / 255, accuracy: 0.02, "Rotation \(turns * 90) at \(x),\(y)")
                    XCTAssertEqual(actual[3], 1, accuracy: 0.001)
                }
            }
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Double] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Double(bytes[(y * image.width + x) * 4 + $0]) / 255 }
    }
}
