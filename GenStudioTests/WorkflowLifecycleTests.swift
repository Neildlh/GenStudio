import XCTest
@testable import GenStudio

@MainActor
final class WorkflowLifecycleTests: XCTestCase {
    func testGenerationCanStartWhileModelDownloadIsActive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "hello")
        let target = StudioNode(kind: .textModel, label: "Text", position: .init(x: 300, y: 0), model: "stub")
        let project = WorkflowProject(name: "Concurrent work", nodes: [prompt, target], edges: [
            .init(sourceID: prompt.id, targetID: target.id, type: .text)
        ])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine(delay: .milliseconds(250)))
        model.projects = [project]
        model.currentProjectID = project.id
        model.selectedNodeID = target.id
        model.models = [.init(name: "stub", size: nil, digest: nil)]
        model.libraryStore.activeRecipeID = "background-download"

        model.runSelected()

        XCTAssertTrue(model.isRunning, "A background download must not disable inference with an installed model")
        XCTAssertTrue(model.libraryStore.generationRunning)
        XCTAssertNil(model.alertMessage)
        for _ in 0..<100 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.outputs.first?.text, "result")
    }

    func testShortAdvertTemplateProvidesThreeReferencesBriefHeroStillAndAnimatic() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.createShortAdvertWorkflow()
        let project = try XCTUnwrap(model.currentProject)

        XCTAssertEqual(project.name, "Short Advert · Character + Scene")
        XCTAssertEqual(project.nodes.filter { $0.kind == .imageInput }.count, 3)
        let describer = try XCTUnwrap(project.nodes.first { $0.kind == .imageDescriber })
        XCTAssertEqual(describer.dynamicInputs.map(\.label), ["Character Sheet", "Portrait", "Scene"])
        XCTAssertEqual(project.nodes.first { $0.kind == .imageGenerator }?.model, "")
        XCTAssertEqual(project.nodes.first { $0.kind == .shotSequence }?.sequence.anchors.map(\.label), ["Setup", "Action", "Punchline / End Card"])
        XCTAssertTrue(project.nodes.contains { $0.kind == .animatic })
        XCTAssertEqual(project.edges.filter { $0.targetID == describer.id && $0.type == .image }.count, 3)
        XCTAssertTrue(project.edges.contains { $0.type == .shotSequence })
        _ = try GraphValidator().validate(project, requireRunnableInputs: false)
    }

    func testQueuedSavesCannotResurrectDeletedWorkflowAndAssetsSurvive() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioPersistence(root: root)
        let model = StudioModel(persistence: store, engine: StubEngine())
        model.createProject()
        let deleted = try XCTUnwrap(model.currentProject)
        try model.renameProject(deleted.id, to: "queued rename")
        model.addNode(.prompt)
        let survivor = WorkflowProject(name: "Survivor", nodes: [], edges: [])
        model.projects.append(survivor); try await store.saveProject(survivor)
        let asset = root.appending(path: "Artifacts/retained.png")
        try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("retained".utf8).write(to: asset)
        await model.deleteProject(deleted.id)
        XCTAssertEqual(model.currentProjectID, survivor.id)
        try await store.saveProject(deleted)
        let fresh = StudioPersistence(root: root)
        try await fresh.saveProject(deleted)
        let remaining = try await fresh.loadProjects()
        XCTAssertEqual(remaining.map(\.id), [survivor.id])
        XCTAssertEqual(try Data(contentsOf: asset), Data("retained".utf8))
        await model.deleteProject(survivor.id)
        XCTAssertNil(model.currentProjectID)
        let empty = try await fresh.loadProjects()
        XCTAssertTrue(empty.isEmpty)
        let restarted = StudioModel(persistence: fresh, engine: StubEngine())
        await restarted.start()
        XCTAssertTrue(restarted.projects.isEmpty)
    }

    func testGraphUndoKeepsRenamedWorkflowName() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.createProject(); model.addNode(.prompt)
        let id = try XCTUnwrap(model.currentProjectID)
        try model.renameProject(id, to: "Renamed")
        model.undo()
        XCTAssertEqual(model.currentProject?.name, "Renamed")
        XCTAssertEqual(model.currentProject?.nodes.count, 0)
        model.redo()
        XCTAssertEqual(model.currentProject?.name, "Renamed")
        XCTAssertEqual(model.currentProject?.nodes.count, 1)
        await model.flushProjectWrites()
    }

    func testWireColourPersistsAndIsUndoable() throws {
        let source = StudioNode(kind: .prompt, label: "Source", position: .init(x: 0, y: 0))
        let target = StudioNode(kind: .textPreview, label: "Target", position: .init(x: 300, y: 0))
        let edge = StudioEdge(sourceID: source.id, sourcePortID: "text", targetID: target.id, targetPortID: "text", type: .text)
        let project = WorkflowProject(name: "Colours", nodes: [source, target], edges: [edge])
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        model.setWireColor(edgeID: edge.id, color: .pink)
        XCTAssertEqual(model.currentProject?.edges.first?.color, .pink)
        let reopened = try JSONDecoder().decode(WorkflowProject.self, from: JSONEncoder().encode(try XCTUnwrap(model.currentProject)))
        XCTAssertEqual(reopened.edges.first?.color, .pink)
        model.undo()
        XCTAssertNil(model.currentProject?.edges.first?.color)
    }

    func testCopyPasteConnectionsOnlyTouchesTheOnePortInvolved() throws {
        let source = StudioNode(kind: .prompt, label: "Source", position: .init(x: 0, y: 0))
        let otherOutput = StudioNode(kind: .prompt, label: "Other Source", position: .init(x: 0, y: 200))
        let numberSource = StudioNode(kind: .number, label: "Number", position: .init(x: 0, y: 400))
        let target1 = StudioNode(kind: .textPreview, label: "Target 1", position: .init(x: 300, y: 0))
        let target2 = StudioNode(kind: .textPreview, label: "Target 2", position: .init(x: 300, y: 200))
        let target3 = StudioNode(kind: .textPreview, label: "Target 3", position: .init(x: 300, y: 400))
        // `otherOutput` already feeds `target4` on its own, before any copy/paste — that connection must
        // survive the paste, since paste only replaces the specific targets it is applying, not this port's
        // other existing wiring.
        let target4 = StudioNode(kind: .textPreview, label: "Target 4", position: .init(x: 300, y: 600))
        let edges = [
            StudioEdge(sourceID: source.id, sourcePortID: "text", targetID: target1.id, targetPortID: "text", type: .text),
            StudioEdge(sourceID: source.id, sourcePortID: "text", targetID: target2.id, targetPortID: "text", type: .text),
            StudioEdge(sourceID: otherOutput.id, sourcePortID: "text", targetID: target4.id, targetPortID: "text", type: .text)
        ]
        let project = WorkflowProject(name: "Fan-out", nodes: [source, otherOutput, numberSource, target1, target2, target3, target4], edges: edges)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id

        let sourceOutput = PortAddress(nodeID: source.id, portID: "text")
        let otherOutputAddress = PortAddress(nodeID: otherOutput.id, portID: "text")
        XCTAssertTrue(model.hasConnections(at: sourceOutput, direction: .output))
        XCTAssertFalse(model.canPasteConnections(onto: otherOutputAddress, portType: .text, direction: .output), "Nothing copied yet")

        // Copy the fan-out from `source`'s output and paste it onto a second output that already has wiring of its own.
        model.copyConnections(from: sourceOutput, direction: .output)
        XCTAssertFalse(model.canPasteConnections(onto: sourceOutput, portType: .text, direction: .output), "Pasting onto the port copied from is a no-op, so it stays disabled")
        let numberOutput = PortAddress(nodeID: numberSource.id, portID: "number")
        XCTAssertFalse(model.canPasteConnections(onto: numberOutput, portType: .number, direction: .output), "Different port type must not be pasteable")
        XCTAssertTrue(model.canPasteConnections(onto: otherOutputAddress, portType: .text, direction: .output))

        model.pasteConnections(onto: otherOutputAddress)

        let afterPaste = try XCTUnwrap(model.currentProject?.edges)
        XCTAssertEqual(afterPaste.filter { $0.sourceID == source.id }.count, 0, "An input only ever has one source, so pasting hands target1/target2 over to the new output")
        XCTAssertEqual(afterPaste.filter { $0.sourceID == otherOutput.id }.count, 3, "The pasted-onto port's own pre-existing wiring (to target4) is additive, not replaced")
        XCTAssertTrue(afterPaste.contains { $0.sourceID == otherOutput.id && $0.targetID == target1.id })
        XCTAssertTrue(afterPaste.contains { $0.sourceID == otherOutput.id && $0.targetID == target2.id })
        XCTAssertTrue(afterPaste.contains { $0.sourceID == otherOutput.id && $0.targetID == target4.id }, "Untouched by the paste")
        XCTAssertNil(model.alertMessage, "Every copied connection had a compatible match, so no summary is needed")

        // Copying an input's single source and pasting it onto a different, unconnected input.
        let target1Input = PortAddress(nodeID: target1.id, portID: "text")
        let target3Input = PortAddress(nodeID: target3.id, portID: "text")
        XCTAssertTrue(model.hasConnections(at: target1Input, direction: .input))
        model.copyConnections(from: target1Input, direction: .input)
        model.pasteConnections(onto: target3Input)
        let afterInputPaste = try XCTUnwrap(model.currentProject?.edges)
        XCTAssertEqual(afterInputPaste.filter { $0.targetID == target3.id }.count, 1)
        XCTAssertTrue(afterInputPaste.contains { $0.sourceID == otherOutput.id && $0.targetID == target3.id })

        // The same node also has an OUTPUT port with the same id ("text") — copying/checking the input must
        // never be confused with that output, since `PortAddress` alone doesn't disambiguate direction.
        XCTAssertFalse(model.hasConnections(at: target1Input, direction: .output), "Target1's *output* isn't wired to anything, only its input is")
    }

    func testRenameAndDuplicateInactiveWorkflowPreserveTopologyWithNewIdentities() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = StudioNode(kind: .prompt, label: "P", position: .init(x: 1, y: 2), prompt: "hello", imagePath: "/retained/image.png")
        let combine = StudioNode(kind: .combineText, label: "C", position: .init(x: 3, y: 4))
        let edge = StudioEdge(sourceID: source.id, sourcePortID: "text", targetID: combine.id, targetPortID: combine.inputPorts[0].id, type: .text)
        let original = WorkflowProject(name: "Original", nodes: [source, combine], edges: [edge])
        let active = WorkflowProject(name: "Active", nodes: [], edges: [])
        let store = StudioPersistence(root: root)
        let model = StudioModel(persistence: store, engine: StubEngine())
        model.projects = [active, original]; model.currentProjectID = active.id
        XCTAssertThrowsError(try model.renameProject(original.id, to: " \n "))
        try model.renameProject(original.id, to: "  Renamed  ")
        XCTAssertEqual(model.currentProjectID, active.id)
        model.duplicateProject(original.id)
        let copy = try XCTUnwrap(model.currentProject)
        XCTAssertEqual(copy.name, "Renamed Copy")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertTrue(Set(copy.nodes.map(\.id)).isDisjoint(with: original.nodes.map(\.id)))
        XCTAssertNotEqual(copy.edges[0].id, edge.id)
        XCTAssertEqual(copy.edges[0].sourceID, copy.nodes[0].id)
        XCTAssertEqual(copy.edges[0].targetID, copy.nodes[1].id)
        XCTAssertEqual(copy.edges[0].targetPortID, copy.nodes[1].inputPorts[0].id)
        XCTAssertNotEqual(copy.nodes[1].inputPorts[0].id, combine.inputPorts[0].id)
        XCTAssertEqual(copy.nodes[0].imagePath, source.imagePath)
        model.duplicateProject(original.id)
        XCTAssertEqual(model.currentProject?.name, "Renamed Copy 2")
        await model.flushProjectWrites()
        let loaded = try await StudioPersistence(root: root).loadProjects()
        XCTAssertEqual(loaded.first(where: { $0.id == original.id })?.name, "Renamed")
        XCTAssertEqual(loaded.first(where: { $0.id == copy.id })?.edges, copy.edges)
    }
}
