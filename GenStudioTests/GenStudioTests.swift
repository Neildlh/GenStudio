import XCTest
@testable import GenStudio

final class GraphValidatorTests: XCTestCase {
    private func node(_ kind: NodeKind, prompt: String = "hello", model: String = "qwen") -> StudioNode {
        StudioNode(kind: kind, label: kind.title, position: .init(x: 0, y: 0), prompt: prompt, model: model)
    }

    func testValidPromptToModel() throws {
        let prompt = node(.prompt)
        let model = node(.textModel)
        let project = WorkflowProject(name: "Valid", nodes: [prompt, model], edges: [.init(sourceID: prompt.id, targetID: model.id, type: .text)])
        XCTAssertEqual(try GraphValidator().validate(project, installedModels: ["qwen"]).count, 2)
    }

    func testRejectsCycle() {
        let first = node(.textModel)
        let second = node(.textModel)
        let project = WorkflowProject(name: "Cycle", nodes: [first, second], edges: [
            .init(sourceID: first.id, targetID: second.id, type: .text),
            .init(sourceID: second.id, targetID: first.id, type: .text)
        ])
        XCTAssertThrowsError(try GraphValidator().validate(project, installedModels: ["qwen"]))
    }

    func testRejectsDanglingEdge() {
        let prompt = node(.prompt)
        let project = WorkflowProject(name: "Dangling", nodes: [prompt], edges: [.init(sourceID: prompt.id, targetID: UUID(), type: .text)])
        XCTAssertThrowsError(try GraphValidator().validate(project))
    }

    func testRejectsIncompatibleConnection() {
        let image = node(.imageInput)
        let text = node(.textModel)
        let project = WorkflowProject(name: "Wrong Type", nodes: [image, text], edges: [.init(sourceID: image.id, targetID: text.id, type: .image)])
        XCTAssertThrowsError(try GraphValidator().validate(project))
    }

    func testRejectsDisconnectedRequiredInputAndMissingModel() {
        let disconnected = node(.textModel)
        XCTAssertThrowsError(try GraphValidator().validate(.init(name: "Disconnected", nodes: [disconnected], edges: []), installedModels: ["qwen"]))

        let prompt = node(.prompt)
        let model = node(.textModel, model: "missing")
        XCTAssertThrowsError(try GraphValidator().validate(.init(name: "Missing", nodes: [prompt, model], edges: [.init(sourceID: prompt.id, targetID: model.id, type: .text)]), installedModels: ["qwen"]))
    }
}

final class CanvasInteractionTests: XCTestCase {
    func testImageGeneratorKeepsThreeFixedOrderedReferences() {
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 0, y: 0))

        XCTAssertEqual(generator.inputPorts.filter { $0.type == .image }.map(\.label), ["Reference 1", "Reference 2", "Reference 3"])
        XCTAssertEqual(generator.imageGeneratorReferencePortIDs, ["referenceImage", "referenceImage2", "referenceImage3"])

        XCTAssertTrue(generator.inputPorts.filter { $0.type == .image }.allSatisfy { !$0.required })
    }

    @MainActor
    func testImageGeneratorAddsADeclaredFourthReferenceWithoutChangingTheFirstThree() {
        var generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 0, y: 0), model: ChatGPTSubscriptionImageEngine.recipeID)
        let limit = StudioModel.imageReferenceLimit(for: generator, capabilities: [ImageCapabilityRegistry.chatGPTSubscriptionReference], cloudSignedIn: true)

        XCTAssertEqual(limit, 4)
        generator.dynamicInputs.append(.init(label: "Reference 4", type: .image))
        XCTAssertEqual(generator.inputPorts.filter { $0.type == .image }.map(\.label), ["Reference 1", "Reference 2", "Reference 3", "Reference 4"])
        XCTAssertEqual(generator.imageGeneratorReferencePortIDs.count, limit)
    }

    @MainActor
    func testImageGeneratorDoesNotOfferCloudReferenceSlotsUntilSignedIn() {
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 0, y: 0), model: ChatGPTSubscriptionImageEngine.recipeID)

        XCTAssertNil(StudioModel.imageReferenceLimit(for: generator, capabilities: [ImageCapabilityRegistry.chatGPTSubscriptionReference], cloudSignedIn: false))
    }

    func testRepeatedDragUpdatesUseFixedGestureOrigin() {
        let origin = CanvasPoint(x: 100, y: 200)
        let first = CanvasInteraction.translated(origin: origin, horizontal: 20, vertical: 10, scale: 2)
        let second = CanvasInteraction.translated(origin: origin, horizontal: 40, vertical: 30, scale: 2)

        XCTAssertEqual(first, CanvasPoint(x: 110, y: 205))
        XCTAssertEqual(second, CanvasPoint(x: 120, y: 215), "Cumulative translation must not be added to the prior update")
    }

    func testFitViewIncludesMixedWidthImageCardsAndExternalLabels() {
        let text = StudioNode(kind: .prompt, label: "P", position: .init(x: -240, y: -50))
        let image = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 140, y: 100))
        let viewport = CanvasInteraction.fittedViewport(nodes: [text, image], canvasWidth: 1200, canvasHeight: 800)
        XCTAssertEqual(NodeLayout.cardWidth(text), 360)
        XCTAssertEqual(NodeLayout.cardWidth(image), 320)
        XCTAssertEqual(NodeLayout.previewTop(image), 48)
        for node in [text, image] {
            let left = viewport.offset.x + (node.position.x - NodeLayout.leadingOverflow(node)) * viewport.zoom
            let right = viewport.offset.x + (node.position.x + NodeLayout.cardWidth(node) + NodeLayout.trailingOverflow(node)) * viewport.zoom
            let bottom = viewport.offset.y + (node.position.y + NodeLayout.cardHeight(node)) * viewport.zoom
            XCTAssertGreaterThanOrEqual(left, 39.9)
            XCTAssertLessThanOrEqual(right, 1160.1)
            XCTAssertLessThanOrEqual(bottom, 760.1)
        }
    }

    func testFitViewRecoversExtremeCoordinatesWithoutMovingNodes() {
        let node = StudioNode(kind: .prompt, label: "Off canvas", position: .init(x: -4_563, y: -7_630))
        let viewport = CanvasInteraction.fittedViewport(nodes: [node], canvasWidth: 980, canvasHeight: 640)

        XCTAssertEqual(node.position, CanvasPoint(x: -4_563, y: -7_630))
        XCTAssertGreaterThan(viewport.offset.x + node.position.x * viewport.zoom, 0)
        XCTAssertGreaterThan(viewport.offset.y + node.position.y * viewport.zoom, 0)
    }

    func testZoomKeepsAnchorOverSameWorldPoint() {
        let original = CanvasViewport(offset: .init(x: -240, y: 75), zoom: 0.6)
        let anchor = CanvasPoint(x: 430, y: 310)
        let world = CanvasPoint(
            x: (anchor.x - original.offset.x) / original.zoom,
            y: (anchor.y - original.offset.y) / original.zoom
        )

        let zoomed = CanvasInteraction.zoomedViewport(original, to: 1.4, anchor: anchor)

        XCTAssertEqual(zoomed.offset.x + world.x * zoomed.zoom, anchor.x, accuracy: 0.0001)
        XCTAssertEqual(zoomed.offset.y + world.y * zoomed.zoom, anchor.y, accuracy: 0.0001)
    }

    func testZoomSupportsFourHundredPercentAndClampsBeyondIt() {
        let viewport = CanvasViewport(offset: .init(x: 0, y: 0), zoom: 1)
        let anchor = CanvasPoint(x: 400, y: 300)

        let zoomed = CanvasInteraction.zoomedViewport(viewport, to: 4, anchor: anchor)
        let clamped = CanvasInteraction.zoomedViewport(viewport, to: 8, anchor: anchor)

        XCTAssertEqual(CanvasInteraction.maximumZoom, 4)
        XCTAssertEqual(zoomed.zoom, 4)
        XCTAssertEqual(clamped.zoom, 4)
    }

    func testZoomOutSupportsLargeWorkflowOverviewAndManualFloor() {
        let viewport = CanvasViewport(offset: .init(x: 120, y: -80), zoom: 1)
        let anchor = CanvasPoint(x: 500, y: 350)

        let zoomed = CanvasInteraction.zoomedViewport(viewport, to: 0.1, anchor: anchor)
        let clamped = CanvasInteraction.zoomedViewport(viewport, to: 0.01, anchor: anchor)

        XCTAssertEqual(zoomed.zoom, CanvasInteraction.minimumZoom)
        XCTAssertEqual(clamped.zoom, CanvasInteraction.minimumZoom)
    }

    func testSocketHitRadiusGrowsForZoomedOutCanvasAndHasASafeCap() {
        XCTAssertEqual(CanvasInteraction.socketHitRadius(for: 1), 22)
        XCTAssertEqual(CanvasInteraction.socketHitRadius(for: 0.4), 55)
        XCTAssertEqual(CanvasInteraction.socketHitRadius(for: 0.1), 60)
        XCTAssertEqual(CanvasInteraction.socketHitRadius(for: 0.01), 60)
    }

    func testAutomaticNodeConnectionChoosesTypedSide() {
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 500, y: 100))
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0))
        let upscale = StudioNode(kind: .imageUpscale, label: "Upscale", position: .init(x: 0, y: 0))
        XCTAssertEqual(prompt.outputPorts.map(\.id), ["text"])
        XCTAssertTrue(generator.inputPorts.contains { $0.id == "prompt" && $0.type == .text })

        XCTAssertEqual(
            CanvasInteraction.automaticConnection(newNode: prompt, selectedNode: generator),
            .init(side: .left, sourcePortID: "text", targetPortID: "prompt")
        )
        XCTAssertEqual(
            CanvasInteraction.automaticConnection(newNode: upscale, selectedNode: generator),
            .init(side: .right, sourcePortID: "image", targetPortID: "image")
        )
    }

    func testSocketInteractionTargetIsLargerThanVisualRail() {
        XCTAssertGreaterThan(NodeLayout.socketHitTargetWidth, NodeLayout.socketRailWidth)
        XCTAssertGreaterThan(NodeLayout.socketHitTargetHeight, NodeLayout.socketRowHeight)
        XCTAssertEqual((NodeLayout.socketHitTargetWidth - NodeLayout.socketRailWidth) / 2, 12)
    }

    func testWireRouteLeavesEachSocketHorizontallyBeforeBending() {
        let route = CanvasInteraction.wireRoute(
            from: CGPoint(x: 340, y: 950),
            to: CGPoint(x: 100, y: 125)
        )

        XCTAssertEqual(route.sourceStub, CGPoint(x: 350, y: 950))
        XCTAssertEqual(route.targetStub, CGPoint(x: 90, y: 125))
        XCTAssertGreaterThan(route.control1.x, route.sourceStub.x, "An output must initially route away from the right edge of its node")
        XCTAssertLessThan(route.control2.x, route.targetStub.x, "An input must be approached from the left edge of its node")
    }

    func testFrameBoundsHonoursReadableSingleNodeZoomLimit() {
        let viewport = CanvasInteraction.fittedViewport(
            bounds: [CGRect(x: 100, y: 200, width: 240, height: 180)],
            canvasWidth: 1400,
            canvasHeight: 900,
            padding: 48,
            maximumZoom: 1
        )

        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.offset.x + 220, 700, accuracy: 0.0001)
        XCTAssertEqual(viewport.offset.y + 290, 450, accuracy: 0.0001)
    }

    func testFrameBoundsCanZoomSingleNodeToFillWorkspace() {
        let viewport = CanvasInteraction.fittedViewport(
            bounds: [CGRect(x: 100, y: 200, width: 240, height: 180)],
            canvasWidth: 1400,
            canvasHeight: 900,
            padding: 48
        )

        XCTAssertEqual(viewport.zoom, CanvasInteraction.maximumZoom)
    }

    func testFitBoundsCanZoomOutBeyondManualNavigationFloor() {
        let viewport = CanvasInteraction.fittedViewport(
            bounds: [CGRect(x: 0, y: 0, width: 12_000, height: 8_000)],
            canvasWidth: 1_000,
            canvasHeight: 700,
            padding: 48,
            minimumZoom: CanvasInteraction.fitMinimumZoom
        )

        XCTAssertEqual(viewport.zoom, 904.0 / 12_000.0, accuracy: 0.000_001)
        XCTAssertGreaterThan(viewport.zoom, CanvasInteraction.fitMinimumZoom)
        XCTAssertLessThan(viewport.zoom, CanvasInteraction.minimumZoom)
    }

    func testKeyboardNavigationUsesDependenciesThenSpatialOrder() {
        let first = StudioNode(kind: .prompt, label: "First", position: .init(x: 300, y: 200))
        let second = StudioNode(kind: .textModel, label: "Second", position: .init(x: 50, y: 100))
        let third = StudioNode(kind: .textPreview, label: "Third", position: .init(x: 600, y: 100))
        let edges = [
            StudioEdge(sourceID: first.id, targetID: second.id, type: .text),
            StudioEdge(sourceID: second.id, targetID: third.id, type: .text)
        ]

        XCTAssertEqual(CanvasInteraction.navigationOrder(nodes: [third, second, first], edges: edges), [first.id, second.id, third.id])
    }

    func testPromptStyleCardsKeepContentAlignedBelowTheirSharedHeader() {
        let kinds: [NodeKind] = [.prompt, .imagePrompt, .videoPrompt, .imageDescriber, .characterSheet]
        let tops = kinds.map { NodeLayout.previewTop(StudioNode(kind: $0, label: $0.title, position: .init(x: 0, y: 0))) }

        XCTAssertEqual(Set(tops), [56], "Prompt-style cards should use one consistent content offset")
    }

    func testEveryOtherNodeKindSharesOneContentOffsetBelowTheCompactHeader() {
        let promptStyled: Set<NodeKind> = [.prompt, .imagePrompt, .videoPrompt, .promptEnhancer, .imageDescriber, .characterSheet]
        let tops = NodeKind.allCases.filter { !promptStyled.contains($0) }
            .map { NodeLayout.previewTop(StudioNode(kind: $0, label: $0.title, position: .init(x: 0, y: 0))) }
        XCTAssertEqual(Set(tops), [48], "Image, video, and utility nodes must not leave a gap under the header")
    }

    func testPromptAndCompositionNodesDoNotOfferPerCardRunControls() {
        let promptNodes: [NodeKind] = [.prompt, .imagePrompt, .videoPrompt, .characterSheet, .promptTemplate, .combineText, .textArray, .listSelect, .number, .numberToText]
        XCTAssertTrue(promptNodes.allSatisfy(\.hidesCanvasRunControl))
        XCTAssertTrue(NodeKind.imageGenerator.usesModel)
        XCTAssertEqual(NodeKind.imageGenerator.canvasRunLabel, "Run Model")
        XCTAssertFalse(NodeKind.imageResize.hidesCanvasRunControl)
        XCTAssertEqual(NodeKind.imageResize.canvasRunLabel, "Run")
    }

    func testEveryNodeKindReservesSpaceForExternalPortLabels() {
        for kind in NodeKind.allCases {
            let node = StudioNode(kind: kind, label: kind.title, position: .init(x: 0, y: 0))
            XCTAssertEqual(NodeLayout.leadingOverflow(node), node.inputPorts.isEmpty ? 7 : 124, kind.title)
            XCTAssertEqual(NodeLayout.trailingOverflow(node), node.outputPorts.isEmpty ? 7 : 124, kind.title)
        }
    }

    func testOnlyConnectedInputsAndAllOutputsUseSolidSockets() throws {
        let node = StudioNode(kind: .imageToVideo, label: "Video", position: .init(x: 0, y: 0))
        let input = try XCTUnwrap(node.inputPorts.first)
        let output = try XCTUnwrap(node.outputPorts.first)

        XCTAssertFalse(PortPresentation.socketIsFilled(input, connectedInputPortIDs: []))
        XCTAssertTrue(PortPresentation.socketIsFilled(input, connectedInputPortIDs: [input.id]))
        XCTAssertTrue(PortPresentation.socketIsFilled(output, connectedInputPortIDs: []))
    }
}

@MainActor
final class StudioModelTests: XCTestCase {
    func testNoOpProjectMutationDoesNotPublishOrChangeTimestamp() {
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        let project = WorkflowProject(name: "No-op", nodes: [], edges: [])
        model.projects = [project]
        model.currentProjectID = project.id
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }

        model.mutateProject { $0.name = project.name }

        XCTAssertEqual(model.currentProject, project)
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(observation) {}
    }

    func testBulkHistoryDeletionUpdatesPublishedStateAndKeepsGalleryContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioHistoryModelTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioPersistence(root: root)
        let model = StudioModel(persistence: store, engine: StubEngine())
        let projectID = UUID(), nodeID = UUID()
        let snapshot = RunInputSnapshot(projectID: projectID, nodeID: nodeID, prompt: "p", model: "m", temperature: 0, maxTokens: 1)
        let runs = (0..<3).map { _ in RunRecord(id: UUID(), snapshot: snapshot, status: .succeeded, queuedAt: Date()) }
        let output = TextOutput(id: UUID(), runID: runs[0].id, projectID: projectID, nodeID: nodeID, prompt: "p", model: "m", text: "keep", createdAt: Date())
        for run in runs { try await store.saveRun(run) }
        try await store.saveOutput(output)
        model.runs = runs; model.outputs = [output]

        await model.deleteHistoryItems(Set(runs.prefix(2).map(\.id)))

        XCTAssertEqual(model.runs.map(\.id), [runs[2].id])
        XCTAssertEqual(model.outputs, [output])
        let savedRuns = try await store.loadRuns(recoverInterrupted: false)
        let savedOutputs = try await store.loadOutputs()
        XCTAssertEqual(savedRuns.map(\.id), [runs[2].id])
        XCTAssertEqual(savedOutputs.map(\.id), [output.id])
        XCTAssertEqual(savedOutputs.first?.text, output.text)
    }

    func testBodyDropUsesFreeSocketAndCycleRollbackRestoresDynamicSlots() {
        let p1 = StudioNode(kind: .prompt, label: "P1", position: .init(x: 0, y: 0), prompt: "one"), p2 = StudioNode(kind: .prompt, label: "P2", position: .init(x: 0, y: 1), prompt: "two")
        let combine = StudioNode(kind: .combineText, label: "C", position: .init(x: 1, y: 0), dynamicInputs: [.init(id: "one", label: "One"), .init(id: "two", label: "Two")])
        let router = StudioNode(kind: .textRouter, label: "R", position: .init(x: 2, y: 0))
        let initial = [StudioEdge(sourceID: p1.id, sourcePortID: "text", targetID: combine.id, targetPortID: "one", type: .text), StudioEdge(sourceID: combine.id, sourcePortID: "text", targetID: router.id, targetPortID: "text", type: .text)]
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        let project = WorkflowProject(name: "body", nodes: [p1, p2, combine, router], edges: initial); model.projects = [project]; model.currentProjectID = project.id
        model.connectToBody(sourceID: p2.id, sourcePortID: "text", targetID: combine.id)
        XCTAssertEqual(model.currentProject?.edges.last?.targetPortID, "two")
        let beforeCycle = model.currentProject
        model.connectToBody(sourceID: router.id, sourcePortID: "a", targetID: combine.id)
        XCTAssertEqual(model.currentProject?.edges, beforeCycle?.edges)
        XCTAssertEqual(model.currentProject?.nodes.first(where: { $0.id == combine.id })?.dynamicInputs, beforeCycle?.nodes.first(where: { $0.id == combine.id })?.dynamicInputs)
        XCTAssertTrue(model.alertMessage?.contains("cycle") == true)
    }

    func testAddingNodeToSelectionPlacesAndConnectsByTypedDirection() throws {
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 500, y: 100), model: "image")
        let project = WorkflowProject(name: "Automatic add", nodes: [generator], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        let promptID = try XCTUnwrap(model.addNodeConnectedToSelection(.prompt, selectedNodeID: generator.id))
        let prompt = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == promptID })
        XCTAssertEqual(prompt.position.x, generator.position.x - NodeLayout.cardWidth(prompt) - 96)
        XCTAssertEqual(model.currentProject?.edges.last?.sourceID, promptID)
        XCTAssertEqual(model.currentProject?.edges.last?.targetID, generator.id)
        XCTAssertEqual(model.currentProject?.edges.last?.targetPortID, "prompt")

        let upscaleID = try XCTUnwrap(model.addNodeConnectedToSelection(.imageUpscale, selectedNodeID: generator.id))
        let upscale = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == upscaleID })
        XCTAssertEqual(upscale.position.x, generator.position.x + NodeLayout.cardWidth(generator) + 96)
        XCTAssertEqual(model.currentProject?.edges.last?.sourceID, generator.id)
        XCTAssertEqual(model.currentProject?.edges.last?.targetID, upscaleID)
        XCTAssertEqual(model.currentProject?.edges.last?.targetPortID, "image")
    }

    func testDeleteSelectedRemovesOnlyIncidentEdgesAndUndoRestoresGraph() {
        let selected = StudioNode(kind: .prompt, label: "Selected", position: .init(x: 0, y: 0))
        let survivor = StudioNode(kind: .prompt, label: "Survivor", position: .init(x: 0, y: 100))
        let previewA = StudioNode(kind: .textPreview, label: "A", position: .init(x: 300, y: 0))
        let previewB = StudioNode(kind: .textPreview, label: "B", position: .init(x: 300, y: 100))
        let incident = StudioEdge(sourceID: selected.id, sourcePortID: "text", targetID: previewA.id, targetPortID: "text", type: .text)
        let unrelated = StudioEdge(sourceID: survivor.id, sourcePortID: "text", targetID: previewB.id, targetPortID: "text", type: .text)
        let project = WorkflowProject(name: "Delete fixture", nodes: [selected, survivor, previewA, previewB], edges: [incident, unrelated])
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id; model.selectedNodeID = selected.id
        model.deleteSelected()
        XCTAssertEqual(model.currentProject?.nodes, [survivor, previewA, previewB])
        XCTAssertEqual(model.currentProject?.edges, [unrelated])
        XCTAssertNil(model.selectedNodeID)
        model.undo()
        XCTAssertEqual(model.currentProject?.nodes, project.nodes)
        XCTAssertEqual(model.currentProject?.edges, project.edges)
        model.selectedNodeID = UUID()
        let before = model.currentProject
        model.deleteSelected()
        XCTAssertEqual(model.currentProject, before)
        XCTAssertFalse(model.canUndo)
    }

    func testDuplicateNodeCopiesConfigurationOffsetsItAndLeavesConnectionsOnSource() throws {
        let source = StudioNode(kind: .imageGenerator, label: "Hero", position: .init(x: 100, y: 200), prompt: "same prompt", model: "recipe")
        let target = StudioNode(kind: .imagePreview, label: "Preview", position: .init(x: 500, y: 200))
        let edge = StudioEdge(sourceID: source.id, sourcePortID: "image", targetID: target.id, targetPortID: "image", type: .image)
        let project = WorkflowProject(name: "Duplicate", nodes: [source, target], edges: [edge])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        model.duplicateNode(source.id)

        let copy = try XCTUnwrap(model.currentProject?.nodes.first(where: { $0.id != source.id && $0.id != target.id }))
        XCTAssertEqual(copy.prompt, source.prompt)
        XCTAssertEqual(copy.model, source.model)
        XCTAssertEqual(copy.position, .init(x: 140, y: 240))
        XCTAssertEqual(copy.label, "Hero Copy")
        XCTAssertEqual(model.selectedNodeID, copy.id)
        XCTAssertEqual(model.currentProject?.edges, [edge])
    }

    func testOptionDragDuplicatesAtTheSourcePositionBeforeMoving() throws {
        let source = StudioNode(kind: .prompt, label: "Source", position: .init(x: 100, y: 200))
        let project = WorkflowProject(name: "Option drag", nodes: [source], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        let copies = model.duplicateNodesForDrag([source.id])
        let copyID = try XCTUnwrap(copies[source.id])
        let copy = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == copyID })

        XCTAssertEqual(copy.position, source.position)
        XCTAssertEqual(copy.label, "Source Copy")
        XCTAssertEqual(model.currentProject?.nodes.count, 2)
    }

    func testMovingSeveralNodesIsOneUndoableGesture() {
        let first = StudioNode(kind: .prompt, label: "First", position: .init(x: 10, y: 20))
        let second = StudioNode(kind: .textPreview, label: "Second", position: .init(x: 300, y: 40))
        let project = WorkflowProject(name: "Drag group", nodes: [first, second], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        model.moveNodes(
            [first.id, second.id],
            from: [first.id: first.position, second.id: second.position],
            to: [first.id: .init(x: 50, y: 60), second.id: .init(x: 340, y: 80)],
            ended: true
        )

        model.undo()
        XCTAssertEqual(model.currentProject?.nodes, project.nodes)
    }

    func testKeyboardNudgeMovesSelectionAsOneUndoableEdit() {
        let first = StudioNode(kind: .prompt, label: "First", position: .init(x: 10, y: 20))
        let second = StudioNode(kind: .textPreview, label: "Second", position: .init(x: 300, y: 40))
        let project = WorkflowProject(name: "Nudge", nodes: [first, second], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        model.nudgeNodes([first.id, second.id], by: .init(x: 10, y: -1))

        XCTAssertEqual(model.currentProject?.nodes[0].position, .init(x: 20, y: 19))
        XCTAssertEqual(model.currentProject?.nodes[1].position, .init(x: 310, y: 39))
        model.undo()
        XCTAssertEqual(model.currentProject?.nodes, project.nodes)
    }

    func testPasteNodesRemapsInternalWiresAndCentersGroup() throws {
        let source = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 100, y: 100))
        let target = StudioNode(kind: .textPreview, label: "Preview", position: .init(x: 500, y: 100))
        let edge = StudioEdge(sourceID: source.id, sourcePortID: "text", targetID: target.id, targetPortID: "text", type: .text)
        let project = WorkflowProject(name: "Paste", nodes: [], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        let ids = model.pasteNodes([source, target], edges: [edge], centeredAt: .init(x: 700, y: 400))

        XCTAssertEqual(ids.count, 2)
        let pastedEdge = try XCTUnwrap(model.currentProject?.edges.first)
        XCTAssertTrue(ids.contains(pastedEdge.sourceID))
        XCTAssertTrue(ids.contains(pastedEdge.targetID))
        XCTAssertEqual(pastedEdge.sourcePortID, "text")
        XCTAssertEqual(pastedEdge.targetPortID, "text")
        XCTAssertTrue(ids.contains(try XCTUnwrap(model.selectedNodeID)))
    }

    func testUndoHistoryDoesNotCrossProjectBoundary() {
        let a = WorkflowProject(name: "A", nodes: [], edges: [])
        let b = WorkflowProject(name: "B", nodes: [], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [a, b]; model.currentProjectID = a.id
        model.addNode(.prompt)
        XCTAssertEqual(model.currentProject?.nodes.count, 1)
        model.selectProject(b.id); model.undo()
        XCTAssertEqual(model.currentProjectID, b.id)
        XCTAssertEqual(model.currentProject?.nodes.count, 0)
        XCTAssertEqual(model.projects.first(where: { $0.id == a.id })?.nodes.count, 1)
    }

    func testRenameAndThreeGraphEditsCanBeUndone() {
        let original = StudioNode(kind: .prompt, label: "Original", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Undo", nodes: [original], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        model.renameNode(original.id, to: "  Renamed  ")
        model.addNode(.number)
        let addedID = try! XCTUnwrap(model.selectedNodeID)
        model.deleteSelected()

        XCTAssertEqual(model.currentProject?.nodes.first?.label, "Renamed")
        XCTAssertFalse(model.currentProject?.nodes.contains(where: { $0.id == addedID }) == true)
        model.undo()
        XCTAssertTrue(model.currentProject?.nodes.contains(where: { $0.id == addedID }) == true)
        model.undo()
        XCTAssertEqual(model.currentProject?.nodes.count, 1)
        XCTAssertEqual(model.currentProject?.nodes.first?.label, "Renamed")
        model.undo()
        XCTAssertEqual(model.currentProject, project)
        XCTAssertFalse(model.canUndo)
    }

    func testDeleteGeneratedNodeStillAllowsUndo() {
        let node = StudioNode(kind: .textPreview, label: "Generated", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Generated delete", nodes: [node], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id; model.selectedNodeID = node.id
        model.runtimeValues[.init(nodeID: node.id, portID: "text")] = .text("finished")

        model.deleteSelected()
        XCTAssertTrue(model.currentProject?.nodes.isEmpty == true)
        model.undo()
        XCTAssertEqual(model.currentProject?.nodes, [node])
        XCTAssertEqual(model.displayedValue(for: node), .text("finished"))
    }

    func testRejectedReplacementLeavesEntirePriorEdgeSetUnchanged() {
        let source = StudioNode(kind: .prompt, label: "X", position: .init(x: 0, y: 0), prompt: "x")
        let a = StudioNode(kind: .textModel, label: "A", position: .init(x: 1, y: 0), model: "stub")
        let b = StudioNode(kind: .textModel, label: "B", position: .init(x: 2, y: 0), model: "stub")
        let c = StudioNode(kind: .textModel, label: "C", position: .init(x: 3, y: 0), model: "stub")
        let priorEdges = [
            StudioEdge(sourceID: source.id, sourcePortID: "text", targetID: a.id, targetPortID: "prompt", type: .text),
            StudioEdge(sourceID: a.id, sourcePortID: "text", targetID: b.id, targetPortID: "prompt", type: .text),
            StudioEdge(sourceID: b.id, sourcePortID: "text", targetID: c.id, targetPortID: "prompt", type: .text)
        ]
        let project = WorkflowProject(name: "Rollback", nodes: [source, a, b, c], edges: priorEdges)
        let model = StudioModel(engine: StubEngine())
        model.projects = [project]
        model.currentProjectID = project.id

        model.connect(sourceID: c.id, targetID: a.id)

        XCTAssertEqual(model.currentProject?.edges, priorEdges)
        XCTAssertTrue(model.alertMessage?.contains("cycle") == true)
    }
}

final class PersistenceTests: XCTestCase {
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)") }

    func testRoundTripAndInterruptedRecovery() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioPersistence(root: root)
        let project = WorkflowProject(name: "Durable", nodes: [], edges: [])
        try await store.saveProject(project)
        let loadedProjects = try await store.loadProjects()
        XCTAssertEqual(loadedProjects.first?.name, "Durable")

        let snapshot = RunInputSnapshot(projectID: project.id, nodeID: UUID(), prompt: "p", model: "m", temperature: 0, maxTokens: 1)
        let run = RunRecord(id: UUID(), snapshot: snapshot, status: .running, queuedAt: Date(), startedAt: Date())
        try await store.saveRun(run)
        let recovered = try await store.loadRuns()
        XCTAssertEqual(recovered.first?.status, .interrupted)
        XCTAssertNotNil(recovered.first?.finishedAt)
    }

    func testPopulatedGraphAndViewportReopenFromFreshPersistence() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: -420, y: 175), prompt: "persist me")
        let model = StudioNode(kind: .textModel, label: "Model", position: .init(x: 840, y: -310), model: "stub")
        let project = WorkflowProject(
            name: "Populated",
            nodes: [prompt, model],
            edges: [.init(sourceID: prompt.id, sourcePortID: "text", targetID: model.id, targetPortID: "prompt", type: .text)],
            viewport: .init(offset: .init(x: 321, y: -222), zoom: 0.73)
        )
        try await StudioPersistence(root: root).saveProject(project)

        let reopened = try await StudioPersistence(root: root).loadProjects()

        let loaded = try XCTUnwrap(reopened.first)
        XCTAssertEqual(loaded.id, project.id)
        XCTAssertEqual(loaded.name, project.name)
        XCTAssertEqual(loaded.nodes, project.nodes)
        XCTAssertEqual(loaded.edges, project.edges)
        XCTAssertEqual(loaded.viewport, project.viewport)
    }

    func testCorruptProjectIsReportedAndNotOverwritten() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "Projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appending(path: "broken.json")
        let bytes = Data("{not-json".utf8)
        try bytes.write(to: file)
        do {
            _ = try await StudioPersistence(root: root).loadProjects()
            XCTFail("Expected malformed data")
        } catch {
            XCTAssertEqual(try Data(contentsOf: file), bytes, "Unreadable data must remain untouched")
        }
    }

    func testUnsupportedSchemaIsExplicit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioPersistence(root: root)
        var project = WorkflowProject(name: "Future", nodes: [], edges: [])
        project.schemaVersion = 99
        try await store.saveProject(project)
        do {
            _ = try await store.loadProjects()
            XCTFail("Expected unsupported schema")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsupported schema version 99"))
        }
    }

    func testReservedV2EndpointAndUnknownZeroSchemaAreRejectedWithoutRewrite() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appending(path: "Projects"); try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "x")
        let preview = StudioNode(kind: .textPreview, label: "V", position: .init(x: 1, y: 0))
        let malformed = WorkflowProject(name: "bad", nodes: [prompt, preview], edges: [.init(sourceID: prompt.id, targetID: preview.id, type: .text)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(malformed), file = projects.appending(path: "bad.json"); try bytes.write(to: file)
        await XCTAssertThrowsErrorAsync { _ = try await StudioPersistence(root: root).loadProjects() }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let zero = Data("{\"schemaVersion\":0,\"name\":\"zero\",\"nodes\":[],\"edges\":[]}".utf8)
        try zero.write(to: file)
        await XCTAssertThrowsErrorAsync { _ = try await StudioPersistence(root: root).loadProjects() }
        XCTAssertEqual(try Data(contentsOf: file), zero)
    }
}

actor StubEngine: TextGenerationEngine {
    var prompts: [String] = []
    let delay: Duration
    let result: String
    init(delay: Duration = .zero, result: String = "result") { self.delay = delay; self.result = result }
    func listModels() async throws -> [InstalledModel] { [.init(name: "stub", size: nil, digest: nil)] }
    func generate(prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        prompts.append(prompt)
        if delay != .zero { try await Task.sleep(for: delay) }
        return result
    }
    func capturedPrompts() -> [String] { prompts }
}

actor FailingEngine: TextGenerationEngine {
    private(set) var callCount = 0
    let error: StudioError
    init(_ error: StudioError) { self.error = error }
    func listModels() async throws -> [InstalledModel] { [.init(name: "stub", size: nil, digest: nil)] }
    func generate(prompt: String, model: String, temperature: Double, maxTokens: Int, timeout: Duration) async throws -> String {
        callCount += 1
        throw error
    }
    func calls() -> Int { callCount }
}

final class ExecutionTests: XCTestCase {
    private func graph(includeUnrelated: Bool = false) -> (WorkflowProject, UUID) {
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "ancestor")
        let target = StudioNode(kind: .textModel, label: "Target", position: .init(x: 1, y: 1), model: "stub")
        var nodes = [prompt, target]
        var edges = [StudioEdge(sourceID: prompt.id, targetID: target.id, type: .text)]
        if includeUnrelated {
            let otherPrompt = StudioNode(kind: .prompt, label: "Other", position: .init(x: 0, y: 0), prompt: "")
            let otherModel = StudioNode(kind: .textModel, label: "Other Model", position: .init(x: 0, y: 0), model: "stub")
            nodes = [otherPrompt, otherModel] + nodes
            edges.insert(.init(sourceID: otherPrompt.id, targetID: otherModel.id, type: .text), at: 0)
        }
        return (.init(name: "Run", nodes: nodes, edges: edges), target.id)
    }

    func testRunsOnlyTargetAncestorsAndPersistsImmutableSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine()
        let persistence = StudioPersistence(root: root)
        let queue = ExecutionQueue(engine: engine, persistence: persistence)
        let (project, target) = graph(includeUnrelated: true)
        let (run, output) = try await queue.run(project: project, targetID: target, installedModels: ["stub"])
        let prompts = await engine.capturedPrompts()
        XCTAssertEqual(prompts, ["ancestor"])
        XCTAssertEqual(run.snapshot.prompt, "ancestor")
        XCTAssertEqual(output.prompt, "ancestor")
        let savedOutputs = try await persistence.loadOutputs()
        XCTAssertEqual(savedOutputs.count, 1)
    }

    func testUnrelatedStructuralDefectsDoNotBlockSelectedValidGraph() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (base, target) = graph()
        let unrelatedA = StudioNode(kind: .textModel, label: "Unrelated A", position: .init(x: 3, y: 3), model: "stub")
        let unrelatedB = StudioNode(kind: .textModel, label: "Unrelated B", position: .init(x: 4, y: 4), model: "stub")
        var project = base
        project.nodes += [unrelatedA, unrelatedB]
        project.edges += [
            .init(sourceID: unrelatedA.id, targetID: unrelatedB.id, type: .text),
            .init(sourceID: unrelatedB.id, targetID: unrelatedA.id, type: .text),
            .init(sourceID: unrelatedA.id, targetID: UUID(), type: .image)
        ]

        let (_, output) = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root))
            .run(project: project, targetID: target, installedModels: ["stub"])

        XCTAssertEqual(output.prompt, "ancestor")
    }

    func testInvalidEdgeAttachedToSelectedSliceStillBlocksRun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (base, target) = graph()
        var project = base
        project.edges.append(.init(sourceID: UUID(), targetID: target, type: .text))

        do {
            _ = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root))
                .run(project: project, targetID: target, installedModels: ["stub"])
            XCTFail("Expected an attached dangling edge to block the selected run")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer exists"))
        }
    }

    func testIncompatibleEdgeAttachedToSelectedSliceStillBlocksRun() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (base, target) = graph()
        var project = base
        let prompt = try XCTUnwrap(project.nodes.first(where: { $0.kind == .prompt }))
        project.edges.append(.init(sourceID: prompt.id, targetID: target, type: .image))

        do {
            _ = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root))
                .run(project: project, targetID: target, installedModels: ["stub"])
            XCTFail("Expected an attached incompatible edge to block the selected run")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Incompatible image connection"))
        }
    }

    func testCancellationPersistsCancelledWithoutOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = StudioPersistence(root: root)
        let queue = ExecutionQueue(engine: StubEngine(delay: .seconds(2)), persistence: persistence)
        let (project, target) = graph()
        let task = Task { try await queue.run(project: project, targetID: target, installedModels: ["stub"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
        let savedRuns = try await persistence.loadRuns(recoverInterrupted: false)
        let savedOutputs = try await persistence.loadOutputs()
        XCTAssertEqual(savedRuns.first?.status, .cancelled)
        XCTAssertTrue(savedOutputs.isEmpty)
    }

    func testConcurrentRunIsRejectedByBusyGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = ExecutionQueue(engine: StubEngine(delay: .milliseconds(400)), persistence: StudioPersistence(root: root))
        let (project, target) = graph()
        let first = Task { try await queue.run(project: project, targetID: target, installedModels: ["stub"]) }
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await queue.run(project: project, targetID: target, installedModels: ["stub"])
            XCTFail("Expected serialized busy rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already running"))
        }
        _ = try await first.value
    }

    func testTimeoutFailsRunAndStopsDownstream() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "start")
        let upstream = StudioNode(kind: .textModel, label: "Upstream", position: .init(x: 1, y: 1), model: "stub")
        let downstream = StudioNode(kind: .textModel, label: "Downstream", position: .init(x: 2, y: 2), model: "stub")
        let project = WorkflowProject(name: "Failure", nodes: [prompt, upstream, downstream], edges: [
            .init(sourceID: prompt.id, targetID: upstream.id, type: .text),
            .init(sourceID: upstream.id, targetID: downstream.id, type: .text)
        ])
        let engine = FailingEngine(.timedOut)
        let persistence = StudioPersistence(root: root)
        do {
            _ = try await ExecutionQueue(engine: engine, persistence: persistence).run(project: project, targetID: downstream.id, installedModels: ["stub"])
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let callCount = await engine.calls()
        let runs = try await persistence.loadRuns(recoverInterrupted: false)
        let outputs = try await persistence.loadOutputs()
        XCTAssertEqual(callCount, 1, "Downstream inference must not start after upstream failure")
        XCTAssertEqual(runs.first?.status, .failed)
        XCTAssertTrue(outputs.isEmpty)
    }
}

final class NodeModelCompatibilityTests: XCTestCase {
    private func installed(_ recipe: ModelRecipe, available: Bool = true) -> InstalledGenerationModel {
        .init(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID, components: [], installedAt: Date(), inferenceVerified: false, available: available, recipeSnapshot: recipe)
    }

    private func graph(kind: NodeKind, model: String) -> (WorkflowProject, StudioNode) {
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "Create a product shot")
        let node = StudioNode(kind: kind, label: kind.title, position: .init(x: 1, y: 0), model: model)
        return (.init(name: "Imported workflow", nodes: [prompt, node], edges: [.init(sourceID: prompt.id, sourcePortID: "text", targetID: node.id, targetPortID: "prompt", type: .text)]), node)
    }

    @MainActor
    func testPickerUsesNodePurposeAndInstalledRuntimeEligibilityWithoutChangingSavedSelection() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        let recipes = ModelCatalog.recipes
        let text = try XCTUnwrap(recipes.first { $0.kind == .text })
        let image = try XCTUnwrap(recipes.first { $0.kind == .image })
        let video = try XCTUnwrap(recipes.first { $0.kind == .video })
        let vision = try XCTUnwrap(recipes.first { $0.kind == .vision })
        let unsupported = ModelRecipe(id: "future-image", name: "Future image model", kind: .image, engineID: "future", components: [], runtimeReady: false, minimumMemoryBytes: 0)
        studio.libraryStore.installed = [text, image, video, vision, unsupported].map { installed($0) }
        XCTAssertEqual(studio.generationModels(.text).map(\.id), [text.id])
        XCTAssertEqual(studio.generationModels(.image).map(\.id), [image.id])
        XCTAssertEqual(studio.generationModels(.vision).map(\.id), [vision.id])
        XCTAssertEqual(studio.generationModels(.video).map(\.id), [VideoCapabilityRegistry.wanT2VRecipeID], "The core workflow still recommends only the verified Wan text-to-video recipe")
        let (project, node) = graph(kind: .imageGenerator, model: video.id)
        studio.projects = [project]; studio.currentProjectID = project.id; studio.selectedNodeID = node.id
        XCTAssertTrue(studio.generationModelIssue(for: node)?.contains("video generation") == true)
        XCTAssertEqual(studio.selectedNode?.model, video.id, "A saved model choice must not silently switch")
        studio.libraryStore.installed = [installed(image, available: false)]
        XCTAssertTrue(studio.generationModels(.image).isEmpty)
        let (_, unavailable) = graph(kind: .imageGenerator, model: image.id)
        XCTAssertTrue(studio.generationModelIssue(for: unavailable)?.contains("files are unavailable") == true)
        let (_, pending) = graph(kind: .imageGenerator, model: unsupported.id)
        studio.libraryStore.installed = [installed(unsupported)]
        XCTAssertTrue(studio.generationModelIssue(for: pending)?.contains("no compatible local runtime") == true)
    }

    @MainActor
    func testNewImageGeneratorPrefersRecommendedInstalledRecipe() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        let sd = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == ImageCapabilityRegistry.sd15RecipeID })
        let klein = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID })

        // Install order must not decide which model a newly-created node uses.
        studio.libraryStore.installed = [installed(sd), installed(klein)]
        let project = WorkflowProject(name: "Default selection", nodes: [], edges: [])
        studio.projects = [project]
        studio.currentProjectID = project.id
        studio.addNode(.imageGenerator)

        XCTAssertEqual(studio.selectedNode?.model, MediaModelCatalog.kleinRecipeID)
        XCTAssertEqual(studio.generationModels(.image).map(\.id), [MediaModelCatalog.kleinRecipeID, ImageCapabilityRegistry.sd15RecipeID])
    }

    func testImportedKnownMismatchesFailEvenWithoutLibraryMetadata() throws {
        for (kind, recipeKind) in [(NodeKind.imageGenerator, GenerationModelKind.video), (.textModel, .vision)] {
            let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.kind == recipeKind })
            let (project, _) = graph(kind: kind, model: recipe.id)
            XCTAssertThrowsError(try GraphValidator().validate(project, installedModels: [recipe.id])) { error in
                XCTAssertTrue(error.localizedDescription.contains("Choose a compatible model"))
            }
            XCTAssertNoThrow(try GraphValidator().validate(project, requireRunnableInputs: false), "An incompatible saved selection remains editable")
        }
    }

    func testQueueRejectsMismatchedInstalledModelBeforeInferenceAndAllowsExternalText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = StubEngine(), queue = ExecutionQueue(engine: engine, persistence: StudioPersistence(root: root))
        let image = try XCTUnwrap(ModelCatalog.recipes.first { $0.kind == .image })
        let (project, node) = graph(kind: .textModel, model: image.id)
        do {
            _ = try await queue.execute(project: project, targetID: node.id, installedModels: [image.id], installedGenerationModels: [installed(image)])
            XCTFail("Image weights cannot execute in a text node")
        } catch { XCTAssertTrue(error.localizedDescription.contains("image generation")) }
        let captured = await engine.capturedPrompts()
        XCTAssertTrue(captured.isEmpty)
        let (external, externalNode) = graph(kind: .textModel, model: "stub")
        let result = try await queue.execute(project: external, targetID: externalNode.id, installedModels: ["stub"], installedGenerationModels: [])
        XCTAssertEqual(result.values[.init(nodeID: externalNode.id, portID: "text")], .text("result"))
        let (missing, missingNode) = graph(kind: .imageGenerator, model: "missing-import")
        do {
            _ = try await queue.execute(project: missing, targetID: missingNode.id, installedGenerationModels: [])
            XCTFail("An empty library must not bypass model validation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not installed")) }
    }
}

final class RunPlanningTests: XCTestCase {
    private func node(_ kind: NodeKind, label: String, x: Double = 0, y: Double = 0, model: String = "qwen") -> StudioNode {
        StudioNode(kind: kind, label: label, position: .init(x: x, y: y), model: model)
    }

    func testWholeWorkflowTargetsAreOnlyGraphEndPointsInVisualOrder() {
        // upstream --> midLeft (a sink, top row)
        //          \-> midRight -> tail (a sink, bottom row)
        let upstream = node(.prompt, label: "Upstream", x: 0, y: 0)
        let midLeft = node(.textModel, label: "Mid Left", x: 100, y: 0)
        let midRight = node(.textModel, label: "Mid Right", x: 100, y: 100)
        let tail = node(.textModel, label: "Tail", x: 200, y: 100)
        let project = WorkflowProject(name: "Test", nodes: [upstream, midLeft, midRight, tail], edges: [
            .init(sourceID: upstream.id, targetID: midLeft.id, type: .text),
            .init(sourceID: upstream.id, targetID: midRight.id, type: .text),
            .init(sourceID: midRight.id, targetID: tail.id, type: .text),
        ])
        // upstream and midRight both feed a downstream node, so only the two sinks (midLeft, tail)
        // should be targeted, left-to-right/top-to-bottom: midLeft (x:100) before tail (x:200).
        XCTAssertEqual(RunPlan.wholeWorkflowTargets(project: project), [midLeft.id, tail.id])
    }

    func testWholeWorkflowTargetsSkipLockedNodesAndStickyNotes() {
        var locked = node(.textModel, label: "Locked", x: 0, y: 0)
        locked.finalized = FinalRecord(path: "Links/prompts/Locked.txt", kind: .text, lockedAt: Date())
        let note = node(.stickyNote, label: "Note", x: 100, y: 0)
        let runnable = node(.textModel, label: "Runnable", x: 200, y: 0)
        let project = WorkflowProject(name: "Test", nodes: [locked, note, runnable], edges: [])
        XCTAssertEqual(RunPlan.wholeWorkflowTargets(project: project), [runnable.id])
    }

    func testWholeWorkflowTargetsEmptyWhenNothingIsRunnable() {
        var locked = node(.textModel, label: "Locked", x: 0, y: 0)
        locked.finalized = FinalRecord(path: "Links/prompts/Locked.txt", kind: .text, lockedAt: Date())
        let project = WorkflowProject(name: "Test", nodes: [locked], edges: [])
        XCTAssertTrue(RunPlan.wholeWorkflowTargets(project: project).isEmpty)
    }

    func testAggregatePlanCountsASharedGenerativeAncestorOnce() {
        // Both image generators depend on the same upstream text-generating node.
        let shared = node(.textModel, label: "Shared Caption", x: 0, y: 0)
        let imageA = node(.imageGenerator, label: "Image A", x: 100, y: 0)
        let imageB = node(.imageGenerator, label: "Image B", x: 100, y: 100)
        let project = WorkflowProject(name: "Test", nodes: [shared, imageA, imageB], edges: [
            .init(sourceID: shared.id, sourcePortID: "text", targetID: imageA.id, targetPortID: "prompt", type: .text),
            .init(sourceID: shared.id, sourcePortID: "text", targetID: imageB.id, targetPortID: "prompt", type: .text),
        ])
        XCTAssertEqual(RunPlan.make(project: project, target: imageA.id).textGenerations, 1)
        XCTAssertEqual(RunPlan.make(project: project, target: imageB.id).textGenerations, 1)
        let aggregate = RunPlan.make(project: project, targets: [imageA.id, imageB.id])
        XCTAssertEqual(aggregate.textGenerations, 1, "Shared Caption is one ancestor of both targets and must be counted once, not twice")
        XCTAssertEqual(aggregate.imageGenerations, 2)
    }
}
