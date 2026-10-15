import XCTest
@testable import GenStudio

/// "Start Video Ad": a real local video advert — three stills from FLUX.2 Klein 9B, each animated by a
/// chosen video model, joined in order and exported as a 9:16 vertical video.
@MainActor
final class LocalVideoAdTemplateTests: XCTestCase {
    private func installed(_ id: String) throws -> InstalledGenerationModel {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == id }, id)
        return InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
                                        components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/tmp/\($0.id)"), source: $0) },
                                        installedAt: Date(), inferenceVerified: true, available: true, recipeSnapshot: recipe)
    }

    private func model(installed ids: [String]) throws -> StudioModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "video-ad-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.libraryStore.installed = try ids.map(installed)
        return model
    }

    func testThreeAnimatedStillsAreJoinedInOrderIntoAVerticalAd() throws {
        let model = try model(installed: [MediaModelCatalog.klein9BRecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID])
        model.createLocalVideoAdWorkflow()
        let project = try XCTUnwrap(model.currentProject)

        let stills = project.nodes.filter { $0.kind == .imageGenerator }
        let clips = project.nodes.filter { $0.kind == .imageToVideo }
        XCTAssertEqual(stills.count, 3); XCTAssertEqual(clips.count, 3)
        XCTAssertTrue(stills.allSatisfy { $0.model == MediaModelCatalog.klein9BRecipeID && $0.width == 576 && $0.height == 1024 })
        XCTAssertTrue(clips.allSatisfy { $0.model == MLXVideoModelCatalog.ltx23Q4RecipeID && $0.video.width == 576 && $0.video.height == 1024 && $0.video.frameCount == 121 })

        for clip in clips {
            let inputs = Set(project.edges.filter { $0.targetID == clip.id }.map(\.targetPortID))
            XCTAssertEqual(inputs, ["startImage", "prompt"], "\(clip.label) has its still and its motion prompt")
            XCTAssertNotEqual(clip.video.sound, false, "LTX clips keep their sound")
            let motion = try XCTUnwrap(project.edges.first { $0.targetID == clip.id && $0.targetPortID == "prompt" }.flatMap { edge in project.nodes.first { $0.id == edge.sourceID } })
            XCTAssertEqual(motion.kind, .videoPrompt, "Each shot's motion is directed with camera presets")
            let direction = try XCTUnwrap(motion.videoPromptSettings)
            XCTAssertEqual(direction.mode, .imageToVideo)
            XCTAssertNotNil(VideoCameraMove.named(direction.cameraMovement), "\(motion.label) uses a real camera move")
            XCTAssertFalse(direction.ambience.isEmpty, "\(motion.label) describes the sound of its setting")
            XCTAssertTrue(direction.music.isEmpty, "Per-clip music would change at every cut")
            XCTAssertFalse(direction.compiledPrompt.isEmpty)
        }
        XCTAssertEqual(Set(project.nodes.filter { $0.kind == .videoPrompt }.compactMap { $0.videoPromptSettings?.cameraMovement }).count, 3, "Three different moves")
        let assemble = try XCTUnwrap(project.nodes.first { $0.kind == .assembleVideo })
        XCTAssertEqual(assemble.assembly.audio, .preserve)
        XCTAssertEqual([assemble.assembly.width, assemble.assembly.height, assemble.assembly.fps], [1080, 1920, 24], "Assembled at delivery size so the End Card text is never shrunk and re-enlarged")
        XCTAssertEqual(assemble.assembly.transition, .dissolve, "Soft dissolves between shots")
        XCTAssertFalse(assemble.assembly.fadeIn, "Opens straight on the first shot, a stronger hook")
        XCTAssertTrue(assemble.assembly.fadeOut)
        let order = assemble.dynamicInputs.compactMap { port in project.edges.first { $0.targetID == assemble.id && $0.targetPortID == port.id }?.sourceID }
        XCTAssertEqual(order.compactMap { id in project.nodes.first { $0.id == id }?.label }, ["Shot 1 · Clip", "Shot 2 · Clip", "Shot 3 · Clip", "End Card"])
        let card = try XCTUnwrap(project.nodes.first { $0.kind == .endCard })
        XCTAssertEqual(card.endCardSettings?.width, 1080); XCTAssertEqual(card.endCardSettings?.height, 1920); XCTAssertEqual(card.endCardSettings?.fps, 24)
        let backdrop = try XCTUnwrap(project.edges.first { $0.targetID == card.id && $0.targetPortID == "background" })
        XCTAssertEqual(project.nodes.first { $0.id == backdrop.sourceID }?.label, "Shot 3 · Still", "The last still, darkened, sits behind the card")
        let export = try XCTUnwrap(project.nodes.first { $0.kind == .instagramExport })
        XCTAssertTrue(project.edges.contains { $0.sourceID == assemble.id && $0.targetID == export.id })

        XCTAssertNoThrow(try GraphValidator().validate(project, installedModels: nil, requireRunnableInputs: false))
        let plan = RunPlan.make(project: project, target: export.id)
        XCTAssertEqual(plan.untimedVideoGenerations, 0, "Every clip is timed from this Mac's measurements")
        XCTAssertGreaterThan(plan.estimatedVideoSeconds, 0)
    }

    func testWithoutRecommendedModelsTheTemplateStillBuildsWithModelsToChoose() throws {
        let model = try model(installed: [])
        model.createLocalVideoAdWorkflow()
        let project = try XCTUnwrap(model.currentProject)
        XCTAssertTrue(project.nodes.filter { $0.kind == .imageGenerator || $0.kind == .imageToVideo }.allSatisfy { $0.model.isEmpty })
        XCTAssertTrue(project.nodes.contains { $0.kind == .stickyNote && $0.prompt.contains("Start Here") })
    }
}
