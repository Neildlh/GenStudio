import XCTest
@testable import GenStudio

/// The app tells the owner, for this Mac, which installed models to keep, which cannot be used, which are
/// not needed (with what replaces them), which models workflows use that are missing, and what to add.
final class ModelAdvisorTests: XCTestCase {
    private let mac = HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "27.0", freeDiskBytes: 800 << 30)

    private func recipe(_ id: String) throws -> ModelRecipe { try XCTUnwrap(ModelCatalog.recipes.first { $0.id == id }, id) }

    private func installed(_ recipe: ModelRecipe, available: Bool = true) -> InstalledGenerationModel {
        InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
                                 components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/tmp/\($0.id)"), source: $0) },
                                 installedAt: Date(), inferenceVerified: true, available: available, recipeSnapshot: recipe)
    }

    private func updateCopy(of original: ModelRecipe) -> ModelRecipe {
        ModelRecipe(id: original.id + "-v-7c7e1618", name: original.name, kind: original.kind, engineID: original.engineID, components: original.components,
                    runtimeReady: false, minimumMemoryBytes: original.minimumMemoryBytes, baseRecipeID: original.id, runtimeProfile: original.runtimeProfile)
    }

    private func report(_ models: [InstalledGenerationModel], hardware: HardwareProfile? = nil, projects: [WorkflowProject] = [], runs: [RunRecord] = []) -> ModelAdviceReport {
        ModelAdvisor.report(installed: models, hardware: hardware ?? mac, projects: projects, runs: runs)
    }

    private func advice(_ id: String, in report: ModelAdviceReport) throws -> ModelAdvice { try XCTUnwrap(report.advice.first { $0.id == id }, id) }

    func testAModelWhoseRouteIsWithdrawnCannotBeUsed() throws {
        let ltx25 = try recipe(MediaModelCatalog.ltx25RecipeID)
        let result = try advice(ltx25.id, in: report([installed(ltx25)]))
        XCTAssertEqual(result.status, .cannotRun)
        XCTAssertTrue(result.reason.hasPrefix("GenStudio can't run this model here"), result.reason)
        XCTAssertTrue(result.detail?.contains("first frame") == true, "The technical reason stays available")
    }

    func testNamesAreShortAndCarryTheirVersion() {
        XCTAssertEqual(ModelAdvisor.displayName(VideoCapabilityRegistry.wanT2VRecipeID), "Wan 2.1 T2V 1.3B")
        XCTAssertEqual(ModelAdvisor.displayName(MLXVideoModelCatalog.ltx23Q4RecipeID), "LTX-2.3 MLX Q4")
        XCTAssertEqual(ModelAdvisor.displayName(MediaModelCatalog.minimaxH3RecipeID + "-v-7c7e1618"), "MiniMax-H3 FL2VA (update copy)")
    }

    func testAnUnverifiedUpdateCopyNextToItsOriginalCannotBeUsed() throws {
        let h3 = try recipe(MediaModelCatalog.minimaxH3RecipeID)
        let copy = updateCopy(of: h3)
        let result = report([installed(h3), installed(copy)])
        let copyAdvice = try advice(copy.id, in: result)
        XCTAssertEqual(copyAdvice.status, .cannotRun)
        XCTAssertEqual(copyAdvice.name, "MiniMax-H3 FL2VA (update copy)")
        XCTAssertTrue(copyAdvice.reason.contains("update"), copyAdvice.reason)
        let original = try advice(h3.id, in: result)
        XCTAssertEqual(original.status, .keep, "Slow here, but kept as the final-quality video model")
    }

    func testModelsBelowTheBarAreNotNeededAndNameWhatReplacesThem() throws {
        let klein4B = try recipe(MediaModelCatalog.kleinRecipeID)
        let item = try advice(klein4B.id, in: report([installed(klein4B)]))
        XCTAssertEqual(item.status, .notNeeded)
        XCTAssertEqual(item.replacementRecipeID, MediaModelCatalog.klein9BRecipeID)
    }

    func testJuggernautIsKeptAsAPhotographicAlternativeNotFlaggedForRemoval() throws {
        let juggernaut = try recipe(MediaModelCatalog.juggernautXLRecipeID)
        let item = try advice(juggernaut.id, in: report([installed(juggernaut)]))
        XCTAssertEqual(item.status, .keep)
        XCTAssertEqual(ModelAdvisor.pickerNote(juggernaut.id), "")
    }

    func testTheRecommendedSetIsKept() throws {
        let ids = [MediaModelCatalog.klein9BRecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID, MLXVideoModelCatalog.fastMetal5BRecipeID,
                   MLXVLMModelCatalog.qwen38RecipeID, UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, SpeechModelCatalog.qwen3VoiceDesignRecipeID]
        let result = report(try ids.map { installed(try recipe($0)) })
        for id in ids { XCTAssertEqual(try advice(id, in: result).status, .keep, id) }
        XCTAssertEqual(result.reclaimableBytes, 0)
        XCTAssertTrue(result.toAdd.isEmpty, "Everything recommended is already installed")
    }

    func testMissingFilesMeanAModelCannotBeUsed() throws {
        let klein9B = try recipe(MediaModelCatalog.klein9BRecipeID)
        XCTAssertEqual(try advice(klein9B.id, in: report([installed(klein9B, available: false)])).status, .cannotRun)
    }

    func testAModelNeedingMoreMemoryThanThisMacHasCannotBeUsed() throws {
        let ltx = try recipe(MLXVideoModelCatalog.ltx23Q4RecipeID)
        let small = HardwareProfile(chip: "Apple M2", memoryBytes: 16 << 30, osVersion: "27.0", freeDiskBytes: 100 << 30)
        let item = try advice(ltx.id, in: report([installed(ltx)], hardware: small))
        XCTAssertEqual(item.status, .cannotRun)
        XCTAssertTrue(item.reason.contains("16 GB"), item.reason)
    }

    func testUsageAndThisMacsOwnRunTimesAreReported() throws {
        let h3 = try recipe(MediaModelCatalog.minimaxH3RecipeID)
        let nodes = (0..<3).map { StudioNode(kind: .startEndVideo, label: "Shot \($0)", position: .init(x: Double($0), y: 0), model: h3.id) }
        let project = WorkflowProject(name: "The Audition", nodes: nodes, edges: [])
        let started = Date(timeIntervalSince1970: 1_000_000)
        let runs = [1437.0, 1506, 1576].map { seconds in
            RunRecord(id: UUID(), snapshot: RunInputSnapshot(projectID: project.id, nodeID: nodes[0].id, prompt: "", model: h3.id, temperature: 0, maxTokens: 0),
                      status: .succeeded, queuedAt: started, startedAt: started, finishedAt: started.addingTimeInterval(seconds))
        }
        let item = try advice(h3.id, in: report([installed(h3)], projects: [project], runs: runs))
        XCTAssertEqual(item.usage.nodeCount, 3)
        XCTAssertEqual(item.usage.workflowNames, ["The Audition"])
        XCTAssertEqual(item.measured, "Your 3 runs here took a median of 25 min.")
    }

    func testOnlyModelsNotKeptCountTowardsReclaimableSpace() throws {
        let klein9B = try recipe(MediaModelCatalog.klein9BRecipeID), klein4B = try recipe(MediaModelCatalog.kleinRecipeID)
        let result = report([installed(klein9B), installed(klein4B)])
        XCTAssertEqual(result.reclaimableBytes, klein4B.totalBytes)
    }

    func testWorkflowNodesUsingModelsThatAreNotInstalledAreListed() throws {
        let nodes = (0..<2).map { StudioNode(kind: .imageDescriber, label: "Describe \($0)", position: .init(x: Double($0), y: 0), model: "vision-smolvlm-500m-q8") }
        let result = report([], projects: [WorkflowProject(name: "Big Chicken", nodes: nodes, edges: [])])
        let missing = try XCTUnwrap(result.missing.first)
        XCTAssertEqual(missing.modelID, "vision-smolvlm-500m-q8")
        XCTAssertEqual(missing.nodeCount, 2)
        XCTAssertEqual(missing.workflowNames, ["Big Chicken"])
    }

    func testRecommendedModelsThatAreNotInstalledAreOfferedToAdd() throws {
        let result = report([installed(try recipe(MediaModelCatalog.klein9BRecipeID))])
        let ids = Set(result.toAdd.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [MLXVideoModelCatalog.fastMetal5BRecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID, MLXVLMModelCatalog.qwen38RecipeID]))
        XCTAssertFalse(ids.contains(MediaModelCatalog.klein9BRecipeID))
        XCTAssertFalse(ids.contains(MediaModelCatalog.kleinRecipeID), "Never suggests a model below the bar")
    }

    @MainActor
    func testStartHereUsesTheSameRecommendedSet() {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: FileManager.default.temporaryDirectory.appending(path: "advisor-\(UUID())")))
        XCTAssertEqual(Set(store.starterRecipes.map(\.id)), ModelAdvisor.recommendedRecipeIDs)
    }
}

@MainActor
final class RecommendedForThisMacTests: XCTestCase {
    func testTheRecommendedListOnlyShowsModelsThisMacShouldHave() {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: FileManager.default.temporaryDirectory.appending(path: "recommended-\(UUID())")))
        store.hardware = .init(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "Version 27.0", freeDiskBytes: 800 << 30)
        let ids = Set(store.recommendedForThisMac.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [MediaModelCatalog.klein9BRecipeID, MLXVideoModelCatalog.fastMetal5BRecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID]), "\(ids)")
        for rejected in [MediaModelCatalog.kleinRecipeID, VideoCapabilityRegistry.wanT2VRecipeID,
                         ImageCapabilityRegistry.sd15RecipeID] {
            XCTAssertFalse(ids.contains(rejected), "\(rejected) does not meet this Mac's bar or is unassessed")
        }
        XCTAssertTrue(ids.contains(MediaModelCatalog.juggernautXLRecipeID), "Juggernaut is offered as a photographic alternative")
    }
}

final class PickerNoteTests: XCTestCase {
    func testBelowTheBarModelsAreLabelledInPickers() {
        XCTAssertEqual(ModelAdvisor.pickerNote(MediaModelCatalog.kleinRecipeID), " · not recommended here")
        XCTAssertEqual(ModelAdvisor.pickerNote(MediaModelCatalog.klein9BRecipeID), "")
        XCTAssertEqual(ModelAdvisor.pickerNote("unknown-model"), "", "Unassessed models are not mislabelled")
    }
}

final class WeeklyRadarCheckTests: XCTestCase {
    func testTheRadarChecksAgainOnceAWeek() {
        let now = Date()
        XCTAssertTrue(ModelRadarStore.needsAutomaticCheck(lastChecked: nil, now: now), "Never checked")
        XCTAssertFalse(ModelRadarStore.needsAutomaticCheck(lastChecked: now.addingTimeInterval(-6 * 86_400), now: now))
        XCTAssertTrue(ModelRadarStore.needsAutomaticCheck(lastChecked: now.addingTimeInterval(-7 * 86_400), now: now))
    }
}
