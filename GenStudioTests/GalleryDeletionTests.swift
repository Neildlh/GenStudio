import XCTest
@testable import GenStudio

final class GalleryPersistenceDeletionTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "GenStudioGalleryTests-\(UUID().uuidString)")
    }

    func testDeletingTextOutputRemovesPersistedRecord() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioPersistence(root: root)
        let output = TextOutput(id: UUID(), runID: UUID(), projectID: UUID(), nodeID: UUID(), prompt: "p", model: "m", text: "bad output", createdAt: Date())

        try await store.saveOutput(output)
        try await store.deleteOutput(output.id)

        let remaining = try await store.loadOutputs()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeletingWorkflowResultRemovesOnlyUnsharedRetainedMedia() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactsDirectory = root.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
        let shared = artifactsDirectory.appending(path: "shared.png")
        let unique = artifactsDirectory.appending(path: "unique.png")
        try Data("shared".utf8).write(to: shared)
        try Data("unique".utf8).write(to: unique)

        let store = StudioPersistence(root: root)
        let project = WorkflowProject(name: "Gallery", nodes: [], edges: [])
        let sharedAddress = PortAddress(nodeID: UUID(), portID: "shared")
        let uniqueAddress = PortAddress(nodeID: UUID(), portID: "unique")
        let deleted = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: UUID(), graphSnapshot: project, values: [sharedAddress: .image(shared), uniqueAddress: .image(unique)], createdAt: Date())
        let survivor = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: UUID(), graphSnapshot: project, values: [sharedAddress: .image(shared)], createdAt: Date().addingTimeInterval(-1))
        try await store.saveExecutionArtifact(deleted)
        try await store.saveExecutionArtifact(survivor)

        try await store.deleteExecutionArtifact(deleted)

        let remaining = try await store.loadExecutionArtifacts()
        XCTAssertEqual(remaining.map(\.id), [survivor.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unique.path))
    }

    func testWorkflowResultDeletionNeverRemovesFilesOutsideArtifactStore() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let external = FileManager.default.temporaryDirectory.appending(path: "GenStudioExternal-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("original".utf8).write(to: external)
        let store = StudioPersistence(root: root)
        let project = WorkflowProject(name: "Gallery", nodes: [], edges: [])
        let artifact = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: UUID(), graphSnapshot: project, values: [.init(nodeID: UUID(), portID: "image"): .image(external)], createdAt: Date())
        try await store.saveExecutionArtifact(artifact)

        try await store.deleteExecutionArtifact(artifact)

        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    }
}

@MainActor
final class GalleryModelDeletionTests: XCTestCase {
    func testBulkDeletingGalleryItemsUpdatesPublishedState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioGalleryModelTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioPersistence(root: root)
        let model = StudioModel(persistence: store, engine: StubEngine())
        let project = WorkflowProject(name: "Gallery", nodes: [], edges: [])
        let outputs = (0..<3).map { index in
            TextOutput(id: UUID(), runID: UUID(), projectID: project.id, nodeID: UUID(), prompt: "p", model: "m", text: "discard me \(index)", createdAt: Date())
        }
        let artifacts = (0..<2).map { _ in
            ExecutionArtifact(id: UUID(), projectID: project.id, targetID: UUID(), graphSnapshot: project, values: [:], createdAt: Date())
        }
        for output in outputs { try await store.saveOutput(output) }
        for artifact in artifacts { try await store.saveExecutionArtifact(artifact) }
        model.outputs = outputs
        model.executionArtifacts = artifacts

        await model.deleteGalleryItems(outputIDs: Set(outputs.map(\.id)), artifactIDs: Set(artifacts.map(\.id)))

        XCTAssertTrue(model.outputs.isEmpty)
        XCTAssertTrue(model.executionArtifacts.isEmpty)
        let savedOutputs = try await store.loadOutputs()
        let savedArtifacts = try await store.loadExecutionArtifacts()
        XCTAssertTrue(savedOutputs.isEmpty)
        XCTAssertTrue(savedArtifacts.isEmpty)
    }
}
