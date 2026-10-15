import XCTest
@testable import GenStudio

final class PromptCompilerTests: XCTestCase {
    func testPreservedSheetBriefStillEnforcesPromptSafetyLimits() async throws {
        let contract = PromptCompilerContract(recipeID: "sheet-test", task: .image(.imageToImage), dialect: .template,
                                              maximumBytes: 32, semanticExpansion: true)
        let text = "  Same subject.\n"
        let result = try await PromptCompiler.compile(authoredPrompt: text, recipeID: "sheet-test", task: .image(.imageToImage),
                                                       contract: contract, preserveAuthoredText: true)
        XCTAssertEqual(result.compiledPrompt, text)
        XCTAssertFalse(result.usedFallback)
        for invalid in ["   ", "<lora:unwanted>", String(repeating: "a", count: 33)] {
            do {
                _ = try await PromptCompiler.compile(authoredPrompt: invalid, recipeID: "sheet-test", task: .image(.imageToImage),
                                                     contract: contract, preserveAuthoredText: true)
                XCTFail("Preserving authored text must not bypass validation")
            } catch {
                XCTAssertTrue(error is StudioError)
            }
        }
    }

    func testSelectingDifferentImageRecipesChangesCompilationContract() async throws {
        let authored = "a red apple on a dark wooden table"
        let sd = try await PromptCompiler.compile(authoredPrompt: authored, recipeID: ImageCapabilityRegistry.sd15RecipeID,
                                                   task: .image(.textToImage))
        let klein = try await PromptCompiler.compile(authoredPrompt: authored, recipeID: MediaModelCatalog.kleinRecipeID,
                                                     task: .image(.textToImage))

        XCTAssertEqual(sd.compiledPrompt, authored)
        XCTAssertNotEqual(sd.compiledPrompt, klein.compiledPrompt)
        XCTAssertEqual(sd.dialect, .plainText)
        XCTAssertEqual(klein.dialect, .template)
        XCTAssertTrue(klein.usedFallback)
    }

    func testKlein9BImageToImageHasItsOwnPromptContract() async throws {
        let result = try await PromptCompiler.compile(
            authoredPrompt: "turn the jacket blue",
            recipeID: MediaModelCatalog.klein9BRecipeID,
            task: .image(.imageToImage)
        )

        XCTAssertEqual(result.recipeID, MediaModelCatalog.klein9BRecipeID)
        XCTAssertEqual(result.task, .image(.imageToImage))
        XCTAssertEqual(result.dialect, .template)
        XCTAssertEqual(result.compilerVersion, PromptCompilerRegistry.version)
        XCTAssertTrue(result.compiledPrompt.contains("turn the jacket blue"))
        XCTAssertTrue(result.usedFallback)
    }

    func testGenericCheckpointContractComesFromItsAdapterProfile() async throws {
        let authored = "cinematic portrait in window light"
        let result = try await PromptCompiler.compile(
            authoredPrompt: authored,
            recipeID: MediaModelCatalog.juggernautXLRecipeID,
            task: .image(.textToImage)
        )

        XCTAssertEqual(result.compiledPrompt, authored)
        XCTAssertEqual(result.dialect, .plainText)
        XCTAssertFalse(result.usedFallback)
    }

    func testImportedCheckpointGetsContractFromValidatedRuntimeMetadata() async throws {
        let recipe = try UserModelCatalog.recipe(from: .init(
            name: "Imported checkpoint", provider: "test", modelVersionID: nil,
            downloadURL: URL(string: "https://example.com/model.safetensors")!, filename: "model.safetensors",
            sha256: String(repeating: "a", count: 64), byteSize: 1_000_000, license: "test", baseModel: nil,
            runtimeProfile: .stableDiffusionCheckpoint, tasks: [.textToImage]
        ))
        let contract = try XCTUnwrap(PromptCompilerRegistry.contract(recipe: recipe, task: .image(.textToImage)))
        let result = try await PromptCompiler.compile(
            authoredPrompt: "a red kite", recipeID: recipe.id, task: .image(.textToImage), contract: contract
        )

        XCTAssertEqual(result.compiledPrompt, "a red kite")
        XCTAssertEqual(result.recipeID, recipe.id)
        XCTAssertEqual(result.dialect, .plainText)
        XCTAssertNil(PromptCompilerRegistry.contract(recipe: recipe, task: .vision))
    }

    func testInstalledMultimodalProfileSuppliesContractsForBothDeclaredNodeKinds() throws {
        let recipe = ModelRecipe(
            id: "mlx-vlm-test", name: "MLX VLM", kind: .vision, engineID: "mlx-vlm", components: [],
            runtimeReady: false, minimumMemoryBytes: 1, runtimeProfile: "mlx-vlm",
            workflowCapabilities: [.textGeneration, .imageUnderstanding]
        )

        XCTAssertEqual(PromptCompilerRegistry.contract(recipe: recipe, task: .text)?.dialect, .plainText)
        XCTAssertEqual(PromptCompilerRegistry.contract(recipe: recipe, task: .vision)?.dialect, .plainText)
        XCTAssertNil(PromptCompilerRegistry.contract(recipe: recipe, task: .image(.textToImage)))
    }

    func testAdmittedGGUFTextProfileSuppliesPlainTextContract() throws {
        let recipe = ModelRecipe(
            id: "text-gguf-test", name: "GGUF", kind: .text, engineID: "llama.cpp", components: [],
            runtimeReady: false, minimumMemoryBytes: 1
        )

        XCTAssertEqual(PromptCompilerRegistry.contract(recipe: recipe, task: .text)?.dialect, .plainText)
        XCTAssertNil(PromptCompilerRegistry.contract(recipe: recipe, task: .vision))
    }

    func testInstalledLocalCompilerModelIsUsedOnlyForRecipesThatRequestExpansion() async throws {
        let engine = StubEngine(result: "expanded apple description")
        let result = try await PromptCompiler.compile(authoredPrompt: "an apple", recipeID: MediaModelCatalog.kleinRecipeID,
                                                      task: .image(.textToImage), installedCompilerModelIDs: [PromptCompilerRegistry.defaultCompilerModelID],
                                                      textEngine: engine)

        XCTAssertEqual(result.compiledPrompt, "expanded apple description")
        XCTAssertEqual(result.compilerModelID, PromptCompilerRegistry.defaultCompilerModelID)
        XCTAssertFalse(result.usedFallback)
        let prompts = await engine.capturedPrompts()
        XCTAssertEqual(prompts.count, 1)
    }

    func testValidStructuredInputPassesThroughUnchanged() async throws {
        let input = #"{"caption":{"comprehensive_description":"a quiet room","camera_info":{},"world_knowledge":[],"prominent_elements":[]}}"#
        let result = try await PromptCompiler.compile(authoredPrompt: input, recipeID: MediaModelCatalog.lingBotRecipeID,
                                                      task: .video(.imageToVideo))
        XCTAssertEqual(result.compiledPrompt, input)
        XCTAssertFalse(result.usedFallback)
        XCTAssertNil(result.compilerModelID)
        XCTAssertEqual(result.dialect, .structuredJSON)
    }

    func testUnsupportedRecipeAndTaskFailWithoutBorrowingSyntax() async {
        do {
            _ = try await PromptCompiler.compile(authoredPrompt: "a cat", recipeID: ImageCapabilityRegistry.sd15RecipeID, task: .vision)
            XCTFail("An image recipe must not receive a vision prompt contract")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No prompt compiler contract"))
            XCTAssertTrue(error.localizedDescription.contains("will not apply another recipe's prompt syntax"))
        }
    }

    func testForbiddenTokensAreRejectedBeforeAdapterUse() async {
        do {
            _ = try await PromptCompiler.compile(authoredPrompt: "a cat <lora:style:1>", recipeID: ImageCapabilityRegistry.sd15RecipeID,
                                                  task: .image(.textToImage))
            XCTFail("Forbidden engine tokens must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("forbidden token"))
        }
    }
}
