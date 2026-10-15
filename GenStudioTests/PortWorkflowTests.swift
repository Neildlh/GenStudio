import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

final class PortWorkflowTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioPortTests-\(UUID().uuidString)") }
    private func edge(_ source: StudioNode, _ output: String, _ target: StudioNode, _ input: String, _ type: PortDataType) -> StudioEdge { .init(sourceID: source.id, sourcePortID: output, targetID: target.id, targetPortID: input, type: type) }

    func testRealV1UIFixtureMigratesWithoutNewKeys() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/evidence/node-wiring-v1-ui-fixture.json")
        let data = try Data(contentsOf: file)
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "sourcePortID"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(WorkflowProject.self, from: data)
        XCTAssertEqual(project.schemaVersion, 3); XCTAssertEqual(project.nodes.first?.outputPorts.first?.id, "text")
    }

    func testV2CharacterSheetMigratesToDirectReferenceWorkflow() throws {
        let image = StudioNode(kind: .imageInput, label: "Reference", position: .init(x: 0, y: 0), imagePath: "/tmp/reference.png")
        let sheet = StudioNode(kind: .characterSheet, label: "Sheet", position: .init(x: 1, y: 0), prompt: "Describe the picture", model: "vision-model", dynamicInputs: [.init(id: "image", label: "Image 1", type: .image)])
        let generator = StudioNode(kind: .imageGenerator, label: "Generate", position: .init(x: 2, y: 0), model: "image-model")
        let legacy = WorkflowProject(schemaVersion: 2, name: "Legacy sheet", nodes: [image, sheet, generator], edges: [
            edge(image, "image", sheet, "image", .image),
            edge(sheet, "text", generator, "prompt", .text)
        ])

        let migrated = try JSONDecoder().decode(WorkflowProject.self, from: JSONEncoder().encode(legacy))
        let migratedSheet = try XCTUnwrap(migrated.nodes.first(where: { $0.id == sheet.id }))
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertTrue(migratedSheet.inputPorts.isEmpty)
        XCTAssertTrue(migratedSheet.dynamicInputs.isEmpty)
        XCTAssertEqual(migratedSheet.model, "")
        XCTAssertEqual(migratedSheet.prompt, StudioNode.characterSheetPrompt(for: .person))
        XCTAssertFalse(migrated.edges.contains(where: { $0.targetID == sheet.id }))
        XCTAssertTrue(migrated.edges.contains(where: { $0.sourceID == sheet.id && $0.targetID == generator.id && $0.type == .text }))
    }

    func testPopulatedV1EdgesMapToExactPerKindPorts() throws {
        let promptID = UUID(), modelID = UUID()
        let json = """
        {"schemaVersion":1,"id":"\(UUID())","name":"legacy","nodes":[{"id":"\(promptID)","kind":"prompt","label":"P","position":{"x":0,"y":0},"prompt":"hello"},{"id":"\(modelID)","kind":"textModel","label":"M","position":{"x":1,"y":1},"model":"stub"}],"edges":[{"id":"\(UUID())","sourceID":"\(promptID)","targetID":"\(modelID)","type":"text"}]}
        """
        let project = try JSONDecoder().decode(WorkflowProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.edges.first?.sourcePortID, "text"); XCTAssertEqual(project.edges.first?.targetPortID, "prompt")
    }

    func testDynamicPortIDsSurviveRemoveReopenAppendAndPreserveOrder() async throws {
        let temp = root(); defer { try? FileManager.default.removeItem(at: temp) }
        var combine = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 0, y: 0), separator: "|", dynamicInputs: [.init(id: "one", label: "One"), .init(id: "middle", label: "Middle"), .init(id: "three", label: "Three")])
        combine.dynamicInputs.remove(at: 1)
        let project = WorkflowProject(name: "slots", nodes: [combine], edges: [])
        let store = StudioPersistence(root: temp); try await store.saveProject(project)
        let loaded = try await store.loadProjects()
        var reopened = try XCTUnwrap(loaded.first)
        reopened.nodes[0].dynamicInputs.append(.init(id: "four", label: "Four"))
        XCTAssertEqual(reopened.nodes[0].dynamicInputs.map(\.id), ["one", "three", "four"])
        let sources = ["first", "third", "fourth"].enumerated().map { StudioNode(kind: .prompt, label: "P\($0.offset)", position: .init(x: 0, y: Double($0.offset)), prompt: $0.element) }
        reopened.nodes += sources
        reopened.edges = [edge(sources[0], "text", reopened.nodes[0], "one", .text), edge(sources[1], "text", reopened.nodes[0], "three", .text), edge(sources[2], "text", reopened.nodes[0], "four", .text)]
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: reopened, targetID: reopened.nodes[0].id)
        XCTAssertEqual(result.values[.init(nodeID: reopened.nodes[0].id, portID: "text")], .text("first|third|fourth"))
        let empty = WorkflowProject(name: "literal", nodes: [StudioNode(kind: .promptTemplate, label: "Literal", position: .init(x: 0, y: 0), prompt: "literal", dynamicInputs: [])], edges: [])
        try await store.saveProject(empty)
        let allProjects = try await StudioPersistence(root: temp).loadProjects()
        let literal = try XCTUnwrap(allProjects.first(where: { $0.id == empty.id }))
        XCTAssertTrue(literal.nodes[0].dynamicInputs.isEmpty)
    }

    func testOrderedCombineExecutesInSocketOrder() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let p1 = StudioNode(kind: .prompt, label: "One", position: .init(x: 0, y: 0), prompt: "alpha")
        let p2 = StudioNode(kind: .prompt, label: "Two", position: .init(x: 0, y: 1), prompt: "beta")
        let combine = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0), separator: "|", dynamicInputs: [.init(id: "first", label: "First"), .init(id: "second", label: "Second")])
        let preview = StudioNode(kind: .textPreview, label: "Preview", position: .init(x: 2, y: 0))
        let project = WorkflowProject(name: "ordered", nodes: [p1, p2, combine, preview], edges: [edge(p1, "text", combine, "first", .text), edge(p2, "text", combine, "second", .text), edge(combine, "text", preview, "text", .text)])
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: temp)).execute(project: project, targetID: preview.id)
        XCTAssertEqual(result.values[.init(nodeID: preview.id, portID: "text")], .text("alpha|beta"))
    }

    func testMissingPortDuplicateOccupiedAndCycleAreRejected() throws {
        let p = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "x")
        let preview = StudioNode(kind: .textPreview, label: "V", position: .init(x: 1, y: 0))
        let valid = edge(p, "text", preview, "text", .text)
        XCTAssertThrowsError(try GraphValidator().validate(.init(name: "missing", nodes: [p, preview], edges: [.init(sourceID: p.id, sourcePortID: "missing", targetID: preview.id, targetPortID: "text", type: .text)])))
        XCTAssertThrowsError(try GraphValidator().validate(.init(name: "duplicate", nodes: [p, preview], edges: [valid, valid])))
    }

    func testMaskInputRequiresAReadableFile() {
        let node = StudioNode(kind: .maskInput, label: "Mask", position: .init(x: 0, y: 0))
        XCTAssertThrowsError(try GraphValidator().validate(.init(name: "mask", nodes: [node], edges: [])))
    }

    func testOlderNodesDecodeMaskOperationDefaults() throws {
        let node = StudioNode(kind: .maskOperations, label: "M", position: .init(x: 0, y: 0))
        let json = """
        {"id":"\(node.id)","kind":"maskOperations","label":"M","position":{"x":0,"y":0}}
        """
        let decoded = try JSONDecoder().decode(StudioNode.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.maskInvert); XCTAssertEqual(decoded.maskGrowShrink, 0); XCTAssertEqual(decoded.maskFeather, 0)
    }

    func testFanoutBranchesConvergeWithOneUpstreamGeneration() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "once")
        let generated = StudioNode(kind: .textModel, label: "M", position: .init(x: 1, y: 0), model: "stub")
        let left = StudioNode(kind: .textRouter, label: "L", position: .init(x: 2, y: 0))
        let right = StudioNode(kind: .textRouter, label: "R", position: .init(x: 2, y: 1))
        let combine = StudioNode(kind: .combineText, label: "C", position: .init(x: 3, y: 0), separator: "|", dynamicInputs: [.init(id: "left", label: "Left"), .init(id: "right", label: "Right")])
        let edges = [edge(prompt, "text", generated, "prompt", .text), edge(generated, "text", left, "text", .text), edge(generated, "text", right, "text", .text), edge(left, "a", combine, "left", .text), edge(right, "b", combine, "right", .text)]
        let engine = StubEngine(result: "generated")
        let result = try await ExecutionQueue(engine: engine, persistence: StudioPersistence(root: temp)).execute(project: .init(name: "fanout", nodes: [prompt, generated, left, right, combine], edges: edges), targetID: combine.id, installedModels: ["stub"])
        let prompts = await engine.capturedPrompts()
        XCTAssertEqual(prompts, ["once"])
        XCTAssertEqual(result.values[.init(nodeID: combine.id, portID: "text")], .text("generated|generated"))
    }
}

final class MediaProcessorTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioMediaTests-\(UUID().uuidString)") }
    private func image(_ url: URL, width: Int = 4, height: Int = 2, red: CGFloat, blue: CGFloat) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)); let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [red, 0, blue, 1]))); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)); CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func color(_ image: CGImage) throws -> NSColor {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: CGFloat(bytes[3]) / 255)
    }
    /// A black canvas with a white square, for mask morphology/feather tests. Grayscale content
    /// (R = G = B everywhere) keeps morphology and blur behaving as expected on a single channel.
    private func mask(_ url: URL, canvas: Int = 40, squareOrigin: Int = 10, squareSize: Int = 20) throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [0, 0, 0, 1]))); context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: space, components: [1, 1, 1, 1]))); context.fill(CGRect(x: squareOrigin, y: squareOrigin, width: squareSize, height: squareSize))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)); CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    /// Average brightness of one rectangular region, in the same bottom-left-origin coordinate space
    /// CGContext fills and CIImage crops both already use — this sidesteps ever needing to reason about
    /// bitmap row order, since authoring and measurement never leave that shared coordinate space.
    private func regionAverage(_ image: CGImage, rect: CGRect) throws -> CGFloat {
        let cropped = CIImage(cgImage: image).cropped(to: rect)
        let filter = try XCTUnwrap(CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: cropped, kCIInputExtentKey: CIVector(cgRect: rect)]))
        let output = try XCTUnwrap(filter.outputImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return CGFloat(pixel[0]) / 255
    }

    func testMediaExportPreservesSelfAndExistingDestinationOnFailure() throws {
        let temp = root(); defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appending(path: "source.png"), destination = temp.appending(path: "export.png")
        let original = Data("source pixels".utf8), prior = Data("prior export".utf8)
        try original.write(to: source); try prior.write(to: destination)
        try MediaExport.copy(source: source, destination: source)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertThrowsError(try MediaExport.copy(source: temp.appending(path: "missing.png"), destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), prior)
        try MediaExport.copy(source: source, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testRealResizeCropBlendPixelsAndUniqueArtifacts() async throws {
        let temp = root(); defer { try? FileManager.default.removeItem(at: temp) }; try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let red = temp.appending(path: "red.png"), blue = temp.appending(path: "blue.png"); try image(red, red: 1, blue: 0); try image(blue, red: 0, blue: 1)
        let processor = MediaProcessor(root: temp)
        let resized = try await processor.resize(red, width: 8, height: 6); let crop = try await processor.crop(resized, x: 0, y: 0, width: 0.5, height: 0.5); let blend = try await processor.blend(background: red, foreground: blue, opacity: 0.5)
        let resizedImage = try await processor.validateImage(resized), cropImage = try await processor.validateImage(crop), blendImage = try await processor.validateImage(blend)
        XCTAssertEqual([resizedImage.width, resizedImage.height], [8, 6]); XCTAssertEqual([cropImage.width, cropImage.height], [4, 3]); XCTAssertEqual([blendImage.width, blendImage.height], [4, 2]); XCTAssertNotEqual(resized, crop); XCTAssertNotEqual(crop, blend)
        let cropColor = try color(cropImage), blendColor = try color(blendImage)
        XCTAssertEqual(cropColor.redComponent, 1, accuracy: 0.02); XCTAssertEqual(cropColor.blueComponent, 0, accuracy: 0.02)
        XCTAssertEqual(blendColor.redComponent, 0.5, accuracy: 0.08); XCTAssertEqual(blendColor.blueComponent, 0.5, accuracy: 0.08); XCTAssertEqual(blendColor.alphaComponent, 1, accuracy: 0.02)
        await XCTAssertThrowsErrorAsync { _ = try await processor.resize(red, width: 16_384, height: 16_384) }
    }

    func testColourCorrectTransfersSourceColourToGeneratedImage() async throws {
        let temp = root(); defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appending(path: "source.png"), generated = temp.appending(path: "generated.png")
        try image(source, red: 1, blue: 0)
        try image(generated, red: 0, blue: 1)
        let processor = MediaProcessor(root: temp)
        let output = try await processor.colourCorrect(source: source, generated: generated)
        let corrected = try color(try await processor.validateImage(output))
        XCTAssertEqual(corrected.redComponent, 1, accuracy: 0.03)
        XCTAssertEqual(corrected.greenComponent, 0, accuracy: 0.03)
        XCTAssertEqual(corrected.blueComponent, 0, accuracy: 0.03)

        let node = StudioNode(kind: .colourCorrect, label: "Colour Correct", position: .init(x: 0, y: 0))
        XCTAssertEqual(node.kind.category, "Image Editing")
        XCTAssertEqual(node.inputPorts.map(\.id), ["source", "generated"])
        XCTAssertEqual(node.outputPorts.first?.id, "image")
    }

    func testVideoFrameResizePreviewReopensAfterOwnedSourceDeletion() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "docs/evidence/sd-media/wan-pinwheel-quality.mp4")
        let clip = temp.appending(path: "owned-input.mp4"); try FileManager.default.copyItem(at: fixture, to: clip)
        let video = StudioNode(kind: .videoInput, label: "Video", position: .init(x: 0, y: 0), videoPath: clip.path)
        let frame = StudioNode(kind: .extractFrame, label: "Frame", position: .init(x: 1, y: 0), numberValue: 0.5)
        let resize = StudioNode(kind: .imageResize, label: "Resize", position: .init(x: 2, y: 0), width: 32, height: 24)
        let preview = StudioNode(kind: .imagePreview, label: "Preview", position: .init(x: 3, y: 0))
        let edges = [StudioEdge(sourceID: video.id, sourcePortID: "video", targetID: frame.id, targetPortID: "video", type: .video), StudioEdge(sourceID: frame.id, sourcePortID: "image", targetID: resize.id, targetPortID: "image", type: .image), StudioEdge(sourceID: resize.id, sourcePortID: "image", targetID: preview.id, targetPortID: "image", type: .image)]
        let store = StudioPersistence(root: temp)
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: .init(name: "video pipeline", nodes: [video, frame, resize, preview], edges: edges), targetID: preview.id)
        guard case .image(let retained)? = result.values[.init(nodeID: preview.id, portID: "image")] else { return XCTFail("Expected retained preview") }
        let retainedImage = try await MediaProcessor(root: temp).validateImage(retained)
        XCTAssertEqual([retainedImage.width, retainedImage.height], [32, 24])
        try FileManager.default.removeItem(at: clip)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: retained.path))
        let artifacts = try await StudioPersistence(root: temp).loadExecutionArtifacts()
        XCTAssertEqual(artifacts.first?.graphSnapshot.nodes.first(where: { $0.id == frame.id })?.numberValue, 0.5)
        guard case .image(let reopened)? = artifacts.first?.values[.init(nodeID: preview.id, portID: "image")] else { return XCTFail("Expected reopened preview") }
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: reopened.path))
    }

    func testMaskOperationsValidatesExactSourceDimensions() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let maskURL = temp.appending(path: "mask.png"); try mask(maskURL)
        let mismatched = temp.appending(path: "mismatched.png"); try image(mismatched, width: 4, height: 2, red: 0, blue: 0)
        let processor = MediaProcessor(root: temp)
        await XCTAssertThrowsErrorAsync { _ = try await processor.maskOperations(maskURL, invert: false, growOrShrink: 0, featherRadius: 0, matchingSize: mismatched) }
        let matched = temp.appending(path: "matched.png"); try mask(matched)
        _ = try await processor.maskOperations(maskURL, invert: false, growOrShrink: 0, featherRadius: 0, matchingSize: matched)
    }

    func testMaskOperationsRejectsOutOfBoundsParameters() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appending(path: "source.png"); try mask(source)
        let processor = MediaProcessor(root: temp)
        await XCTAssertThrowsErrorAsync { _ = try await processor.maskOperations(source, invert: false, growOrShrink: 300, featherRadius: 0) }
        await XCTAssertThrowsErrorAsync { _ = try await processor.maskOperations(source, invert: false, growOrShrink: 0, featherRadius: 200) }
    }

    func testMaskOperationsInvertGrowShrinkAndFeather() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appending(path: "source.png"); try mask(source) // black 40×40, white square at 10...30
        let processor = MediaProcessor(root: temp)
        let outsideBand = CGRect(x: 7, y: 10, width: 2, height: 20) // 3px left of the square's edge, full square height
        let insideBand = CGRect(x: 10, y: 10, width: 2, height: 20) // just inside the square's left edge

        let plain = try await processor.validateImage(try await processor.maskOperations(source, invert: false, growOrShrink: 0, featherRadius: 0))
        XCTAssertEqual(try regionAverage(plain, rect: outsideBand), 0, accuracy: 0.02, "Untouched band outside the square starts pure black")

        let grown = try await processor.validateImage(try await processor.maskOperations(source, invert: false, growOrShrink: 5, featherRadius: 0))
        XCTAssertGreaterThan(try regionAverage(grown, rect: outsideBand), 0.5, "Growing the mask by 5px should cover a band 3px outside the original edge")

        let shrunk = try await processor.validateImage(try await processor.maskOperations(source, invert: false, growOrShrink: -5, featherRadius: 0))
        XCTAssertLessThan(try regionAverage(shrunk, rect: insideBand), 0.5, "Shrinking the mask by 5px should uncover a band just inside the original edge")

        let inverted = try await processor.validateImage(try await processor.maskOperations(source, invert: true, growOrShrink: 0, featherRadius: 0))
        XCTAssertGreaterThan(try regionAverage(inverted, rect: outsideBand), 0.9, "Invert flips the outside band from black to white")

        let feathered = try await processor.validateImage(try await processor.maskOperations(source, invert: false, growOrShrink: 0, featherRadius: 8))
        XCTAssertGreaterThan(try regionAverage(feathered, rect: outsideBand), 0.05, "Feathering bleeds white across the hard edge into the outside band")
        XCTAssertLessThan(try regionAverage(feathered, rect: outsideBand), 0.9, "Feathering alone should not fully whiten a band 3px outside the edge")
    }

    func testMaskInputAndMaskOperationsExecuteEndToEndWithSizeValidation() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let maskFile = temp.appending(path: "mask.png"); try mask(maskFile)
        let matchingSource = temp.appending(path: "source-match.png"); try mask(matchingSource)
        let mismatchedSource = temp.appending(path: "source-mismatch.png"); try image(mismatchedSource, width: 4, height: 2, red: 0, blue: 0)
        let persistence = StudioPersistence(root: temp)

        let maskInput = StudioNode(kind: .maskInput, label: "Mask", position: .init(x: 0, y: 0), imagePath: maskFile.path)
        var sourceInput = StudioNode(kind: .imageInput, label: "Source", position: .init(x: 0, y: 1), imagePath: matchingSource.path)
        var operations = StudioNode(kind: .maskOperations, label: "Ops", position: .init(x: 1, y: 0))
        operations.maskGrowShrink = 5
        let edges = [
            StudioEdge(sourceID: maskInput.id, sourcePortID: "image", targetID: operations.id, targetPortID: "mask", type: .image),
            StudioEdge(sourceID: sourceInput.id, sourcePortID: "image", targetID: operations.id, targetPortID: "source", type: .image)
        ]
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: persistence).execute(project: .init(name: "mask", nodes: [maskInput, sourceInput, operations], edges: edges), targetID: operations.id)
        guard case .image(let output)? = result.values[.init(nodeID: operations.id, portID: "mask")] else { return XCTFail("Expected a mask output") }
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: output.path))

        sourceInput.imagePath = mismatchedSource.path
        await XCTAssertThrowsErrorAsync {
            _ = try await ExecutionQueue(engine: StubEngine(), persistence: persistence).execute(project: .init(name: "mask-mismatch", nodes: [maskInput, sourceInput, operations], edges: edges), targetID: operations.id)
        }
    }

    func testCompareExecutesDistinctImagesAndSelection() async throws {
        let temp = root(); try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: temp) }
        let red = temp.appending(path: "compare-red.png"), blue = temp.appending(path: "compare-blue.png")
        try image(red, red: 1, blue: 0); try image(blue, red: 0, blue: 1)
        let a = StudioNode(kind: .imageInput, label: "A", position: .init(x: 0, y: 0), imagePath: red.path)
        let b = StudioNode(kind: .imageInput, label: "B", position: .init(x: 0, y: 1), imagePath: blue.path)
        var compare = StudioNode(kind: .imageCompare, label: "Compare", position: .init(x: 1, y: 0), comparisonSelection: 0)
        let edges = [StudioEdge(sourceID: a.id, sourcePortID: "image", targetID: compare.id, targetPortID: "a", type: .image), StudioEdge(sourceID: b.id, sourcePortID: "image", targetID: compare.id, targetPortID: "b", type: .image)]
        let persistence = StudioPersistence(root: temp)
        let first = try await ExecutionQueue(engine: StubEngine(), persistence: persistence).execute(project: .init(name: "compare", nodes: [a, b, compare], edges: edges), targetID: compare.id)
        XCTAssertNotEqual(first.values[.init(nodeID: compare.id, portID: "a")], first.values[.init(nodeID: compare.id, portID: "b")])
        XCTAssertEqual(first.values[.init(nodeID: compare.id, portID: "selected")], first.values[.init(nodeID: compare.id, portID: "a")])
        compare.comparisonSelection = 1
        let second = try await ExecutionQueue(engine: StubEngine(), persistence: persistence).execute(project: .init(name: "compare", nodes: [a, b, compare], edges: edges), targetID: compare.id)
        XCTAssertEqual(second.values[.init(nodeID: compare.id, portID: "selected")], second.values[.init(nodeID: compare.id, portID: "b")])
    }
}

func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await expression(); XCTFail("Expected error", file: file, line: line) } catch { }
}
