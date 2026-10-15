import XCTest
@testable import GenStudio

/// "Generate N takes": one confirmation queues a batch of fresh-seed generations of one node, so a
/// long unattended run (an overnight batch) leaves a set of distinct takes to choose from.
@MainActor
final class BatchTakesTests: XCTestCase {
    private struct Fixture {
        let model: StudioModel
        let engine: FixtureVideoEngine
        let node: StudioNode
        let root: URL
    }

    private func fixture(seedLocked: Bool, behaviour: (URL) -> FixtureVideoEngine.Behaviour) async throws -> Fixture {
        let root = try VideoFixtures.root("batch-takes")
        let capability = VideoCapabilityRegistry.fastMetal5TextToVideo
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == capability.recipeID })
        // A batch refreshes the library between takes, so the package must be registered on disk, not only
        // injected. Placeholder files stand in for weights: the fixture engine never reads them.
        let libraryRoot = root.appending(path: "ModelLibrary", directoryHint: .isDirectory)
        let packageRoot = libraryRoot.appending(path: "Installed/fixture", directoryHint: .isDirectory)
        let components: [InstalledModelComponent] = try recipe.components.map { source in
            let file = packageRoot.appending(path: source.filename)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("placeholder".utf8).write(to: file)
            return .init(id: source.id, role: source.role, fileURL: file, source: source)
        }
        let installedModel = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
            components: components, installedAt: Date(), inferenceVerified: false, available: true, recipeSnapshot: recipe)
        struct Registry: Encodable { let schemaVersion = 1; let models: [InstalledGenerationModel] }
        try JSONEncoder().encode(Registry(models: [installedModel])).write(to: libraryRoot.appending(path: "registry.json"))
        var settings = capability.recommended
        settings.frameCount = 21; settings.requestedDurationSeconds = 21.0 / 24.0
        settings.seed = 4242
        let clip = try await VideoFixtures.colorClip((90, 90, 90), frames: settings.frameCount, fps: settings.fps,
                                                      width: settings.width, height: settings.height, in: root, name: "fixture")
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "a greenhouse at dawn")
        var shot = StudioNode(kind: .textToVideo, label: "Shot", position: .init(x: 1, y: 0), model: capability.recipeID)
        shot.video = settings
        shot.seedLocked = seedLocked
        let project = WorkflowProject(name: "Batch", nodes: [prompt, shot], edges: [VideoFixtures.edge(prompt, "text", shot, "prompt", .text)])
        let engine = FixtureVideoEngine(behaviour(clip))
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine(), videoEngine: engine)
        model.libraryStore.installed = [installedModel]
        model.projects = [project]; model.currentProjectID = project.id
        return Fixture(model: model, engine: engine, node: shot, root: root)
    }

    private func waitUntilIdle(_ model: StudioModel) async throws {
        for _ in 0..<500 where model.isRunning || !model.queuedRuns.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isKeepingMacAwake, "Sleep is allowed again once nothing runs or waits")
    }

    func testBatchQueuesDistinctFreshSeedTakesEvenWhenTheSeedIsLocked() async throws {
        let fixture = try await fixture(seedLocked: true) { .succeed($0) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.runTakes(of: fixture.node, count: 3)
        XCTAssertEqual(fixture.model.pendingTakeBatch?.count, 3, "A batch asks once, not once per take")
        fixture.model.confirmPendingTakeBatch()
        XCTAssertTrue(fixture.model.isKeepingMacAwake, "A queued batch keeps the Mac from idling to sleep")
        try await waitUntilIdle(fixture.model)

        XCTAssertNil(fixture.model.alertMessage)
        let requests = await fixture.engine.captured()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map(\.seed)).count, 3, "A locked seed would repeat one take three times; a batch varies it")
        XCTAssertEqual(fixture.model.takes(for: fixture.node).count, 3, "Every take is kept")
        XCTAssertEqual(fixture.model.currentProject?.nodes.first { $0.id == fixture.node.id }?.seedLocked, true, "The node's own lock is untouched")
    }

    func testCancellingABatchStopsTheTakesStillWaiting() async throws {
        let fixture = try await fixture(seedLocked: false) { _ in .waitForCancellation }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.runTakes(of: fixture.node, count: 3)
        fixture.model.confirmPendingTakeBatch()
        for _ in 0..<500 { if await !fixture.engine.captured().isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(fixture.model.isRunning)
        XCTAssertEqual(fixture.model.queuedTakeCount(for: fixture.node.id), 2)

        fixture.model.cancelTakes(of: fixture.node.id)
        try await waitUntilIdle(fixture.model)

        XCTAssertTrue(fixture.model.queuedRuns.isEmpty, "Cancel stops the whole batch, not just the take in flight")
        let requests = await fixture.engine.captured()
        XCTAssertEqual(requests.count, 1)
    }

    func testBatchSizeOutsideTheOfferedRangeQueuesNothing() async throws {
        let fixture = try await fixture(seedLocked: false) { .succeed($0) }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.model.runTakes(of: fixture.node, count: 0)
        XCTAssertNil(fixture.model.pendingTakeBatch)
        fixture.model.runTakes(of: fixture.node, count: StudioModel.maximumTakeBatch + 1)
        XCTAssertNil(fixture.model.pendingTakeBatch)
        XCTAssertTrue(fixture.model.queuedRuns.isEmpty)
    }
}
