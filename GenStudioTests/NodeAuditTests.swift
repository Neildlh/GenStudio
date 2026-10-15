import AppKit
import CoreGraphics
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

/// Regression tests from the full node audit. Each test states the behaviour a
/// node's purpose requires; see docs/NODE_AUDIT.md for the finding behind it.
@MainActor
final class DynamicTextInputTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioAudit-\(UUID().uuidString)") }
    private func prompt(_ text: String, _ y: Double = 0) -> StudioNode { StudioNode(kind: .prompt, label: text, position: .init(x: 0, y: y), prompt: text) }
    private func edge(_ source: StudioNode, _ sourcePort: String = "text", _ target: StudioNode, _ targetPort: String) -> StudioEdge {
        .init(sourceID: source.id, sourcePortID: sourcePort, targetID: target.id, targetPortID: targetPort, type: .text)
    }
    private func makeModel(_ project: WorkflowProject) -> StudioModel {
        let model = StudioModel(persistence: StudioPersistence(root: root()), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id
        return model
    }
    private func combine(in model: StudioModel, _ id: UUID) throws -> StudioNode { try XCTUnwrap(model.currentProject?.nodes.first { $0.id == id }) }
    private func connectedIDs(_ model: StudioModel, _ id: UUID) -> Set<String> { Set(model.currentProject?.edges.filter { $0.targetID == id }.map(\.targetPortID) ?? []) }

    /// The reported defect: a Combine Text node offered one socket, so a second wire replaced the first.
    func testCombineTextAlwaysOffersAFreeSocketSoEveryWireIsKept() throws {
        let sources = (0..<4).map { prompt("P\($0)", Double($0)) }
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0))
        let model = makeModel(WorkflowProject(name: "many", nodes: sources + [joiner], edges: []))
        for source in sources {
            let node = try combine(in: model, joiner.id)
            let free = try XCTUnwrap(node.inputPorts.first { !connectedIDs(model, joiner.id).contains($0.id) }, "A free socket must always be available")
            model.connect(sourceID: source.id, sourcePortID: "text", targetID: joiner.id, targetPortID: free.id, replacing: true)
        }
        XCTAssertEqual(model.currentProject?.edges.filter { $0.targetID == joiner.id }.count, 4, "Connecting to the free socket must never replace an earlier wire")
        let final = try combine(in: model, joiner.id)
        XCTAssertFalse(final.inputPorts.allSatisfy { connectedIDs(model, joiner.id).contains($0.id) }, "A spare socket must remain after the last connection")
    }

    func testDroppingOnTheCardBodyKeepsGrowingTheSocketList() throws {
        let sources = (0..<3).map { prompt("P\($0)", Double($0)) }
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0))
        let model = makeModel(WorkflowProject(name: "body", nodes: sources + [joiner], edges: []))
        for source in sources { model.connectToBody(sourceID: source.id, sourcePortID: "text", targetID: joiner.id) }
        XCTAssertEqual(connectedIDs(model, joiner.id).count, 3)
        XCTAssertNil(model.alertMessage)
    }

    func testFreshCombineTextShowsTwoSocketsAndDisconnectingTrimsSurplusSpares() throws {
        let a = prompt("a"), b = prompt("b", 1), c = prompt("c", 2)
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0))
        XCTAssertEqual(joiner.inputPorts.count, 2, "Joining needs at least two parts to be legible")
        let model = makeModel(WorkflowProject(name: "trim", nodes: [a, b, c, joiner], edges: []))
        for source in [a, b, c] { model.connectToBody(sourceID: source.id, sourcePortID: "text", targetID: joiner.id) }
        XCTAssertEqual(try combine(in: model, joiner.id).inputPorts.count, 4)
        let last = try XCTUnwrap(model.currentProject?.edges.last)
        model.disconnect(edgeID: last.id)
        XCTAssertEqual(try combine(in: model, joiner.id).inputPorts.count, 3, "Exactly one trailing free socket remains")
    }

    func testRemovingAPartRenumbersAutomaticLabelsInOrder() throws {
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0), dynamicInputs: [.init(id: "1", label: "Part 1"), .init(id: "2", label: "Part 2"), .init(id: "3", label: "Part 3")])
        let model = makeModel(WorkflowProject(name: "renumber", nodes: [joiner], edges: []))
        model.removeDynamicInput(nodeID: joiner.id, portID: "2")
        XCTAssertEqual(try combine(in: model, joiner.id).dynamicInputs.map(\.label), ["Part 1", "Part 2"])
    }

    func testPartsCanBeReorderedAndRenamedAndOrderDrivesTheOutput() async throws {
        let a = prompt("alpha"), b = prompt("beta", 1)
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0), separator: "|", dynamicInputs: [.init(id: "one", label: "One"), .init(id: "two", label: "Two")])
        let model = makeModel(WorkflowProject(name: "order", nodes: [a, b, joiner], edges: [edge(a, "text", joiner, "one"), edge(b, "text", joiner, "two")]))
        model.moveDynamicInput(nodeID: joiner.id, portID: "two", by: -1)
        XCTAssertEqual(try combine(in: model, joiner.id).dynamicInputs.map(\.id).prefix(2), ["two", "one"])
        model.renameDynamicInput(nodeID: joiner.id, portID: "two", to: "  Style  ")
        XCTAssertEqual(try combine(in: model, joiner.id).dynamicInputs.first { $0.id == "two" }?.label, "Style")
        model.renameDynamicInput(nodeID: joiner.id, portID: "two", to: "   ")
        XCTAssertEqual(try combine(in: model, joiner.id).dynamicInputs.first { $0.id == "two" }?.label, "Style", "A blank name is ignored")
        let queue = ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root()))
        let result = try await queue.execute(project: try XCTUnwrap(model.currentProject), targetID: joiner.id)
        XCTAssertEqual(result.values[.init(nodeID: joiner.id, portID: "text")], .text("beta|alpha"))
    }

    func testUnconnectedSpareSocketDoesNotBlockARunButANodeWithNoInputDoes() throws {
        let a = prompt("alpha")
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0), dynamicInputs: [.init(id: "one", label: "One"), .init(id: "two", label: "Two")])
        let ok = WorkflowProject(name: "ok", nodes: [a, joiner], edges: [edge(a, "text", joiner, "one")])
        XCTAssertNoThrow(try GraphValidator().validate(ok))
        let empty = WorkflowProject(name: "empty", nodes: [joiner], edges: [])
        XCTAssertThrowsError(try GraphValidator().validate(empty)) { XCTAssertTrue($0.localizedDescription.contains("at least one"), $0.localizedDescription) }
    }

    /// A project saved before the free-socket rule has every socket wired; the first wire dropped on it would replace one.
    func testOpeningAnOlderProjectRestoresTheFreeSocket() async throws {
        let a = prompt("alpha"), b = prompt("beta", 1)
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0), dynamicInputs: [.init(id: "one", label: "Part 1"), .init(id: "two", label: "Part 2")])
        let saved = WorkflowProject(name: "older", nodes: [a, b, joiner], edges: [edge(a, "text", joiner, "one"), edge(b, "text", joiner, "two")])
        let store = StudioPersistence(root: root())
        try await store.saveProject(saved)
        let model = StudioModel(persistence: store, engine: StubEngine())
        await model.start()
        let opened = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == joiner.id })
        XCTAssertEqual(opened.inputPorts.count, 3)
        XCTAssertEqual(model.currentProject?.edges.count, 2, "Opening must not disturb any connection")
        await model.flushProjectWrites()
        let reloaded = try await StudioPersistence(root: store.root).loadProjects()
        XCTAssertEqual(reloaded.first?.nodes.first { $0.id == joiner.id }?.inputPorts.count, 3, "The corrected project is saved")
    }

    func testEmptyPartsAreSkippedSoNoStraySeparatorRemains() async throws {
        let a = prompt("alpha"), blank = StudioNode(kind: .videoPrompt, label: "V", position: .init(x: 0, y: 1)), c = prompt("gamma", 2)
        var video = blank
        video.videoPromptSettings = VideoPromptSettings(); video.videoPromptSettings?.action = "walks"
        let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0), separator: ", ", dynamicInputs: [.init(id: "one", label: "One"), .init(id: "avoid", label: "Avoid"), .init(id: "three", label: "Three")])
        let project = WorkflowProject(name: "skip", nodes: [a, video, c, joiner], edges: [
            edge(a, "text", joiner, "one"), edge(video, "avoid", joiner, "avoid"), edge(c, "text", joiner, "three")
        ])
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root())).execute(project: project, targetID: joiner.id)
        XCTAssertEqual(result.values[.init(nodeID: joiner.id, portID: "text")], .text("alpha, gamma"))
    }

    func testSeparatorAcceptsEscapedNewlinesAndTabs() async throws {
        let a = prompt("alpha"), b = prompt("beta", 1)
        for (separator, expected) in [("\\n", "alpha\nbeta"), ("\\n\\n", "alpha\n\nbeta"), ("\\t", "alpha\tbeta"), (", ", "alpha, beta"), ("\n", "alpha\nbeta")] {
            let joiner = StudioNode(kind: .combineText, label: "Combine", position: .init(x: 1, y: 0), separator: separator, dynamicInputs: [.init(id: "one", label: "One"), .init(id: "two", label: "Two")])
            let project = WorkflowProject(name: "sep", nodes: [a, b, joiner], edges: [edge(a, "text", joiner, "one"), edge(b, "text", joiner, "two")])
            let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root())).execute(project: project, targetID: joiner.id)
            XCTAssertEqual(result.values[.init(nodeID: joiner.id, portID: "text")], .text(expected), "separator \(separator.debugDescription)")
        }
    }
}

@MainActor
final class ImageGeneratorReferenceSocketTests: XCTestCase {
    private func image(_ label: String) -> StudioNode {
        StudioNode(kind: .imageInput, label: label, position: .init(x: 0, y: 0))
    }

    func testDroppingImageWiresOnGeneratorUsesReservedReferencesInOrder() throws {
        let sources = [image("A"), image("B"), image("C")]
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 1, y: 0))
        let project = WorkflowProject(name: "References", nodes: sources + [generator], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]
        model.currentProjectID = project.id

        for source in sources {
            model.connectToBody(sourceID: source.id, sourcePortID: "image", targetID: generator.id)
        }

        XCTAssertEqual(model.currentProject?.edges.filter { $0.targetID == generator.id }.map(\.targetPortID), ["referenceImage", "referenceImage2", "referenceImage3"])
        XCTAssertTrue(model.currentProject?.nodes.first { $0.id == generator.id }?.dynamicInputs.isEmpty == true)
    }

    func testAddingReferenceDoesNotCreateAnUnsupportedFourthSocket() throws {
        let sources = [image("A"), image("B"), image("C"), image("D")]
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 1, y: 0))
        let project = WorkflowProject(name: "References", nodes: sources + [generator], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]
        model.currentProjectID = project.id

        model.addDynamicInput(to: generator.id)
        for source in sources { model.connectToBody(sourceID: source.id, sourcePortID: "image", targetID: generator.id) }

        let saved = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == generator.id })
        XCTAssertTrue(saved.dynamicInputs.isEmpty)
        XCTAssertEqual(saved.imageGeneratorReferencePortIDs, ["referenceImage", "referenceImage2", "referenceImage3"])
        XCTAssertEqual(model.currentProject?.edges.filter { $0.targetID == generator.id }.count, 3)
        XCTAssertEqual(model.alertMessage, "No free compatible input is available on Generator.")
    }
}

@MainActor
final class PromptTemplateTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioAudit-\(UUID().uuidString)") }
    private func prompt(_ text: String) -> StudioNode { StudioNode(kind: .prompt, label: text, position: .init(x: 0, y: 0), prompt: text) }
    private func template(_ text: String, variables: [String]) -> StudioNode {
        StudioNode(kind: .promptTemplate, label: "Template", position: .init(x: 1, y: 0), prompt: text, dynamicInputs: variables.map { .init(id: "v-\($0)", label: $0) })
    }
    private func wire(_ source: StudioNode, _ target: StudioNode, _ variable: String) -> StudioEdge {
        .init(sourceID: source.id, sourcePortID: "text", targetID: target.id, targetPortID: "v-\(variable)", type: .text)
    }

    func testVariableNamesTolerateSpacesInsideTheBraces() async throws {
        let name = prompt("Ada"), node = template("Hello {{ name }}!", variables: ["name"])
        let project = WorkflowProject(name: "t", nodes: [name, node], edges: [wire(name, node, "name")])
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root())).execute(project: project, targetID: node.id)
        XCTAssertEqual(result.values[.init(nodeID: node.id, portID: "text")], .text("Hello Ada!"))
    }

    func testPreflightNamesAVariableTheTemplateUsesButNothingSupplies() throws {
        let name = prompt("Ada")
        let unknown = template("Hello {{nmae}}", variables: ["name"])
        XCTAssertThrowsError(try GraphValidator().validate(.init(name: "typo", nodes: [name, unknown], edges: [wire(name, unknown, "name")]))) {
            XCTAssertTrue($0.localizedDescription.contains("nmae"), $0.localizedDescription)
        }
        let unwired = template("Hello {{name}}", variables: ["name"])
        XCTAssertThrowsError(try GraphValidator().validate(.init(name: "unwired", nodes: [unwired], edges: []))) {
            XCTAssertTrue($0.localizedDescription.contains("name"), $0.localizedDescription)
        }
    }

    func testAnUnusedUnconnectedVariableDoesNotBlockTheRun() throws {
        let name = prompt("Ada"), node = template("Hello {{name}}", variables: ["name", "spare"])
        XCTAssertNoThrow(try GraphValidator().validate(.init(name: "spare", nodes: [name, node], edges: [wire(name, node, "name")])))
    }

    func testFreshTemplateAndConnectingKeepAFreeVariableSocket() throws {
        let a = prompt("a"), b = prompt("b")
        var node = StudioNode(kind: .promptTemplate, label: "Template", position: .init(x: 1, y: 0), prompt: "{{Variable}} {{Variable 1}}")
        XCTAssertEqual(node.inputPorts.count, 1)
        let model = StudioModel(persistence: StudioPersistence(root: root()), engine: StubEngine())
        node.label = "Template"
        let project = WorkflowProject(name: "grow", nodes: [a, b, node], edges: [])
        model.projects = [project]; model.currentProjectID = project.id
        model.connectToBody(sourceID: a.id, sourcePortID: "text", targetID: node.id)
        model.connectToBody(sourceID: b.id, sourcePortID: "text", targetID: node.id)
        let grown = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == node.id })
        XCTAssertEqual(model.currentProject?.edges.filter { $0.targetID == node.id }.count, 2)
        XCTAssertEqual(grown.inputPorts.count, 3, "Two variables connected plus one free socket")
    }
}

final class NumberTextTests: XCTestCase {
    func testNumbersRenderWithoutRegionalDecimalSeparatorsOrGrouping() {
        XCTAssertEqual(NumberText.string(0.75), "0.75")
        XCTAssertEqual(NumberText.string(3), "3")
        XCTAssertEqual(NumberText.string(-2.5), "-2.5")
        XCTAssertEqual(NumberText.string(1_234_567.891), "1234567.891")
        XCTAssertEqual(NumberText.string(0.1234567), "0.1234567")
        XCTAssertEqual(NumberText.string(1e20), "100000000000000000000")
        XCTAssertEqual(NumberText.string(.nan), "0")
        XCTAssertEqual(NumberText.string(.infinity), "0")
    }

    func testTheExecutorUsesTheLocaleIndependentFormat() async throws {
        let number = StudioNode(kind: .number, label: "N", position: .init(x: 0, y: 0), numberValue: 0.75)
        let text = StudioNode(kind: .numberToText, label: "T", position: .init(x: 1, y: 0))
        let project = WorkflowProject(name: "n", nodes: [number, text], edges: [.init(sourceID: number.id, sourcePortID: "number", targetID: text.id, targetPortID: "text", type: .number)])
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioAudit-\(UUID().uuidString)")
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: text.id)
        XCTAssertEqual(result.values[.init(nodeID: text.id, portID: "text")], .text("0.75"))
    }

    func testTextArrayDelimiterAcceptsTheSameEscapes() throws {
        XCTAssertEqual(try TextArrayOperations.split("a\n\nb", delimiter: "\\n\\n", trim: true), ["a", "b"])
        XCTAssertEqual(try TextArrayOperations.split("a\tb", delimiter: "\\t", trim: false), ["a", "b"])
        XCTAssertEqual(try TextArrayOperations.split("a,b", delimiter: ",", trim: true), ["a", "b"])
    }
}

final class CropBoundsTests: XCTestCase {
    func testTheRuleIsExplainedAndToleratesBinaryRounding() {
        XCTAssertNil(CropBounds.issue(x: 0.7, y: 0, width: 0.3, height: 1), "0.7 + 0.3 must not fail on floating-point rounding")
        XCTAssertNil(CropBounds.issue(x: 0, y: 0, width: 1, height: 1))
        XCTAssertTrue(CropBounds.issue(x: 0.5, y: 0, width: 0.6, height: 1)?.contains("X + Width") == true)
        XCTAssertTrue(CropBounds.issue(x: 0, y: 0.9, width: 1, height: 0.2)?.contains("Y + Height") == true)
        XCTAssertNotNil(CropBounds.issue(x: -0.1, y: 0, width: 0.5, height: 0.5))
        XCTAssertNotNil(CropBounds.issue(x: 0, y: 0, width: 0, height: 0.5))
        XCTAssertNotNil(CropBounds.issue(x: .nan, y: 0, width: 0.5, height: 0.5))
    }
}

@MainActor
final class SingleValueSocketTests: XCTestCase {
    /// The always-free socket rule is only for repeatable inputs; a one-value socket must still be rewired by replacement.
    func testDroppingOnAnOccupiedSingleValueSocketReplacesItsWire() throws {
        let a = StudioNode(kind: .prompt, label: "A", position: .init(x: 0, y: 0), prompt: "a")
        let b = StudioNode(kind: .prompt, label: "B", position: .init(x: 0, y: 1), prompt: "b")
        let preview = StudioNode(kind: .textPreview, label: "V", position: .init(x: 1, y: 0))
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        let project = WorkflowProject(name: "single", nodes: [a, b, preview], edges: [])
        model.projects = [project]; model.currentProjectID = project.id
        model.connect(sourceID: a.id, sourcePortID: "text", targetID: preview.id, targetPortID: "text", replacing: true)
        model.connect(sourceID: b.id, sourcePortID: "text", targetID: preview.id, targetPortID: "text", replacing: true)
        let edges = try XCTUnwrap(model.currentProject?.edges)
        XCTAssertEqual(edges.count, 1); XCTAssertEqual(edges.first?.sourceID, b.id)
    }
}

final class GrayscaleImageProcessingTests: XCTestCase {
    private func grayPNG(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "gray.png")
        let space = CGColorSpaceCreateDeviceGray()
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0.5, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Masks are routinely saved as grayscale; every image node must accept them.
    func testImageNodesAcceptGrayscaleSources() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try grayPNG(in: root)
        let media = MediaProcessor(root: root)
        let resized = try await media.resize(source, width: 16, height: 8)
        let cropped = try await media.crop(source, x: 0, y: 0, width: 0.5, height: 0.5)
        let blended = try await media.blend(background: source, foreground: source, opacity: 0.5)
        let filled = try await media.aspectFill(source, width: 16, height: 16)
        for url in [resized, cropped, blended, filled] { _ = try await media.validateImage(url) }
        let size = try await media.validateImage(resized)
        XCTAssertEqual(size.width, 16); XCTAssertEqual(size.height, 8)
    }
}

final class RunConfirmationTests: XCTestCase {
    private func videoProject(model: String, frames: Int = 9) -> (WorkflowProject, UUID) {
        var node = StudioNode(kind: .textToVideo, label: "V", position: .init(x: 1, y: 0), model: model)
        node.video.frameCount = frames
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "x")
        let edge = StudioEdge(sourceID: prompt.id, sourcePortID: "text", targetID: node.id, targetPortID: "prompt", type: .text)
        return (WorkflowProject(name: "v", nodes: [prompt, node], edges: [edge]), node.id)
    }

    func testAMeasuredQuickVideoDraftJustRuns() {
        let (project, id) = videoProject(model: VideoCapabilityRegistry.wanT2VRecipeID)
        XCTAssertFalse(RunPlan.make(project: project, target: id).requiresConfirmation)
    }

    func testAnUnmeasuredVideoRecipeAlwaysAsksFirst() {
        let (project, id) = videoProject(model: VideoCapabilityRegistry.minimaxH3FirstLastFrame.recipeID)
        XCTAssertTrue(RunPlan.make(project: project, target: id).requiresConfirmation, "No measured timing means it could run for up to an hour")
    }

    func testAMeasuredVideoOverFiveMinutesAsksFirst() {
        let (project, id) = videoProject(model: VideoCapabilityRegistry.wanT2VRecipeID, frames: 65)
        XCTAssertTrue(RunPlan.make(project: project, target: id).requiresConfirmation)
    }

    func testFastMetalAndLTXAreTimedFromThisMacsMeasurements() {
        var (project, id) = videoProject(model: MLXVideoModelCatalog.fastMetal5BRecipeID)
        project.nodes[1].video = VideoCapabilityRegistry.fastMetal5TextToVideo.recommended
        let draft = RunPlan.make(project: project, target: id)
        XCTAssertEqual(draft.untimedVideoGenerations, 0)
        XCTAssertEqual(draft.estimatedVideoSeconds, 88, accuracy: 1)
        XCTAssertFalse(draft.requiresConfirmation, "A measured 1½-minute draft just runs")
        XCTAssertTrue(draft.summary.contains("roughly 88 seconds"), draft.summary)

        var (ltx, ltxID) = videoProject(model: MLXVideoModelCatalog.ltx23Q4RecipeID)
        ltx.nodes[1].video = VideoCapabilityRegistry.ltx23TextToVideo.recommended
        XCTAssertEqual(RunPlan.make(project: ltx, target: ltxID).estimatedVideoSeconds, 173, accuracy: 1)
    }

    func testMeasuredClipsAddingUpToMoreThanFiveMinutesAskFirst() {
        var (project, first) = videoProject(model: MLXVideoModelCatalog.ltx23Q4RecipeID)
        project.nodes[1].video = VideoCapabilityRegistry.ltx23TextToVideo.recommended
        var second = project.nodes[1]; second = StudioNode(kind: .textToVideo, label: "V2", position: .init(x: 1, y: 1), model: MLXVideoModelCatalog.ltx23Q4RecipeID)
        second.video = VideoCapabilityRegistry.ltx23TextToVideo.recommended
        project.nodes.append(second)
        project.edges.append(StudioEdge(sourceID: project.nodes[0].id, sourcePortID: "text", targetID: second.id, targetPortID: "prompt", type: .text))
        let plan = RunPlan.make(project: project, targets: [first, second.id])
        XCTAssertEqual(plan.estimatedVideoSeconds, 346, accuracy: 2)
        XCTAssertTrue(plan.requiresConfirmation)
    }
}


/// Structural invariants every node kind must satisfy, so a newly added or edited kind cannot silently break the canvas.
final class NodeKindInvariantTests: XCTestCase {
    func testEveryNodeKindIsWellFormed() throws {
        for kind in NodeKind.allCases {
            let node = StudioNode(kind: kind, label: kind.title, position: .init(x: 0, y: 0))
            XCTAssertFalse(kind.title.isEmpty, "\(kind)"); XCTAssertFalse(kind.detail.isEmpty, "\(kind)")
            XCTAssertTrue(NodeKind.categoryOrder.contains(kind.category), "\(kind) has no catalogue category")
            for ports in [node.inputPorts, node.outputPorts] {
                XCTAssertEqual(Set(ports.map(\.id)).count, ports.count, "\(kind) has duplicate port ids")
                XCTAssertTrue(ports.allSatisfy { !$0.id.trimmingCharacters(in: .whitespaces).isEmpty && !$0.label.isEmpty }, "\(kind) has an unnamed port")
            }
            if node.outputPorts.isEmpty { XCTAssertEqual(kind, .stickyNote, "\(kind) produces nothing") }
            XCTAssertTrue(NodeLayout.cardHeight(node) > 0 && NodeLayout.cardWidth(node) > 0, "\(kind) has no card size")
            XCTAssertFalse(kind.hidesCanvasRunControl && kind.usesModel, "\(kind) hides its Run button but needs a model run")
            if node.supportsTakes { XCTAssertTrue(node.outputPorts.first.map { [.image, .video].contains($0.type) } ?? false, "\(kind) keeps takes for a non-media output") }
            XCTAssertNoThrow(try GraphValidator().validate(.init(name: "fresh", nodes: [node], edges: []), requireRunnableInputs: false), "\(kind) does not validate when fresh")
            let decoded = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(node))
            XCTAssertEqual(decoded, node, "\(kind) does not survive save and reopen")
        }
    }

    func testEveryInputSocketCanBeFedByAtLeastOneNodeKind() {
        // No input socket is a dead end: some node kind produces its type.
        for kind in NodeKind.allCases {
            let node = StudioNode(kind: kind, label: kind.title, position: .init(x: 0, y: 0))
            for input in node.inputPorts {
                XCTAssertTrue(NodeKind.allCases.contains { StudioNode(kind: $0, label: "", position: .init(x: 0, y: 0)).outputPorts.contains { $0.type == input.type } }, "\(kind).\(input.label) can never be fed")
            }
        }
    }
}

/// Drives every deterministic (non-model) node through the real executor with real pixels, so port wiring and
/// value types are exercised end to end rather than only through the processors.
final class DeterministicNodeWorkflowTests: XCTestCase {
    private func root() throws -> URL { try VideoFixtures.root("deterministic") }
    private func node(_ kind: NodeKind, _ label: String, _ configure: (inout StudioNode) -> Void = { _ in }) -> StudioNode {
        var node = StudioNode(kind: kind, label: label, position: .init(x: 0, y: 0)); configure(&node); return node
    }
    private func wire(_ source: StudioNode, _ sourcePort: String, _ target: StudioNode, _ targetPort: String, _ type: PortDataType) -> StudioEdge {
        .init(sourceID: source.id, sourcePortID: sourcePort, targetID: target.id, targetPortID: targetPort, type: type)
    }
    private func size(_ value: RuntimeValue?, _ media: MediaProcessor) async throws -> (Int, Int) {
        guard case .image(let url) = value else { XCTFail("expected an image"); return (0, 0) }
        let image = try await media.validateImage(url); return (image.width, image.height)
    }

    func testTextNodesFlowEndToEnd() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let prompt = node(.prompt, "P") { $0.prompt = "red, green ,blue" }
        let array = node(.textArray, "A") { $0.arrayDelimiter = ","; $0.arrayTrim = true }
        let pick = node(.listSelect, "S") { $0.listIndex = 3 }
        let number = node(.number, "N") { $0.numberValue = 2.5 }
        let numberText = node(.numberToText, "NT")
        let combine = node(.combineText, "C") { $0.separator = " / "; $0.dynamicInputs = [.init(id: "a", label: "A"), .init(id: "b", label: "B"), .init(id: "c", label: "C")] }
        let router = node(.textRouter, "R")
        let preview = node(.textPreview, "V")
        let project = WorkflowProject(name: "text", nodes: [prompt, array, pick, number, numberText, combine, router, preview], edges: [
            wire(prompt, "text", array, "text", .text), wire(array, "items", pick, "items", .textArray),
            wire(number, "number", numberText, "text", .number),
            wire(pick, "text", combine, "a", .text), wire(numberText, "text", combine, "b", .text), wire(prompt, "text", router, "text", .text),
            wire(router, "b", combine, "c", .text), wire(combine, "text", preview, "text", .text)
        ])
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: preview.id)
        XCTAssertEqual(result.values[.init(nodeID: array.id, portID: "items")], .textArray(["red", "green", "blue"]))
        XCTAssertEqual(result.values[.init(nodeID: preview.id, portID: "text")], .text("blue / 2.5 / red, green ,blue"))
    }

    func testImageNodesFlowEndToEnd() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try VideoFixtures.solidPNG((200, 60, 20), width: 32, height: 16, in: root, name: "a")
        let other = try VideoFixtures.solidPNG((20, 60, 200), width: 16, height: 8, in: root, name: "b")
        let mask = try VideoFixtures.solidPNG((255, 255, 255), width: 16, height: 8, in: root, name: "m")
        let input = node(.imageInput, "In") { $0.imagePath = source.path }
        let reference = node(.imageInput, "Ref") { $0.imagePath = other.path }
        let maskInput = node(.maskInput, "Mask") { $0.imagePath = mask.path }
        let resize = node(.imageResize, "Resize") { $0.width = 16; $0.height = 8 }
        let crop = node(.imageCrop, "Crop") { $0.cropX = 0; $0.cropY = 0; $0.cropWidth = 0.5; $0.cropHeight = 0.5 }
        let rotate = node(.imageRotateFlip, "Rotate") { $0.quarterTurns = 1 }
        let blur = node(.imageBlur, "Blur") { $0.blurRadius = 1 }
        let invert = node(.imageInvert, "Invert")
        let opacity = node(.number, "Opacity") { $0.numberValue = 0.25 }
        let blend = node(.imageBlend, "Blend")
        let correct = node(.colourCorrect, "Correct")
        let compare = node(.imageCompare, "Compare") { $0.comparisonSelection = 1 }
        let maskOps = node(.maskOperations, "MaskOps") { $0.maskInvert = true }
        let preview = node(.imagePreview, "Preview")
        let project = WorkflowProject(name: "image", nodes: [input, reference, maskInput, resize, crop, rotate, blur, invert, opacity, blend, correct, compare, maskOps, preview], edges: [
            wire(input, "image", resize, "image", .image), wire(resize, "image", crop, "image", .image), wire(crop, "image", rotate, "image", .image),
            wire(rotate, "image", blur, "image", .image), wire(blur, "image", invert, "image", .image),
            wire(resize, "image", blend, "background", .image), wire(reference, "image", blend, "foreground", .image), wire(opacity, "number", blend, "opacity", .number),
            wire(blend, "image", correct, "generated", .image), wire(input, "image", correct, "source", .image),
            wire(invert, "image", compare, "a", .image), wire(correct, "image", compare, "b", .image),
            wire(maskInput, "image", maskOps, "mask", .image), wire(reference, "image", maskOps, "source", .image),
            wire(compare, "selected", preview, "image", .image)
        ])
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: preview.id)
        let media = MediaProcessor(root: root)
        let resized = try await size(result.values[.init(nodeID: resize.id, portID: "image")], media)
        let rotated = try await size(result.values[.init(nodeID: rotate.id, portID: "image")], media)
        let blended = try await size(result.values[.init(nodeID: blend.id, portID: "image")], media)
        let maskResult = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: maskOps.id)
        let masked = try await size(maskResult.values[.init(nodeID: maskOps.id, portID: "mask")], media)
        XCTAssertEqual(resized.0, 16); XCTAssertEqual(resized.1, 8)
        XCTAssertEqual(rotated.0, 4); XCTAssertEqual(rotated.1, 8, "An 8×4 crop turned a quarter turn is 4×8")
        XCTAssertEqual(blended.0, 16); XCTAssertEqual(blended.1, 8)
        XCTAssertEqual(masked.0, 16); XCTAssertEqual(masked.1, 8)
        XCTAssertEqual(result.values[.init(nodeID: preview.id, portID: "image")], result.values[.init(nodeID: correct.id, portID: "image")], "Compare with selection B routes Image B through Selected")
    }

    func testExtractFrameAndSequenceNodesFlowEndToEnd() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.colorClip((90, 90, 90), frames: 24, fps: 24, width: 64, height: 36, in: root, name: "clip")
        let video = node(.videoInput, "Clip") { $0.videoPath = clip.path }
        let time = node(.number, "T") { $0.numberValue = 0.5 }
        let frame = node(.extractFrame, "Frame")
        let router = node(.videoRouter, "R")
        let preview = node(.videoPreview, "V")
        let project = WorkflowProject(name: "video", nodes: [video, time, frame, router, preview], edges: [
            wire(video, "video", frame, "video", .video), wire(time, "number", frame, "time", .number),
            wire(video, "video", router, "video", .video), wire(router, "a", preview, "video", .video)
        ])
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: frame.id)
        let extracted = try await size(result.values[.init(nodeID: frame.id, portID: "image")], MediaProcessor(root: root))
        XCTAssertEqual(extracted.0, 64); XCTAssertEqual(extracted.1, 36)
        let previewed = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: preview.id)
        if case .video = previewed.values[.init(nodeID: preview.id, portID: "video")] {} else { XCTFail("Video Router → Video Preview must carry the clip") }
    }
}

/// Copying a generated node must carry its generations (every take and which one is selected) with it,
/// into the same workflow or another one, so a costly result can be reused in a new flow.
@MainActor
final class CopyGenerationTests: XCTestCase {
    private struct Fixture {
        let model: StudioModel; let store: StudioPersistence; let root: URL
        let source: WorkflowProject; let other: WorkflowProject
        let generator: StudioNode; let prompt: StudioNode
        let files: [URL]; let artifacts: [ExecutionArtifact]
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioCopy-\(UUID().uuidString)")
        let store = StudioPersistence(root: root)
        let mediaDirectory = root.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let files = try (0..<2).map { index -> URL in
            try VideoFixtures.solidPNG((40 * index + 20, 90, 200), width: 8, height: 8, in: mediaDirectory, name: "take-\(index)")
        }
        var generator = StudioNode(kind: .imageGenerator, label: "Hero", position: .init(x: 100, y: 100), model: "m")
        generator.imageSeed = 777
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 100), prompt: "fox")
        let edge = StudioEdge(sourceID: prompt.id, sourcePortID: "text", targetID: generator.id, targetPortID: "prompt", type: .text)
        var source = WorkflowProject(name: "Source", nodes: [prompt, generator], edges: [edge])
        let other = WorkflowProject(name: "Other", nodes: [], edges: [])
        let address = PortAddress(nodeID: generator.id, portID: "image")
        let artifacts = files.enumerated().map { index, file in
            ExecutionArtifact(id: UUID(), projectID: source.id, targetID: generator.id, graphSnapshot: source,
                              values: [address: .image(file), .init(nodeID: prompt.id, portID: "text"): .text("fox")],
                              createdAt: Date(timeIntervalSince1970: Double(1_000 + index)), generatedNodeIDs: [generator.id])
        }
        source.nodes[1].selectedTakeID = artifacts[0].id
        for artifact in artifacts { try await store.saveExecutionArtifact(artifact) }
        let model = StudioModel(persistence: store, engine: StubEngine())
        model.projects = [source, other]; model.currentProjectID = source.id
        model.executionArtifacts = artifacts
        return Fixture(model: model, store: store, root: root, source: source, other: other, generator: source.nodes[1], prompt: prompt, files: files, artifacts: artifacts)
    }

    func testPastedNodeKeepsEveryTakeAndTheSelectedOne() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let generations = f.model.generations(for: [f.generator.id])
        let pasted = f.model.pasteNodes([f.generator], edges: [], generations: generations, centeredAt: .init(x: 500, y: 500))
        let copy = try XCTUnwrap(f.model.currentProject?.nodes.first { pasted.contains($0.id) })
        XCTAssertNotEqual(copy.id, f.generator.id)
        XCTAssertEqual(f.model.takes(for: copy).count, 2, "Every take travels with the copy")
        XCTAssertEqual(f.model.displayedValue(for: copy), .image(f.files[0]), "The selected take stays selected")
        XCTAssertEqual(copy.imageSeed, 777)
        XCTAssertEqual(f.model.takes(for: f.generator).count, 2, "The original keeps its own takes")
        XCTAssertFalse(f.model.takes(for: copy).contains { f.artifacts.map(\.id).contains($0.id) }, "Copies own new records, so deleting one take never removes the other's")
        XCTAssertEqual(f.model.takes(for: copy).first?.graphSnapshot.nodes.first { $0.id == copy.id }?.imageSeed, 777, "Take metadata points at the copy")
    }

    func testOnlyTheCopiedNodesGenerationsAreCarried() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let generations = f.model.generations(for: [f.generator.id])
        XCTAssertEqual(generations.count, 2)
        XCTAssertTrue(generations.allSatisfy { $0.values.keys.allSatisfy { $0.nodeID == f.generator.id } }, "The un-copied Prompt's value is not dragged along")
    }

    func testAGenerationCanBePastedIntoAnotherWorkflow() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let generations = f.model.generations(for: [f.generator.id])
        f.model.currentProjectID = f.other.id
        let pasted = f.model.pasteNodes([f.generator], edges: [], generations: generations, centeredAt: .init(x: 0, y: 0))
        let copy = try XCTUnwrap(f.model.currentProject?.nodes.first { pasted.contains($0.id) })
        XCTAssertEqual(f.model.takes(for: copy).count, 2)
        XCTAssertEqual(f.model.displayedValue(for: copy), .image(f.files[0]))
        XCTAssertTrue(f.model.executionArtifacts.filter { pasted.contains($0.values.keys.first?.nodeID ?? UUID()) }.allSatisfy { $0.projectID == f.other.id && $0.graphSnapshot.id == f.other.id })
    }

    func testDeletingTheOriginalTakeKeepsTheCopiesMedia() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let generations = f.model.generations(for: [f.generator.id])
        let pasted = f.model.pasteNodes([f.generator], edges: [], generations: generations, centeredAt: .init(x: 0, y: 0))
        await f.model.flushProjectWrites()
        await f.model.deleteGalleryItems(outputIDs: [], artifactIDs: Set(f.artifacts.map(\.id)))
        let copy = try XCTUnwrap(f.model.currentProject?.nodes.first { pasted.contains($0.id) })
        XCTAssertEqual(f.model.takes(for: copy).count, 2)
        for file in f.files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) is still used by the copy") }
        let reloaded = try await f.store.loadExecutionArtifacts()
        XCTAssertEqual(reloaded.count, 2, "The copy's records were saved to disk")
    }

    /// The purpose of keeping a generation: a flow built downstream of the copy reuses it instead of rendering again.
    func testRunningDownstreamOfACopyReusesItsGenerationWithoutAnEngine() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pasted = f.model.pasteNodes([f.generator], edges: [], generations: f.model.generations(for: [f.generator.id]), centeredAt: .init(x: 0, y: 0))
        let copy = try XCTUnwrap(f.model.currentProject?.nodes.first { pasted.contains($0.id) })
        let preview = StudioNode(kind: .imagePreview, label: "Out", position: .init(x: 400, y: 100))
        var project = try XCTUnwrap(f.model.currentProject)
        project.nodes.append(preview)
        project.edges.append(.init(sourceID: copy.id, sourcePortID: "image", targetID: preview.id, targetPortID: "image", type: .image))
        let take = try XCTUnwrap(f.model.selectedTake(for: copy))
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: f.store).execute(project: project, targetID: preview.id, selectedTakes: [copy.id: take])
        XCTAssertEqual(result.values[.init(nodeID: preview.id, portID: "image")], .image(f.files[0]))
    }

    func testDuplicateKeepsGenerationsToo() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let duplicated = f.model.duplicateNodes([f.generator.id])
        let copy = try XCTUnwrap(f.model.currentProject?.nodes.first { duplicated.contains($0.id) })
        XCTAssertEqual(f.model.takes(for: copy).count, 2)
        XCTAssertEqual(f.model.displayedValue(for: copy), .image(f.files[0]))
    }

    func testTheClipboardPayloadSurvivesEncoding() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let generations = f.model.generations(for: [f.generator.id])
        let decoded = try JSONDecoder().decode([NodeGeneration].self, from: JSONEncoder().encode(generations))
        XCTAssertEqual(decoded, generations)
        XCTAssertFalse(generations.isEmpty)
    }

    func testPastingWithoutGenerationsStillWorksAndIsEmpty() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pasted = f.model.pasteNodes([f.prompt], edges: [], generations: [], centeredAt: .init(x: 0, y: 0))
        XCTAssertEqual(pasted.count, 1)
        XCTAssertTrue(f.model.generations(for: [f.prompt.id]).isEmpty, "A Prompt has no generation")
    }
}

/// Offscreen renders for visual review. Set GENSTUDIO_AUDIT_EVIDENCE to a directory to write them.
@MainActor
final class NodeAuditEvidenceTests: XCTestCase {
    func testCharacterSheetInspector() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GENSTUDIO_SHEET_UI_EVIDENCE"] else {
            throw XCTSkip("Set GENSTUDIO_SHEET_UI_EVIDENCE for Character Sheet inspector review.")
        }
        let out = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioSheetUI-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var sheet = StudioNode(kind: .characterSheet, label: "Character Sheet", position: .init(x: 0, y: 0))
        sheet.characterSheetHeightCM = 179
        sheet.characterSheetPose = .standing
        let project = WorkflowProject(name: "Sheet UI", nodes: [sheet], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id; model.selectedNodeID = sheet.id
        try await render(InspectorView(model: model), size: NSSize(width: 340, height: 900), to: out.appending(path: "sheet-inspector.png"))
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(white: 0.08)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    func testCombineTextCardAndInspector() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GENSTUDIO_AUDIT_EVIDENCE"] else { throw XCTSkip("Set GENSTUDIO_AUDIT_EVIDENCE to a directory.") }
        let out = URL(fileURLWithPath: directory)
        let a = StudioNode(kind: .prompt, label: "Subject", position: .init(x: 0, y: 0), prompt: "a red fox")
        let b = StudioNode(kind: .prompt, label: "Style", position: .init(x: 0, y: 1), prompt: "watercolour")
        let joiner = StudioNode(kind: .combineText, label: "Combine Text", position: .init(x: 400, y: 0), separator: "\n")
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioAudit-\(UUID().uuidString)")
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        let project = WorkflowProject(name: "Evidence", nodes: [a, b, joiner], edges: [])
        model.projects = [project]; model.currentProjectID = project.id
        model.connectToBody(sourceID: a.id, sourcePortID: "text", targetID: joiner.id)
        model.connectToBody(sourceID: b.id, sourcePortID: "text", targetID: joiner.id)
        model.selectedNodeID = joiner.id
        let current = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == joiner.id })
        let connected = Set(model.currentProject?.edges.filter { $0.targetID == joiner.id }.map(\.targetPortID) ?? [])
        let card = NodeCard(node: current, output: nil, selected: true, activeWire: nil, connectedInputPortIDs: connected, move: { _, _ in }, wire: { _, _, _, _ in })
            .frame(width: NodeLayout.cardWidth(current), height: NodeLayout.cardHeight(current)).padding(.leading, 150).padding(24)
        try await render(card, size: NSSize(width: NodeLayout.cardWidth(current) + 200, height: NodeLayout.cardHeight(current) + 48), to: out.appending(path: "combine-card.png"))
        try await render(InspectorView(model: model), size: NSSize(width: 340, height: 620), to: out.appending(path: "combine-inspector.png"))
    }
}
