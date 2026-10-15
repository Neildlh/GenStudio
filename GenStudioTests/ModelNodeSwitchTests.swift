import XCTest
@testable import GenStudio

/// Before a model the advisor marks as not needed can be removed, the nodes that use it can move to the
/// recommended replacement in one step, keeping each clip's length and shape, with undo.
@MainActor
final class ModelNodeSwitchTests: XCTestCase {
    private func installed(_ id: String) throws -> InstalledGenerationModel {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == id }, id)
        return InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
                                        components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/tmp/\($0.id)"), source: $0) },
                                        installedAt: Date(), inferenceVerified: true, available: true, recipeSnapshot: recipe)
    }

    private func model(_ projects: [WorkflowProject], installed ids: [String]) throws -> StudioModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "node-switch-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.libraryStore.installed = try ids.map(installed)
        model.projects = projects; model.currentProjectID = projects.first?.id
        return model
    }

    private func h3Node(_ kind: NodeKind, portrait: Bool) -> StudioNode {
        var node = StudioNode(kind: kind, label: "Shot", position: .init(x: 0, y: 0), model: MediaModelCatalog.minimaxH3RecipeID)
        node.video.width = portrait ? 320 : 576; node.video.height = portrait ? 576 : 320
        node.video.fps = 24; node.video.frameCount = 39; node.video.requestedDurationSeconds = 39.0 / 24.0
        return node
    }

    func testEveryCompatibleNodeAcrossWorkflowsMovesAndKeepsItsShape() throws {
        let startEnd = h3Node(.startEndVideo, portrait: true), i2v = h3Node(.imageToVideo, portrait: false)
        let still = StudioNode(kind: .imageGenerator, label: "Still", position: .init(x: 0, y: 1), model: MediaModelCatalog.kleinRecipeID)
        let audition = WorkflowProject(name: "The Audition", nodes: [startEnd, still], edges: [])
        let chicken = WorkflowProject(name: "Big Chicken", nodes: [i2v], edges: [])
        let model = try model([audition, chicken], installed: [MediaModelCatalog.minimaxH3RecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID, MediaModelCatalog.kleinRecipeID])

        XCTAssertEqual(model.switchableNodeCount(from: MediaModelCatalog.minimaxH3RecipeID, to: MLXVideoModelCatalog.ltx23Q4RecipeID), 2)
        XCTAssertEqual(model.switchNodes(from: MediaModelCatalog.minimaxH3RecipeID, to: MLXVideoModelCatalog.ltx23Q4RecipeID), 2)

        let movedStartEnd = try XCTUnwrap(model.projects[0].nodes.first { $0.id == startEnd.id })
        XCTAssertEqual(movedStartEnd.model, MLXVideoModelCatalog.ltx23Q4RecipeID)
        XCTAssertLessThan(movedStartEnd.video.width, movedStartEnd.video.height, "A portrait clip stays portrait")
        XCTAssertTrue(VideoCapabilityRegistry.ltx23FirstLastFrame.width.contains(movedStartEnd.video.width))
        XCTAssertEqual(model.projects[1].nodes[0].model, MLXVideoModelCatalog.ltx23Q4RecipeID)
        XCTAssertEqual(model.projects[0].nodes.first { $0.id == still.id }?.model, MediaModelCatalog.kleinRecipeID, "Other models are untouched")
    }

    func testANodeTheReplacementCannotRunIsLeftAlone() throws {
        let startEnd = h3Node(.startEndVideo, portrait: false)
        let model = try model([WorkflowProject(name: "A", nodes: [startEnd], edges: [])],
                              installed: [MediaModelCatalog.minimaxH3RecipeID, MLXVideoModelCatalog.fastMetal5BRecipeID])
        XCTAssertEqual(model.switchNodes(from: MediaModelCatalog.minimaxH3RecipeID, to: MLXVideoModelCatalog.fastMetal5BRecipeID), 0, "FastMetal is text-to-video only")
        XCTAssertEqual(model.projects[0].nodes[0].model, MediaModelCatalog.minimaxH3RecipeID)
    }

    func testTheSwitchCanBeUndone() throws {
        let still = StudioNode(kind: .imageGenerator, label: "Still", position: .init(x: 0, y: 0), model: MediaModelCatalog.kleinRecipeID)
        let model = try model([WorkflowProject(name: "A", nodes: [still], edges: [])], installed: [MediaModelCatalog.kleinRecipeID, MediaModelCatalog.klein9BRecipeID])
        XCTAssertEqual(model.switchNodes(from: MediaModelCatalog.kleinRecipeID, to: MediaModelCatalog.klein9BRecipeID), 1)
        XCTAssertEqual(model.currentProject?.nodes[0].model, MediaModelCatalog.klein9BRecipeID)
        model.undo()
        XCTAssertEqual(model.currentProject?.nodes[0].model, MediaModelCatalog.kleinRecipeID)
    }

    func testImageDescribersUsingAMissingModelMoveToTheInstalledReplacement() throws {
        let describers = (0..<2).map { StudioNode(kind: .imageDescriber, label: "Describe \($0)", position: .init(x: Double($0), y: 0), model: "vision-smolvlm-500m-q8") }
        let model = try model([WorkflowProject(name: "06. Audition", nodes: describers, edges: [])], installed: [MLXVLMModelCatalog.qwen38RecipeID])
        let missing = try XCTUnwrap(model.modelAdvice.missing.first)
        XCTAssertEqual(missing.replacementRecipeID, MLXVLMModelCatalog.qwen38RecipeID)
        XCTAssertEqual(model.switchNodes(from: missing.modelID, to: MLXVLMModelCatalog.qwen38RecipeID), 2)
        XCTAssertTrue(model.projects[0].nodes.allSatisfy { $0.model == MLXVLMModelCatalog.qwen38RecipeID })
    }
}
