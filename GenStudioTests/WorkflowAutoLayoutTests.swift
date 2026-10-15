import XCTest
@testable import GenStudio

final class WorkflowAutoLayoutTests: XCTestCase {
    private func node(_ kind: NodeKind, _ name: String) -> StudioNode {
        .init(kind: kind, label: name, position: .init(x: -900, y: 900))
    }
    private func edge(_ source: StudioNode, _ target: StudioNode) -> StudioEdge {
        .init(sourceID: source.id, targetID: target.id, type: source.kind.outputType ?? .text)
    }
    private func assertNoOverlap(_ nodes: [StudioNode], _ positions: [UUID: CanvasPoint], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(Set(positions.keys), Set(nodes.map(\.id)), file: file, line: line)
        let frames = try nodes.map { node -> CGRect in
            let p = try XCTUnwrap(positions[node.id], file: file, line: line)
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, file: file, line: line)
            return CGRect(x: p.x - NodeLayout.leadingOverflow(node), y: p.y,
                          width: NodeLayout.leadingOverflow(node) + NodeLayout.cardWidth(node) + NodeLayout.trailingOverflow(node),
                          height: NodeLayout.cardHeight(node))
        }
        for a in frames.indices {
            for b in frames.indices where b > a {
                XCTAssertFalse(frames[a].intersects(frames[b]), "Cards or socket labels overlap: \(nodes[a].label), \(nodes[b].label)", file: file, line: line)
            }
        }
    }

    func testTidiesNearbyRowsWithoutReplacingTheAuthorDefinedFlow() throws {
        let prompt = node(.prompt, "Prompt"), image = node(.imageInput, "Image")
        let describe = node(.imageDescriber, "Describe"), text = node(.textModel, "Text")
        let generate = node(.imageGenerator, "Generate"), preview = node(.imagePreview, "Preview")
        let nodes = [preview, generate, text, describe, image, prompt].enumerated().map { (entry: (offset: Int, element: StudioNode)) -> StudioNode in
            var node = entry.element
            node.position = [
                CanvasPoint(x: 1_320, y: 430), CanvasPoint(x: 900, y: 420), CanvasPoint(x: 580, y: 408),
                CanvasPoint(x: 250, y: 396), CanvasPoint(x: -760, y: 1_080), CanvasPoint(x: -1_060, y: 1_040)
            ][entry.offset]
            return node
        }
        let edges = [edge(image, describe), edge(prompt, describe), edge(describe, text), edge(text, generate), edge(generate, preview)]
        let positions = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        try assertNoOverlap(nodes, positions)
        let promptPosition = try XCTUnwrap(positions[prompt.id])
        let imagePosition = try XCTUnwrap(positions[image.id])
        let describePosition = try XCTUnwrap(positions[describe.id])
        let textPosition = try XCTUnwrap(positions[text.id])
        let generatePosition = try XCTUnwrap(positions[generate.id])
        let previewPosition = try XCTUnwrap(positions[preview.id])
        XCTAssertEqual(promptPosition.x, imagePosition.x, "Two inputs feeding the same node share one column.")
        XCTAssertLessThan(imagePosition.x, describePosition.x)
        XCTAssertLessThan(describePosition.x, textPosition.x)
        XCTAssertLessThan(textPosition.x, generatePosition.x)
        XCTAssertLessThan(generatePosition.x, previewPosition.x)
        XCTAssertEqual(describePosition.y, textPosition.y, "Nodes in the same rough lane align to one row.")
        XCTAssertGreaterThan(imagePosition.y, describePosition.y, "The separate lower input remains below the main flow.")
    }

    func testTidyingIsRepeatableAndKeepsSeparateGroupsInTheirAreas() throws {
        var nodes = [node(.prompt, "A"), node(.textModel, "B"), node(.textPreview, "C")]
        let edges = [edge(nodes[0], nodes[1]), edge(nodes[1], nodes[2])]
        nodes[0].position = .init(x: -2_400, y: 1_900)
        nodes[1].position = .init(x: -1_950, y: 1_920)
        nodes[2].position = .init(x: -1_400, y: 1_940)
        let first = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        let firstPosition = try XCTUnwrap(first[nodes[0].id])
        let secondPosition = try XCTUnwrap(first[nodes[1].id])
        let thirdPosition = try XCTUnwrap(first[nodes[2].id])
        XCTAssertLessThan(firstPosition.x, secondPosition.x)
        XCTAssertLessThan(secondPosition.x, thirdPosition.x)
        for index in nodes.indices { nodes[index].position = first[nodes[index].id]! }
        XCTAssertEqual(first, WorkflowAutoLayout.positions(nodes: nodes, edges: edges))
    }

    func testDisconnectedGroupsAndLargeDynamicNodesDoNotOverlap() throws {
        var tall = node(.combineText, "Many inputs")
        tall.dynamicInputs = (1...30).map { .init(label: "Part \($0)") }
        let nodes = [node(.prompt, "Prompt"), tall, node(.textPreview, "Result"), node(.imageInput, "Image"), node(.imagePreview, "Image result"), node(.stickyNote, "Note"), node(.number, "Number")]
        let edges = [edge(nodes[0], nodes[1]), edge(nodes[1], nodes[2]), edge(nodes[3], nodes[4])]
        try assertNoOverlap(nodes, WorkflowAutoLayout.positions(nodes: nodes, edges: edges))
    }

    func testMalformedEdgesAndCyclesHaveFiniteSafeFallback() throws {
        let nodes = [node(.textRouter, "A"), node(.textRouter, "B"), node(.textRouter, "C"), node(.prompt, "Separate")]
        let edges = [edge(nodes[0], nodes[1]), edge(nodes[1], nodes[2]), edge(nodes[2], nodes[0]), edge(nodes[0], nodes[0]), edge(nodes[0], nodes[1]), .init(sourceID: UUID(), targetID: nodes[0].id, type: .text)]
        let result = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        try assertNoOverlap(nodes, result)
        XCTAssertEqual(result, WorkflowAutoLayout.positions(nodes: nodes, edges: edges))
        XCTAssertTrue(WorkflowAutoLayout.positions(nodes: [], edges: edges).isEmpty)
    }

    func testAnInputSitsBesideTheNodeItFeedsRatherThanInTheFirstColumn() throws {
        // The single biggest cause of sprawl: longest-path layering strands
        // every unconnected input in column zero, however late it is consumed.
        var chain = [node(.prompt, "A"), node(.textModel, "B"), node(.textModel, "C"), node(.textModel, "Consumer")]
        let late = node(.prompt, "Late input")
        for index in chain.indices { chain[index].position = .init(x: Double(index) * 400, y: 0) }
        let nodes = chain + [late]
        let edges = [edge(chain[0], chain[1]), edge(chain[1], chain[2]), edge(chain[2], chain[3]), edge(late, chain[3])]
        let positions = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        try assertNoOverlap(nodes, positions)
        let latePosition = try XCTUnwrap(positions[late.id])
        let neighbour = try XCTUnwrap(positions[chain[2].id])
        let start = try XCTUnwrap(positions[chain[0].id])
        XCTAssertEqual(latePosition.x, neighbour.x, "A late input shares the column of the node it feeds into.")
        XCTAssertGreaterThan(latePosition.x, start.x, "It is not left stranded in the first column.")
    }

    func testAChainRunsDeadStraightAcrossItsColumns() throws {
        var nodes = [node(.prompt, "A"), node(.textModel, "B"), node(.textModel, "C"), node(.textPreview, "D")]
        for index in nodes.indices { nodes[index].position = .init(x: Double(index) * 300, y: Double(index) * 137) }
        let edges = (0..<3).map { edge(nodes[$0], nodes[$0 + 1]) }
        let positions = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        let tops = try nodes.map { try XCTUnwrap(positions[$0.id]).y }
        for top in tops { XCTAssertEqual(top, tops[0], accuracy: 0.5, "Every card in one chain shares a row.") }
    }

    func testPocketsWrapIntoABoardInsteadOfOneEndlessStrip() throws {
        var nodes: [StudioNode] = []
        var edges: [StudioEdge] = []
        for pocket in 0..<6 {
            var head = node(.prompt, "Head \(pocket)"), tail = node(.textPreview, "Tail \(pocket)")
            head.position = .init(x: Double(pocket) * 2_000, y: 0)
            tail.position = .init(x: Double(pocket) * 2_000 + 400, y: 0)
            edges.append(edge(head, tail))
            nodes.append(contentsOf: [head, tail])
        }
        let positions = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        try assertNoOverlap(nodes, positions)
        let xs = try nodes.map { try XCTUnwrap(positions[$0.id]).x }
        let ys = try nodes.map { try XCTUnwrap(positions[$0.id]).y }
        let width = xs.max()! - xs.min()!
        XCTAssertGreaterThan(ys.max()! - ys.min()!, 0, "Pockets stack onto more than one shelf.")
        XCTAssertLessThan(width, 6 * 1_000, "Pockets wrap rather than trailing off to the right.")
    }

    func testEachLooseCardTravelsWithTheFlowItWasParkedBeside() throws {
        var near = [node(.prompt, "A"), node(.textModel, "B"), node(.textPreview, "C")]
        var far = [node(.prompt, "D"), node(.textModel, "E"), node(.textPreview, "F")]
        for index in near.indices {
            near[index].position = .init(x: Double(index) * 400, y: 0)
            far[index].position = .init(x: Double(index) * 400, y: 9_000)
        }
        var noteForNear = node(.stickyNote, "Note near"), noteForFar = node(.stickyNote, "Note far")
        noteForNear.position = .init(x: 300, y: 260)
        noteForFar.position = .init(x: 300, y: 9_260)
        let nodes = near + far + [noteForNear, noteForFar]
        let edges = (0..<2).flatMap { [edge(near[$0], near[$0 + 1]), edge(far[$0], far[$0 + 1])] }
        let positions = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        try assertNoOverlap(nodes, positions)
        for (note, flow) in [(noteForNear, near), (noteForFar, far)] {
            let notePosition = try XCTUnwrap(positions[note.id])
            let flowPositions = try flow.map { try XCTUnwrap(positions[$0.id]) }
            XCTAssertGreaterThan(notePosition.y, flowPositions.map(\.y).max()!, "\(note.label) parks beneath its own flow.")
            XCTAssertLessThan(abs(notePosition.x - flowPositions.map(\.x).min()!), 400, "\(note.label) stays within that flow's span.")
            XCTAssertLessThan(notePosition.y - flowPositions.map(\.y).max()!, 1_000, "\(note.label) stays with that flow, not the other one.")
        }
    }

    func testTidyingASelectionLeavesEverythingElseAlone() throws {
        var first = [node(.prompt, "A"), node(.textPreview, "B")]
        var second = [node(.prompt, "C"), node(.textPreview, "D")]
        first[0].position = .init(x: 0, y: 0); first[1].position = .init(x: 900, y: 460)
        second[0].position = .init(x: 0, y: 4_000); second[1].position = .init(x: 900, y: 4_460)
        let nodes = first + second
        let edges = [edge(first[0], first[1]), edge(second[0], second[1])]
        let scope = Set(first.map(\.id))
        let positions = WorkflowAutoLayout.positions(nodes: nodes, edges: edges, scope: scope)
        XCTAssertEqual(Set(positions.keys), scope, "Only the selected nodes are repositioned.")
        let tidied = try first.map { try XCTUnwrap(positions[$0.id]) }
        XCTAssertEqual(tidied[0].y, tidied[1].y, accuracy: 0.5, "The selected pair is tidied into one row.")
        XCTAssertEqual(tidied.map(\.y).min()!, first.map(\.position.y).min()!, accuracy: 0.5, "It is tidied where it already sat.")
    }

    func testOrganisingASecondTimeChangesNothing() throws {
        var flow = [node(.prompt, "A"), node(.textModel, "B"), node(.textModel, "C"), node(.textPreview, "D")]
        for index in flow.indices { flow[index].position = .init(x: Double(index) * 517, y: Double(index % 3) * 311) }
        var note = node(.stickyNote, "Note"); note.position = .init(x: 420, y: 300)
        var lone = node(.imageInput, "Spare"); lone.position = .init(x: 6_000, y: -2_400)
        var fanned = node(.textPreview, "Fan"); fanned.position = .init(x: 2_000, y: 900)
        var nodes = flow + [note, lone, fanned]
        let edges = (0..<3).map { edge(flow[$0], flow[$0 + 1]) } + [edge(flow[1], fanned)]
        let first = WorkflowAutoLayout.positions(nodes: nodes, edges: edges)
        try assertNoOverlap(nodes, first)
        for index in nodes.indices { nodes[index].position = try XCTUnwrap(first[nodes[index].id]) }
        XCTAssertEqual(first, WorkflowAutoLayout.positions(nodes: nodes, edges: edges))
    }

    func testColumnPlacementHonoursSeparationWhileHittingFreeTargets() {
        let free = LayeredFlowLayout.settle(desired: [0, 500, 1_000], weights: [1, 1, 1], separations: [100, 100])
        XCTAssertEqual(free, [0, 500, 1_000], "Cards that already clear each other are left exactly where they want to be.")
        let squeezed = LayeredFlowLayout.settle(desired: [300, 300, 300], weights: [1, 1, 1], separations: [100, 100])
        XCTAssertEqual(squeezed[1] - squeezed[0], 100, accuracy: 0.001)
        XCTAssertEqual(squeezed[2] - squeezed[1], 100, accuracy: 0.001)
        XCTAssertEqual((squeezed[0] + squeezed[1] + squeezed[2]) / 3, 300, accuracy: 0.001, "A crowded column stays centred on its target.")
    }
}

@MainActor
final class OrganiseWorkflowTests: XCTestCase {
    func testOrganiseIsOneUndoableSavedEditPreservingWorkflowContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = StudioNode(kind: .prompt, label: "Campaign", position: .init(x: 700, y: -250), prompt: "Keep the product label")
        let output = StudioNode(kind: .textPreview, label: "Result", position: .init(x: -300, y: 950))
        let project = WorkflowProject(name: "Messy", nodes: [prompt, output], edges: [.init(sourceID: prompt.id, sourcePortID: "text", targetID: output.id, targetPortID: "text", type: .text)], viewport: .init(offset: .init(x: -500, y: 200), zoom: 0.8))
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id; model.selectedNodeID = prompt.id
        model.organiseNodes()
        let arranged = try XCTUnwrap(model.currentProject)
        XCTAssertNotEqual(arranged.nodes.map(\.position), project.nodes.map(\.position))
        var content = arranged
        for index in content.nodes.indices { content.nodes[index].position = project.nodes[index].position }
        content.updatedAt = project.updatedAt
        XCTAssertEqual(content, project)
        XCTAssertEqual(model.selectedNodeID, prompt.id)
        model.organiseNodes()
        XCTAssertEqual(model.currentProject, arranged, "Repeating Organise should not add an undo entry.")
        model.undo()
        XCTAssertEqual(model.currentProject, project)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.currentProject, arranged)
        await model.flushProjectWrites()
        let saved = try await StudioPersistence(root: root).loadProjects()
        let restored = try XCTUnwrap(saved.first)
        XCTAssertEqual(restored.nodes, arranged.nodes)
        XCTAssertEqual(restored.edges, arranged.edges)
        XCTAssertEqual(restored.viewport, arranged.viewport)
        XCTAssertEqual(restored.id, arranged.id)
        XCTAssertEqual(restored.name, arranged.name)
        // Persistence stores ISO-8601 timestamps at whole-second precision.
        XCTAssertEqual(restored.updatedAt.timeIntervalSince1970, arranged.updatedAt.timeIntervalSince1970, accuracy: 1)
    }
}
