import XCTest
@testable import GenStudio

final class ModelPackageTests: XCTestCase {
    private let mac = HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "Version 26.0", freeDiskBytes: 500 << 30)
    private let sha = String(repeating: "c", count: 40)

    func testFluxLoRAIsNeverAStandaloneGenerator() {
        let detail = makeDetail(id: "studio/flux-style-lora", pipeline: "text-to-image",
            tags: ["lora", "diffusers", "base_model:adapter:black-forest-labs/FLUX.1-dev", "base_model:black-forest-labs/FLUX.1-dev"],
            files: [file("flux-style.safetensors", 687 << 20)])
        let guidance = ModelPackageGuidance.make(detail: detail)
        XCTAssertEqual(guidance.classification.kind, .lora)
        XCTAssertFalse(guidance.classification.isStandalone)
        XCTAssertEqual(guidance.classification.baseModels, ["black-forest-labs/FLUX.1-dev"])
        XCTAssertEqual(guidance.baseFamilies, [.flux1])
        XCTAssertTrue(guidance.references.isEmpty)
        XCTAssertTrue(guidance.nextAction.contains("no FLUX.1 base model"))
        XCTAssertEqual(guidance.recommendation, .unsupported)
        XCTAssertNil(guidance.baseRecipe)
        XCTAssertFalse(ModelCompatibility.assess(detail: detail, hardware: mac).eligible)
    }

    func testDiffusersLoRAFileWithDeclaredSD15BaseShowsTriggerWordsAndDeferredExecution() {
        var model = discovery(id: "studio/sd15-lora", pipeline: "text-to-image", tags: ["diffusers"])
        model.baseModels = ["stable-diffusion-v1-5/stable-diffusion-v1-5"]
        model.instancePrompts = ["sks watercolor", "<lora:other:1>", ""]
        let detail = makeDetail(model: model, files: [file("pytorch_lora_weights.safetensors", 134_621_556)])
        let guidance = ModelPackageGuidance.make(detail: detail, installedIDs: ["sd15-q4"])
        XCTAssertEqual(guidance.classification.kind, .lora)
        XCTAssertEqual(guidance.baseFamilies, [.sd15])
        XCTAssertEqual(guidance.classification.triggerWords, ["sks watercolor"], "Prompt-syntax and empty triggers are dropped")
        XCTAssertTrue(guidance.baseInstalled)
        XCTAssertEqual(guidance.recommendation, .keepForLater)
        XCTAssertTrue(guidance.nextAction.contains("You already have"))
        XCTAssertTrue(guidance.nextAction.contains("later version"))
    }

    func testLoRAWithoutDeclaredBaseIsNotGuessedFromName() {
        let detail = makeDetail(id: "studio/sdxl-flux-wan-lora", pipeline: "text-to-image", tags: ["lora"], files: [file("sdxl.safetensors", 100)])
        let guidance = ModelPackageGuidance.make(detail: detail)
        XCTAssertEqual(guidance.classification.kind, .lora)
        XCTAssertTrue(guidance.baseFamilies.isEmpty)
        XCTAssertTrue(guidance.nextAction.contains("will not guess"))
    }

    func testBaseModelMetadataRejectsNonRepositoryValues() {
        var model = discovery(id: "studio/adapter", pipeline: nil, tags: ["base_model:adapter:../../etc", "base_model:finetune:owner/good"])
        model.baseModels = ["https://evil.example/x", "owner/good", "OWNER/GOOD"]
        let result = ModelPackageClassification.classify(model: model, files: [])
        XCTAssertEqual(result.baseModels, ["owner/good"])
        XCTAssertEqual(result.baseRelations, [.adapter, .finetune])
        XCTAssertEqual(result.kind, .adapter)
    }

    func testControlNetAndComponentAndDiffusersAndUnknownPackages() {
        XCTAssertEqual(classify(tags: ["controlnet"], files: [file("diffusion_pytorch_model.safetensors", 10)]).title, "ControlNet adapter")
        XCTAssertEqual(classify(tags: [], files: [file("model_index.json", 1), file("unet/diffusion_pytorch_model.safetensors", 10)]).kind, .diffusersPipeline)
        XCTAssertEqual(classify(tags: [], files: [file("split_files/vae/a.safetensors", 10), file("split_files/text_encoders/b.safetensors", 10)]).kind, .components)
        XCTAssertEqual(classify(tags: [], files: [file("README.md", 10)]).kind, .unknown)
        XCTAssertEqual(classify(tags: [], files: [file("model-q4.gguf", 10)]).kind, .modelWeights)
    }

    func testComponentRepositoryPointsToTheExactRecipeThatUsesIt() throws {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.wan22TI2VRecipeID })
        let vae = try XCTUnwrap(recipe.components.first { $0.role == "vae" })
        let detail = makeDetail(model: discovery(id: vae.repository, sha: vae.revision, pipeline: nil, tags: []),
            files: [file(vae.filename, vae.byteSize, vae.sha256), file("split_files/text_encoders/other.safetensors", 5)])
        let guidance = ModelPackageGuidance.make(detail: detail)
        XCTAssertEqual(guidance.classification.kind, .components)
        let reference = try XCTUnwrap(guidance.references.first { $0.recipe.id == recipe.id })
        XCTAssertEqual(reference.roles, ["vae"])
        XCTAssertTrue(reference.matchesInspectedRevision)
        XCTAssertFalse(reference.completeFromRepository)
        XCTAssertTrue(guidance.nextAction.contains("downloads only its pinned files"))
        XCTAssertEqual(guidance.recommendation, .reviewRecipe)
        XCTAssertTrue(guidance.whereToUse.contains("place it yourself"))
        XCTAssertTrue(guidance.needs.contains("only works together"))

        let moved = makeDetail(model: discovery(id: vae.repository, sha: sha, pipeline: nil, tags: []), files: detail.files)
        XCTAssertFalse(try XCTUnwrap(ModelPackageGuidance.make(detail: moved).references.first { $0.recipe.id == recipe.id }).matchesInspectedRevision)
        XCTAssertTrue(ModelPackageGuidance.make(detail: moved).nextAction.contains("not necessarily this latest revision"))
    }

    func testSingleRepositoryVerifiedRecipePromotesCompleteCheckpoint() throws {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == ImageCapabilityRegistry.sd15RecipeID })
        let component = recipe.components[0]
        let detail = makeDetail(model: discovery(id: component.repository, sha: component.revision, pipeline: "text-to-image", tags: []),
            files: [file(component.filename, component.byteSize, component.sha256), file("other-Q8_0.gguf", 10)])
        let guidance = ModelPackageGuidance.make(detail: detail)
        XCTAssertEqual(guidance.classification.kind, .completeModel)
        XCTAssertTrue(guidance.references.contains { $0.completeFromRepository && $0.matchesInspectedRevision })
    }

    /// Adult labels are informational: they change neither package type nor capability admission.
    func testAdultLabelDoesNotAffectPackageTypeOrExactRecipeAdmission() throws {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == ImageCapabilityRegistry.sd15RecipeID })
        let component = recipe.components[0]
        let files = [file(component.filename, component.byteSize, component.sha256)]
        let general = makeDetail(model: discovery(id: component.repository, sha: component.revision, pipeline: "text-to-image", tags: []), files: files)
        let adult = makeDetail(model: discovery(id: component.repository, sha: component.revision, pipeline: "text-to-image", tags: ["not-for-all-audiences", "nsfw"]), files: files)
        XCTAssertTrue(adult.model.isAdultContent)
        XCTAssertEqual(ModelPackageGuidance.make(detail: adult).classification.kind, ModelPackageGuidance.make(detail: general).classification.kind)
        XCTAssertEqual(ModelPackageGuidance.make(detail: adult).recommendation, ModelPackageGuidance.make(detail: general).recommendation)
        XCTAssertEqual(ModelPackageGuidance.make(detail: adult).nextAction, ModelPackageGuidance.make(detail: general).nextAction)
        let generalAssessment = ModelCompatibility.assess(detail: general, hardware: mac)
        let adultAssessment = ModelCompatibility.assess(detail: adult, hardware: mac)
        XCTAssertTrue(adultAssessment.eligible)
        XCTAssertEqual(adultAssessment.state, generalAssessment.state)
        XCTAssertEqual(adultAssessment.recipeID, recipe.id)
        XCTAssertEqual(ModelDiscovery.assess(detail: adult, hardware: mac).exactRecipeIDs, [recipe.id])

        let text = makeDetail(model: discovery(id: "studio/text", sha: sha, pipeline: "text-generation", tags: ["not-for-all-audiences"]),
            files: [file("model-Q4_K_M.gguf", 100, String(repeating: "d", count: 64))])
        XCTAssertEqual(text.experimentalTextFiles.count, 1)
    }

    func testTextLoRAGGUFIsNotOfferedAsStandaloneTextModel() {
        let hash = String(repeating: "d", count: 64)
        let adapter = makeDetail(model: discovery(id: "studio/qwen-lora-gguf", sha: sha, pipeline: "text-generation", tags: ["gguf", "lora", "base_model:adapter:Qwen/Qwen2.5-0.5B-Instruct"]),
            files: [file("adapter-f16.gguf", 100, hash)])
        XCTAssertEqual(ModelPackageGuidance.make(detail: adapter).classification.kind, .lora)
        XCTAssertTrue(adapter.experimentalTextFiles.isEmpty)

        let quantizedFinetune = makeDetail(model: discovery(id: "studio/qwen-finetune-gguf", sha: sha, pipeline: "text-generation", tags: ["gguf", "lora", "base_model:quantized:studio/qwen-finetune"]),
            files: [file("model-Q4_K_M.gguf", 100, hash)])
        XCTAssertEqual(ModelPackageGuidance.make(detail: quantizedFinetune).classification.kind, .completeModel)
        XCTAssertEqual(quantizedFinetune.experimentalTextFiles.count, 1)
    }

    func testHubDetailParsesCardBaseModelAndInstancePrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try await ModelDiscovery(cacheRoot: root, transport: LoRAHubFixture()).detail(repository: "studio/lora")
        XCTAssertEqual(detail.model.baseModels, ["stabilityai/stable-diffusion-xl-base-1.0"])
        XCTAssertEqual(detail.model.instancePrompts, ["in the style of TOK"])
        let guidance = ModelPackageGuidance.make(detail: detail)
        XCTAssertEqual(guidance.classification.kind, .lora)
        XCTAssertEqual(guidance.baseFamilies, [.sdxl])
        let cached = try await ModelDiscovery(cacheRoot: root, transport: LoRAHubFixture()).detail(repository: "studio/lora", offline: true)
        XCTAssertEqual(cached.model.baseModels, detail.model.baseModels)
    }

    func testLoRAInvocationHidesSyntaxAndEnforcesBaseFamilyAndBounds() throws {
        let directory = URL(fileURLWithPath: "/tmp/run-loras")
        let a = selection("/lib/a.safetensors", weight: 0.8)
        let b = selection("/lib/b.safetensors", weight: 0.25)
        var off = selection("/lib/off.safetensors", weight: 1)
        off.isEnabled = false
        let plan = try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: "sd15-q4", selections: [a, off, b], directory: directory)
        XCTAssertEqual(plan.prompt, "a cat<lora:genstudio_lora_0:0.80><lora:genstudio_lora_1:0.25>")
        XCTAssertEqual(plan.applied.map(\.strength), [0.8, 0.25], "Switched-off add-ons are neither applied nor recorded")
        XCTAssertEqual(plan.applied.first?.filename, "weights/a.safetensors")
        XCTAssertEqual(plan.arguments, ["--lora-model-dir", "/tmp/run-loras"])
        XCTAssertEqual(plan.links.map(\.name), ["genstudio_lora_0.safetensors", "genstudio_lora_1.safetensors"])
        XCTAssertEqual(try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: "sd15-q4", selections: [off], directory: directory).arguments, [])
        XCTAssertThrowsError(try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: "sd15-q4", selections: [selection("/lib/n.safetensors", weight: -0.25)], directory: directory))

        XCTAssertThrowsError(try LoRAInvocation.plan(prompt: "a cat <LoRA:secret:1>", baseRecipeID: "sd15-q4", selections: [], directory: directory))
        XCTAssertThrowsError(try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: MediaModelCatalog.kleinRecipeID, selections: [a], directory: directory))
        XCTAssertThrowsError(try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: "sd15-q4", selections: [selection("/lib/a.safetensors", weight: .nan)], directory: directory))
        XCTAssertThrowsError(try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: "sd15-q4", selections: [selection("/lib/a.ckpt", weight: 1)], directory: directory))
        XCTAssertThrowsError(try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: "sd15-q4", selections: [a, a], directory: directory))
        let many = (0..<5).map { selection("/lib/\($0).safetensors", weight: 1) }
        XCTAssertThrowsError(try LoRAInvocation.plan(prompt: "a cat", baseRecipeID: "sd15-q4", selections: many, directory: directory))
        XCTAssertNil(LoRABaseFamily.sdxl.recipeID)
    }

    func testGatedDownloadErrorIsActionableWithoutCredentials() {
        let message = GenerationLibraryError.hub(status: 401, action: "Model download").localizedDescription
        XCTAssertTrue(message.contains("gated"))
        XCTAssertTrue(message.contains("does not send Hugging Face credentials"))
        XCTAssertTrue(GenerationLibraryError.hub(status: 404, action: "Model download").localizedDescription.contains("not found"))
    }

    // MARK: Live acceptance regression

    /// Metadata shape of Heartsync/Flux-NSFW-uncensored as returned by /api/models/…?blobs=true on 14 Sep 2026:
    /// finetune relation derived from base_model, no `lora` tag, and one root `lora.safetensors`.
    func testRootLoRAFilenameWithDerivedFinetuneRelationIsFluxAddOn() throws {
        func detail(adult: Bool) -> DiscoveryDetail {
            var tags = ["diffusers", "text-to-image", "base_model:finetune:black-forest-labs/FLUX.1-dev", "base_model:black-forest-labs/FLUX.1-dev", "license:other"]
            if adult { tags.append("not-for-all-audiences") }
            var model = discovery(id: "Heartsync/Flux-NSFW-uncensored", sha: sha, pipeline: "text-to-image", tags: tags)
            model.baseModels = ["black-forest-labs/FLUX.1-dev"]
            return makeDetail(model: model, files: [file(".gitattributes", 1_519), file("README.md", 2_000),
                file("lora.safetensors", 687_476_088, String(repeating: "a", count: 64))])
        }
        let labelled = detail(adult: true), unlabelled = detail(adult: false)
        let guidance = ModelPackageGuidance.make(detail: labelled)
        XCTAssertEqual(guidance.classification.kind, .lora)
        XCTAssertFalse(guidance.classification.isStandalone)
        XCTAssertEqual(guidance.classification.baseModels, ["black-forest-labs/FLUX.1-dev"])
        XCTAssertEqual(guidance.baseFamilies, [.flux1])
        XCTAssertTrue(guidance.whatItIs.contains("small add-on for an existing image model"))
        XCTAssertTrue(guidance.whatItIs.contains("not a model you can generate with on its own"))
        XCTAssertEqual(guidance.recommendation, .unsupported)
        XCTAssertTrue(guidance.nextAction.contains("no FLUX.1 base model"))
        XCTAssertNil(guidance.baseRecipe)
        XCTAssertTrue(guidance.references.isEmpty)
        XCTAssertFalse(ModelCompatibility.assess(detail: labelled, hardware: mac).eligible)

        XCTAssertTrue(labelled.model.isAdultContent)
        XCTAssertFalse(unlabelled.model.isAdultContent)
        let plain = ModelPackageGuidance.make(detail: unlabelled)
        XCTAssertEqual(plain.classification.kind, guidance.classification.kind)
        XCTAssertEqual(plain.recommendation, guidance.recommendation)
        XCTAssertEqual(plain.nextAction, guidance.nextAction)
        XCTAssertEqual(ModelCompatibility.assess(detail: unlabelled, hardware: mac).state, ModelCompatibility.assess(detail: labelled, hardware: mac).state)
    }

    func testRootLoRAFilenameRuleIsExactAndDoesNotReclassifyCheckpoints() {
        let flux = "base_model:finetune:black-forest-labs/FLUX.1-dev"
        XCTAssertEqual(classify(tags: [flux], files: [file("my-lora.safetensors", 10)]).kind, .modelWeights, "Substring matches are not a convention")
        XCTAssertEqual(classify(tags: [flux], files: [file("LoRA.safetensors", 10)]).kind, .modelWeights, "Hub paths are case-sensitive; only the exact name counts")
        XCTAssertEqual(classify(tags: [flux], files: [file("weights/lora.safetensors", 10)]).kind, .modelWeights, "Root file only")
        XCTAssertEqual(classify(tags: [flux], files: [file("lora.safetensors", 10), file("flux1-dev-finetune.safetensors", 10)]).kind, .modelWeights, "A checkpoint that also ships a LoRA is not reclassified")
        XCTAssertEqual(classify(tags: ["base_model:quantized:black-forest-labs/FLUX.1-dev"], files: [file("lora.safetensors", 10)]).kind, .modelWeights)
        XCTAssertEqual(classify(tags: ["base_model:merge:black-forest-labs/FLUX.1-dev"], files: [file("lora.safetensors", 10)]).kind, .modelWeights)
        XCTAssertEqual(classify(tags: [], files: [file("lora.safetensors", 10), file("README.md", 10)]).kind, .lora)
        XCTAssertEqual(classify(tags: ["lora", "base_model:quantized:owner/base"], files: [file("model-Q4_K_M.gguf", 10)]).kind, .modelWeights, "Incidental lora tag on a quantized release is still not a LoRA")
    }

    // MARK: Beginner guidance

    func testBeginnerGuidanceForLoRAAnswersAllFiveQuestions() throws {
        var model = discovery(id: "studio/watercolor", sha: sha, pipeline: "text-to-image", tags: ["lora", "style", "base_model:adapter:stable-diffusion-v1-5/stable-diffusion-v1-5"])
        model.instancePrompts = ["wtrclr"]
        let guidance = ModelPackageGuidance.make(detail: makeDetail(model: model, files: [file("watercolor.safetensors", 50 << 20)]))
        XCTAssertTrue(guidance.whatItIs.contains("small add-on for an existing image model"))
        XCTAssertEqual(guidance.classification.title, "LoRA adapter", "Technical label stays available as secondary text")
        XCTAssertEqual(guidance.benefits, ["Give results a consistent visual style"])
        XCTAssertTrue(guidance.benefitsNote.contains("depends on how the publisher trained it"))
        XCTAssertTrue(guidance.needs.contains("stable-diffusion-v1-5/stable-diffusion-v1-5"))
        XCTAssertTrue(guidance.needs.contains("not installed yet"))
        XCTAssertTrue(guidance.whereToUse.contains("Image Generator node"))
        XCTAssertTrue(guidance.whereToUse.contains("not available in this version"))
        XCTAssertEqual(guidance.recommendation, .keepForLater)
        XCTAssertEqual(guidance.baseRecipe?.id, ImageCapabilityRegistry.sd15RecipeID)
        XCTAssertFalse(guidance.baseInstalled)
        XCTAssertEqual(guidance.classification.triggerWords, ["wtrclr"])
        XCTAssertTrue(guidance.references.isEmpty, "A LoRA never gets an install button of its own")
    }

    func testBenefitsComeFromTagsNotRepositoryNames() {
        let guidance = ModelPackageGuidance.make(detail: makeDetail(id: "studio/photorealistic-product-character-style-camera-motion-lora", pipeline: "text-to-image", tags: ["lora"], files: [file("x.safetensors", 10)]))
        XCTAssertTrue(guidance.benefits.isEmpty)
        XCTAssertTrue(guidance.benefitsNote.contains("does not say what this add-on changes"))
        XCTAssertEqual(guidance.recommendation, .unknown)
        XCTAssertTrue(guidance.needs.contains("didn’t say which one"))
    }

    func testVideoLoRAPlacementAndAmbiguousBasesAreNotGuessed() {
        let video = ModelPackageGuidance.make(detail: makeDetail(id: "studio/wan-motion", pipeline: nil, tags: ["lora", "camera-motion", "base_model:adapter:Wan-AI/Wan2.1-T2V-1.3B"], files: [file("m.safetensors", 10)]))
        XCTAssertTrue(video.whereToUse.contains("Text to Video"))
        XCTAssertEqual(video.benefits, ["Add or control camera motion"])
        XCTAssertEqual(video.baseRecipe?.id, VideoCapabilityRegistry.wanT2VRecipeID)

        let ambiguous = ModelPackageGuidance.make(detail: makeDetail(id: "studio/two-bases", pipeline: "text-to-image",
            tags: ["lora", "base_model:adapter:stable-diffusion-v1-5/stable-diffusion-v1-5", "base_model:adapter:stabilityai/stable-diffusion-xl-base-1.0"], files: [file("m.safetensors", 10)]))
        XCTAssertNil(ambiguous.baseRecipe)
        XCTAssertEqual(ambiguous.recommendation, .unsupported)
        XCTAssertTrue(ambiguous.needs.contains("More than one base"))
    }

    func testCompleteModelAndGatedTextGuidance() throws {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == ImageCapabilityRegistry.sd15RecipeID })
        let component = recipe.components[0]
        let complete = ModelPackageGuidance.make(detail: makeDetail(model: discovery(id: component.repository, sha: component.revision, pipeline: "text-to-image", tags: []),
            files: [file(component.filename, component.byteSize, component.sha256)]))
        XCTAssertEqual(complete.recommendation, .reviewRecipe)
        XCTAssertTrue(complete.needs.contains("Works on its own"))
        XCTAssertTrue(complete.whereToUse.contains("Image Generator node"))
        XCTAssertTrue(complete.benefits.contains("Create images from a written prompt"))
        XCTAssertTrue(complete.benefits.contains("Change or edit a connected reference image"))

        let gatedModel = DiscoveryModel(id: "studio/gated", sha: sha, pipelineTag: "text-generation", library: nil, license: nil, gated: true, downloads: nil, likes: nil, createdAt: nil, lastModified: nil, tags: [])
        let gated = ModelPackageGuidance.make(detail: makeDetail(model: gatedModel, files: [file("m-Q4_K_M.gguf", 100, String(repeating: "d", count: 64))]))
        XCTAssertEqual(gated.recommendation, .unsupported)
        XCTAssertTrue(gated.whereToUse.contains("Local Text node"))
    }

    func testFutureLoRAControlPolicy() {
        XCTAssertEqual(LoRAControlPolicy.defaultStrength, 1.0)
        XCTAssertTrue(LoRAControlPolicy.strengthIsAdvanced)
        XCTAssertTrue(LoRAControlPolicy.multipleAddOnsAreAdvanced)
        XCTAssertEqual(LoRAControlPolicy.strengthDescription(0.5), "Subtler")
        XCTAssertEqual(LoRAControlPolicy.strengthDescription(1.0), "As trained")
        XCTAssertEqual(LoRAControlPolicy.strengthDescription(1.5), "Stronger")
        XCTAssertEqual(LoRAControlPolicy.baseChoice(for: .sd15, installedRecipeIDs: ["sd15-q4", "qwen25-05b-q4km"]), .preselect(recipeID: "sd15-q4"))
        XCTAssertEqual(LoRAControlPolicy.baseChoice(for: .sd15, installedRecipeIDs: []), .installBase(recipeID: "sd15-q4"))
        if case .unavailable = LoRAControlPolicy.baseChoice(for: .sdxl, installedRecipeIDs: ["sd15-q4"]) {} else { XCTFail("SDXL add-ons must not fall back to SD 1.5") }
        if case .unavailable = LoRAControlPolicy.baseChoice(for: nil, installedRecipeIDs: ["sd15-q4"]) {} else { XCTFail("Undeclared bases are never guessed") }
        XCTAssertNil(LoRAControlPolicy.incompatibility(of: .sd15, withRecipeID: "sd15-q4"))
        let refusal = try? XCTUnwrap(LoRAControlPolicy.incompatibility(of: .sd15, withRecipeID: MediaModelCatalog.kleinRecipeID))
        XCTAssertTrue(refusal?.contains("made for Stable Diffusion 1.5") == true)
        XCTAssertTrue(refusal?.contains("switch the add-on off") == true)
    }

    private func selection(_ path: String, weight: Double) -> LoRASelection {
        LoRASelection(file: URL(fileURLWithPath: path), baseFamily: .sd15, weight: weight, repository: "studio/lora", revision: sha, filename: "weights/" + URL(fileURLWithPath: path).lastPathComponent, sha256: String(repeating: "a", count: 64))
    }
    private func classify(tags: [String], files: [DiscoveryFile]) -> ModelPackageClassification {
        ModelPackageClassification.classify(model: discovery(id: "studio/x", pipeline: "text-to-image", tags: tags), files: files)
    }
    private func discovery(id: String, sha: String? = nil, pipeline: String?, tags: [String]) -> DiscoveryModel {
        DiscoveryModel(id: id, sha: sha, pipelineTag: pipeline, library: nil, license: nil, gated: false, downloads: nil, likes: nil, createdAt: nil, lastModified: nil, tags: tags)
    }
    private func makeDetail(id: String, pipeline: String?, tags: [String], files: [DiscoveryFile]) -> DiscoveryDetail {
        makeDetail(model: discovery(id: id, sha: sha, pipeline: pipeline, tags: tags), files: files)
    }
    private func makeDetail(model: DiscoveryModel, files: [DiscoveryFile]) -> DiscoveryDetail {
        DiscoveryDetail(model: model, files: files, architectures: [], modelType: nil, contextLength: nil, requiresCustomCode: false, configNote: nil, ggufArchitectureHint: nil, fetchedAt: Date(), isCached: false)
    }
    private func file(_ path: String, _ bytes: Int64, _ sha256: String? = nil) -> DiscoveryFile {
        DiscoveryFile(path: path, bytes: bytes, sha256: sha256)
    }
}

private struct LoRAHubFixture: DiscoveryTransport {
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        let json: [String: Any] = [
            "id": "studio/lora", "sha": String(repeating: "e", count: 40), "pipeline_tag": "text-to-image",
            "tags": ["diffusers", "lora", "template:sd-lora"],
            "cardData": ["license": "openrail++", "base_model": "stabilityai/stable-diffusion-xl-base-1.0", "instance_prompt": "in the style of TOK"],
            "siblings": [["rfilename": "pytorch_lora_weights.safetensors", "size": 23_000_000, "lfs": ["sha256": String(repeating: "f", count: 64)]]]
        ]
        return .init(data: try JSONSerialization.data(withJSONObject: json), nextLink: nil)
    }
}
