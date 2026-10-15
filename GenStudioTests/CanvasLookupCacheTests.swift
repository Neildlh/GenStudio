import XCTest
@testable import GenStudio

/// The canvas asks every node for its takes and displayed value on each redraw. Those answers are
/// computed once per take-history change, and must never go stale when the history does change.
@MainActor
final class CanvasLookupCacheTests: XCTestCase {
    private func fixture() -> (StudioModel, WorkflowProject, StudioNode, StudioNode, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "canvas-cache-\(UUID())")
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        let image = StudioNode(kind: .imageGenerator, label: "Still", position: .init(x: 0, y: 0))
        let text = StudioNode(kind: .textModel, label: "Copy", position: .init(x: 0, y: 1))
        let project = WorkflowProject(name: "Cache", nodes: [image, text], edges: [])
        model.projects = [project]; model.currentProjectID = project.id
        return (model, project, image, text, root)
    }

    private func artifact(_ project: WorkflowProject, _ node: StudioNode, _ value: RuntimeValue, age: TimeInterval) -> ExecutionArtifact {
        let port = node.outputPorts[0].id
        return ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project,
                                 values: [PortAddress(nodeID: node.id, portID: port): value], createdAt: Date().addingTimeInterval(-age),
                                 generatedNodeIDs: [node.id])
    }

    func testTakesFollowTheHistoryAsItChanges() {
        let (model, project, image, _, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = artifact(project, image, .image(root.appending(path: "a.png")), age: 20)
        model.executionArtifacts = [first]
        XCTAssertEqual(model.takes(for: image).map(\.id), [first.id])
        XCTAssertEqual(model.displayedValue(for: image), .image(root.appending(path: "a.png")))

        let second = artifact(project, image, .image(root.appending(path: "b.png")), age: 10)
        model.executionArtifacts.insert(second, at: 0)
        XCTAssertEqual(model.takes(for: image).map(\.id), [first.id, second.id], "A new take appears on the next redraw")
        XCTAssertEqual(model.displayedValue(for: image), .image(root.appending(path: "b.png")), "The latest take is shown")

        model.executionArtifacts.removeAll { $0.id == second.id }
        XCTAssertEqual(model.takes(for: image).map(\.id), [first.id], "A deleted take disappears on the next redraw")
    }

    func testLatestResultOfANodeWithoutTakesFollowsTheHistory() {
        let (model, project, _, text, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.executionArtifacts = [artifact(project, text, .text("old"), age: 20)]
        XCTAssertEqual(model.displayedValue(for: text), .text("old"))
        model.executionArtifacts.insert(artifact(project, text, .text("new"), age: 1), at: 0)
        XCTAssertEqual(model.displayedValue(for: text), .text("new"))
    }

    func testTakesAreScopedToTheirWorkflow() {
        let (model, project, image, _, root) = fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var other = project; other = WorkflowProject(name: "Other", nodes: project.nodes, edges: [])
        model.executionArtifacts = [artifact(project, image, .image(root.appending(path: "mine.png")), age: 5),
                                    artifact(other, image, .image(root.appending(path: "theirs.png")), age: 1)]
        XCTAssertEqual(model.takes(for: image).count, 1)
        XCTAssertEqual(model.takes(for: image, inProject: other.id).count, 1)
        model.currentProjectID = other.id
        XCTAssertEqual(model.takes(for: image).first?.values.values.first, .image(root.appending(path: "theirs.png")), "Switching workflow never shows the previous workflow's cached takes")
    }
}
