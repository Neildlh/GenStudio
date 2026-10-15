import XCTest
@testable import GenStudio

final class GenerationTakeTests: XCTestCase {
    func testDefaultSeedsVaryWhileLockedSeedsAndOriginalGraphSurvive() throws {
        let image = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 0, y: 0))
        let video = StudioNode(kind: .textToVideo, label: "Video", position: .init(x: 0, y: 0))
        var locked = image
        locked.id = UUID(); locked.seedLocked = true
        let project = WorkflowProject(name: "Seeds", nodes: [image, video, locked], edges: [])
        let first = GenerationSeedPolicy.resolved(project, random: { 123 })
        let second = GenerationSeedPolicy.resolved(project, random: { 456 })
        XCTAssertEqual(first.nodes[0].imageSeed, 123)
        XCTAssertEqual(second.nodes[0].imageSeed, 456)
        XCTAssertEqual(first.nodes[1].video.seed, 123)
        XCTAssertEqual(second.nodes[1].video.seed, 456)
        XCTAssertEqual(first.nodes[2].imageSeed, 424242)
        XCTAssertEqual(project.nodes[0].imageSeed, 424242)
        XCTAssertFalse(project.nodes[0].seedLocked)
        let restored = try JSONDecoder().decode(WorkflowProject.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(restored.nodes[0].imageSeed, 123)
        XCTAssertTrue(restored.nodes[0].seedLocked)
        var customLegacy = image; customLegacy.imageSeed = 321
        XCTAssertTrue(customLegacy.seedLocked)
    }

    @MainActor
    func testTakeNavigationPersistsSelectionAndIgnoresReusedOutputsAndFailures() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        let node = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Takes", nodes: [node], edges: [])
        let address = PortAddress(nodeID: node.id, portID: "image")
        let first = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(root.appending(path: "first.png"))], createdAt: Date(timeIntervalSince1970: 1))
        let second = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(root.appending(path: "second.png"))], createdAt: Date(timeIntervalSince1970: 2))
        let reused = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: UUID(), graphSnapshot: project, values: second.values, createdAt: Date(timeIntervalSince1970: 3), generatedNodeIDs: [])
        model.projects = [project]; model.currentProjectID = project.id
        model.executionArtifacts = [reused, second, first]
        XCTAssertEqual(model.takes(for: node).map(\.id), [first.id, second.id])
        XCTAssertEqual(model.displayedValue(for: node), second.values[address])
        model.stepTake(for: node, by: -1)
        let selected = try XCTUnwrap(model.currentProject?.nodes.first)
        XCTAssertEqual(selected.selectedTakeID, first.id)
        model.supersededAttempts[node.id] = "Latest attempt cancelled"
        XCTAssertEqual(model.displayedValue(for: selected), first.values[address])
        let reopened = try JSONDecoder().decode(WorkflowProject.self, from: JSONEncoder().encode(try XCTUnwrap(model.currentProject)))
        XCTAssertEqual(reopened.nodes[0].selectedTakeID, first.id)
        model.stepTake(for: selected, by: -1)
        XCTAssertEqual(model.currentProject?.nodes.first?.selectedTakeID, first.id)
    }

    @MainActor
    func testDeletingEarlierTakesKeepsSelectedTakeAndRetainedMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTakeDeletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactsDirectory = root.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        let node = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Takes", nodes: [node], edges: [])
        let address = PortAddress(nodeID: node.id, portID: "image")
        let firstURL = artifactsDirectory.appending(path: "first.png")
        let secondURL = artifactsDirectory.appending(path: "second.png")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let first = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(firstURL)], createdAt: Date(timeIntervalSince1970: 1))
        let second = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(secondURL)], createdAt: Date(timeIntervalSince1970: 2))
        let store = StudioPersistence(root: root)
        try await store.saveExecutionArtifact(first)
        try await store.saveExecutionArtifact(second)
        model.projects = [project]
        model.currentProjectID = project.id
        model.executionArtifacts = [second, first]

        await model.deleteEarlierTakes(for: node)

        XCTAssertEqual(model.takes(for: node).map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let persisted = try await store.loadExecutionArtifacts()
        XCTAssertEqual(persisted.map(\.id), [second.id])
    }

    @MainActor
    func testDeletingSelectedTakeSelectsNearestSurvivor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioTakeDeletion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        let node = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Takes", nodes: [node], edges: [])
        let address = PortAddress(nodeID: node.id, portID: "image")
        let first = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(root.appending(path: "first.png"))], createdAt: Date(timeIntervalSince1970: 1))
        let second = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(root.appending(path: "second.png"))], createdAt: Date(timeIntervalSince1970: 2))
        model.projects = [project]
        model.currentProjectID = project.id
        model.executionArtifacts = [second, first]
        model.updateNode(node.id) { $0.selectedTakeID = first.id }

        await model.deleteTake(first, for: node)

        XCTAssertEqual(model.takes(for: node).map(\.id), [second.id])
        XCTAssertEqual(model.currentProject?.nodes.first?.selectedTakeID, second.id)
    }
}
