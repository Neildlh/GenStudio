import XCTest
@testable import GenStudio

/// Two tiers: fast models for drafts and checks, and "final quality" models that are slower here but
/// make better output for the same job. A slow model earns the final tier only with evidence that it beats
/// the fast model it is compared with; otherwise it stays rejected. The tier is shown before a model is picked.
final class FinalQualityTierTests: XCTestCase {
    private let h3 = MediaModelCatalog.minimaxH3RecipeID

    func testMiniMaxH3IsTheFinalQualityVideoModelAndNamesItsDraftModel() throws {
        let verdict = try XCTUnwrap(MacFitStandard.finalQuality(recipeID: h3))
        XCTAssertEqual(verdict.status, .finalQuality)
        XCTAssertEqual(verdict.draftWith, MLXVideoModelCatalog.ltx23Q4RecipeID)
        XCTAssertTrue(try XCTUnwrap(verdict.wait).contains("min"))
    }

    func testFastModelsAreNotFinalQuality() {
        for id in [MediaModelCatalog.klein9BRecipeID, MLXVideoModelCatalog.ltx23Q4RecipeID, MLXVideoModelCatalog.fastMetal5BRecipeID, "unknown"] {
            XCTAssertNil(MacFitStandard.finalQuality(recipeID: id), id)
        }
    }

    func testEveryFinalQualityVerdictCarriesItsWaitAndAFastDraftModel() throws {
        let finals = MacFitStandard.verdicts.filter { $0.status == .finalQuality }
        XCTAssertFalse(finals.isEmpty)
        for verdict in finals {
            XCTAssertTrue(verdict.subject.hasPrefix("recipe:"), "\(verdict.subject): only a runnable route can be a final-quality pick")
            XCTAssertFalse(verdict.sources.isEmpty, verdict.subject)
            XCTAssertFalse((verdict.wait ?? "").isEmpty, "\(verdict.subject) must say how long it takes")
            XCTAssertFalse((verdict.outranksDraft ?? "").isEmpty, "\(verdict.subject) must record why it beats its draft model")
            let draft = try XCTUnwrap(verdict.draftWith, verdict.subject)
            let draftVerdict = try XCTUnwrap(MacFitStandard.verdict(forSubject: "recipe:\(draft)"), draft)
            XCTAssertTrue([.meets, .expectedToMeet].contains(draftVerdict.status), "\(verdict.subject): its draft model must be a fast one")
        }
    }

    func testPickersLabelFinalQualityModelsWithTheirWait() {
        let note = ModelAdvisor.pickerNote(h3)
        XCTAssertTrue(note.contains("Final quality"), note)
        XCTAssertTrue(note.contains("min"), note)
        XCTAssertFalse(note.contains("not recommended"), note)
        XCTAssertEqual(ModelAdvisor.pickerNote(MLXVideoModelCatalog.ltx23Q4RecipeID), "", "Fast models carry no badge")
    }

    func testTheBadgeTextIsReadableWithoutColour() throws {
        let text = try XCTUnwrap(FinalQualityBadge.text(recipeID: h3))
        XCTAssertTrue(text.hasPrefix("Final quality"), text)
        XCTAssertNil(FinalQualityBadge.text(recipeID: MediaModelCatalog.klein9BRecipeID))
    }

    func testTheAdvisorKeepsAnInstalledFinalQualityModel() throws {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == h3 })
        let installed = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
                                                 components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/tmp/\($0.id)"), source: $0) },
                                                 installedAt: Date(), inferenceVerified: true, available: true, recipeSnapshot: recipe)
        let report = ModelAdvisor.report(installed: [installed], hardware: .init(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "27.0", freeDiskBytes: 800 << 30), projects: [], runs: [])
        let advice = try XCTUnwrap(report.advice.first { $0.id == h3 })
        XCTAssertEqual(advice.status, .keep)
        XCTAssertTrue(advice.reason.contains("Final quality"), advice.reason)
    }

    func testRunAllSaysWhenFinalQualityNodesWillMakeItWait() {
        let slow = StudioNode(kind: .textToVideo, label: "Hero shot", position: .init(x: 0, y: 0), model: h3)
        let fast = StudioNode(kind: .textToVideo, label: "Draft", position: .init(x: 400, y: 0), model: MLXVideoModelCatalog.ltx23Q4RecipeID)
        let project = WorkflowProject(name: "Ad", nodes: [slow, fast], edges: [])
        let plan = RunPlan.make(project: project, targets: [slow.id, fast.id])
        XCTAssertEqual(plan.finalQualityNodes, ["Hero shot"])
        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertTrue(plan.summary.contains("Hero shot"), plan.summary)
        XCTAssertTrue(plan.summary.contains("final-quality"), plan.summary)
        XCTAssertTrue(RunPlan.make(project: WorkflowProject(name: "Draft", nodes: [fast], edges: []), target: fast.id).finalQualityNodes.isEmpty)
    }

    func testSwitchingFromDraftToFinalModelKeepsTheNegativePrompt() {
        var draft = VideoCapabilityRegistry.ltx23TextToVideo.recommended
        draft.negativePrompt = "text, watermark, extra fingers"
        draft.seed = 1234
        let final = VideoCapabilityRegistry.minimaxH3TextToVideo.recommendedSettings(preservingDurationFrom: draft)
        XCTAssertEqual(final.negativePrompt, "text, watermark, extra fingers")
        XCTAssertEqual(final.seed, 1234)
    }
}
