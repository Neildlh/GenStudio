import CoreGraphics
import CryptoKit
import ImageIO
import XCTest
@testable import GenStudio

/// Recipe truthfulness, task gating, command construction and fit for the image/video model expansion.
final class ModelExpansionCatalogTests: XCTestCase {
    private var repositoryRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    private struct HubEvidence: Decodable {
        struct File: Decodable { let path: String; let size: Int64?; let sha256: String? }
        let repo: String; let sha: String?; let gated: GatedValue?; let files: [File]
    }
    /// The Hub API returns `false` or a string such as "auto" for gated repositories.
    private enum GatedValue: Decodable {
        case open, gated(String)
        init(from decoder: Decoder) throws {
            if let flag = try? Bool(from: decoder) { self = flag ? .gated("true") : .open } else { self = .gated(try String(from: decoder)) }
        }
    }

    func testEveryPinnedMediaComponentMatchesRetainedHubEvidenceExactly() throws {
        let media = ModelCatalog.recipes.filter { $0.kind == .image || $0.kind == .video }
        XCTAssertTrue(media.contains { $0.id == MediaModelCatalog.animateDiffRecipeID })
        for recipe in media {
            for component in recipe.components {
                let url = repositoryRoot.appending(path: "docs/research/model-expansion/evidence/hub/\(component.repository.replacingOccurrences(of: "/", with: "__")).json")
                let evidence = try JSONDecoder().decode(HubEvidence.self, from: Data(contentsOf: url))
                XCTAssertEqual(evidence.repo, component.repository)
                XCTAssertEqual(evidence.sha, component.revision, "\(recipe.id)/\(component.id) revision must be the retained commit")
                if case .gated = evidence.gated { XCTFail("\(component.repository) is gated; GenStudio does not collect credentials") }
                let sourceFilename = component.sourceFilename ?? component.filename
                let file = try XCTUnwrap(evidence.files.first { $0.path == sourceFilename }, "\(sourceFilename) missing from evidence")
                XCTAssertEqual(file.size, component.byteSize, "\(recipe.id)/\(component.id) size")
                XCTAssertEqual(file.sha256, component.sha256, "\(recipe.id)/\(component.id) SHA-256")
                XCTAssertFalse(component.license.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    func testSharedComponentsAreIdenticalContentAcrossRecipes() throws {
        func component(_ recipe: String, _ id: String) throws -> ModelComponent { try XCTUnwrap(ModelCatalog.recipes.first { $0.id == recipe }?.components.first { $0.id == id }) }
        XCTAssertEqual(try component(MediaModelCatalog.animateDiffRecipeID, "checkpoint"), try component("sd15-q4", "checkpoint"))
        XCTAssertEqual(try component(MediaModelCatalog.lingBotRecipeID, "vae"), try component(VideoCapabilityRegistry.wanT2VRecipeID, "vae"))
        XCTAssertEqual(try component(MediaModelCatalog.wan22TI2VRecipeID, "textEncoder"), try component(VideoCapabilityRegistry.wanT2VRecipeID, "textEncoder"))
        XCTAssertNotEqual(try component(MediaModelCatalog.wan22TI2VRecipeID, "vae").sha256, try component(VideoCapabilityRegistry.wanT2VRecipeID, "vae").sha256, "Wan 2.2 needs its own VAE")
    }

    func testEveryCapabilityPointsAtAPinnedRecipeWithItsCommandRolesAndBuild() throws {
        for capability in ImageCapabilityRegistry.shipped {
            // The ChatGPT subscription route is a cloud passthrough, not a downloadable
            // local recipe: it has no ModelCatalog entry and no local engineBuild to
            // pin, by design. See ChatGPTSubscriptionImageEngine.
            guard capability.engineID != ChatGPTSubscriptionImageEngine.engineID else { continue }
            let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == capability.recipeID })
            XCTAssertEqual(recipe.kind, .image)
            XCTAssertTrue(Set(capability.command.componentRoles).isSubset(of: Set(recipe.components.map(\.role))), capability.id)
            XCTAssertEqual(capability.engineBuild, VideoCapabilityRegistry.sdCppBuild)
        }
        for capability in VideoCapabilityRegistry.shipped {
            let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == capability.recipeID })
            XCTAssertEqual(recipe.kind, .video)
            XCTAssertTrue(Set(capability.command.componentRoles).isSubset(of: Set(recipe.components.map(\.role))), capability.id)
            let expectedBuild = switch capability.engineID {
            case "mlx-fastvideo": MLXVideoModelCatalog.fastVideoBuild
            case "mlx-ltx": MLXVideoModelCatalog.ltxBuild
            default: VideoCapabilityRegistry.sdCppBuild
            }
            XCTAssertEqual(capability.engineBuild, expectedBuild)
            XCTAssertTrue(capability.frames.contains(capability.recommended.frameCount) && capability.width.contains(capability.recommended.width) && capability.height.contains(capability.recommended.height) && capability.steps.contains(capability.recommended.steps) && capability.fps.contains(capability.recommended.fps), "\(capability.id) recommended settings must be valid")
        }
    }

    func testFastMetalIsAnExactT2VOnlyMLXPackageAndNotProductionSearchProof() throws {
        let recipe = MLXVideoModelCatalog.fastMetal5B
        XCTAssertEqual(recipe.engineID, "mlx-fastvideo")
        XCTAssertEqual(recipe.runtimeProfile, "mlx-fastvideo")
        XCTAssertEqual(recipe.components.count, 15)
        XCTAssertEqual(Set(recipe.components.map(\.repository)), ["FastVideo/FastMetal-5B-QAD"])
        XCTAssertEqual(Set(recipe.components.map(\.revision)).count, 1)
        XCTAssertNotNil(VideoCapabilityRegistry.capability(recipeID: recipe.id, task: .textToVideo))
        XCTAssertNil(VideoCapabilityRegistry.capability(recipeID: recipe.id, task: .imageToVideo))
        XCTAssertFalse(VideoCapabilityRegistry.supportsRecipe(recipe.id), "A packaged engine is not a decoded model proof")
        XCTAssertTrue(VideoCapabilityRegistry.hasUsableAdapter(recipe.id), "The exact package can be evaluated through the app graph")
    }

    func testLTXIsACompleteT2VAndI2VEvaluationRecipe() {
        let recipe = MLXVideoModelCatalog.ltx23Q4
        XCTAssertEqual(recipe.engineID, "mlx-ltx")
        XCTAssertEqual(recipe.runtimeProfile, "mlx-ltx")
        XCTAssertEqual(recipe.components.count, 24, "22 video files plus the two sound-decoder files")
        XCTAssertEqual(Set(recipe.components.map(\.repository)), ["dgrauet/ltx-2.3-mlx-q4", "mlx-community/gemma-3-12b-it-4bit"])
        XCTAssertTrue(recipe.components.contains { $0.filename == "gemma/tokenizer.model" && $0.sourceFilename == "tokenizer.model" })
        XCTAssertNotNil(VideoCapabilityRegistry.capability(recipeID: recipe.id, task: .textToVideo))
        XCTAssertNotNil(VideoCapabilityRegistry.capability(recipeID: recipe.id, task: .imageToVideo))
        XCTAssertFalse(VideoCapabilityRegistry.supportsRecipe(recipe.id), "A packaged native adapter is not a decoded model proof")
        XCTAssertTrue(VideoCapabilityRegistry.hasUsableAdapter(recipe.id))
        XCTAssertNil(VideoCapabilityRegistry.capability(recipeID: MLXVideoModelCatalog.fastMetal5BRecipeID, task: .imageToVideo))
    }

    func testKlein9BIsClearlyRestrictedWhileKlein4BRemainsCommercialOption() throws {
        let klein9B = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.klein9BRecipeID })
        let klein4B = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID })
        let nineBDiffusion = try XCTUnwrap(klein9B.components.first { $0.role == "diffusion" })
        let fourBDiffusion = try XCTUnwrap(klein4B.components.first { $0.role == "diffusion" })
        XCTAssertTrue(nineBDiffusion.license.localizedCaseInsensitiveContains("non-commercial"))
        XCTAssertTrue(fourBDiffusion.license.localizedCaseInsensitiveContains("apache"))
        XCTAssertFalse(nineBDiffusion.license.localizedCaseInsensitiveContains("apache"))
    }

    func testImageNodePickerOnlyOffersInstalledAvailableModelsForItsTask() {
        let sd = FitFixtures.installed(ImageCapabilityRegistry.sd15RecipeID)
        let klein = FitFixtures.installed(MediaModelCatalog.kleinRecipeID)
        let missingKlein = FitFixtures.installed(MediaModelCatalog.kleinRecipeID, available: false)

        XCTAssertEqual(
            ImageCapabilityRegistry.selectableCapabilities(task: .textToImage, referenceCount: 0, installed: [sd]).map(\.recipeID),
            [ImageCapabilityRegistry.sd15RecipeID]
        )
        XCTAssertEqual(
            ImageCapabilityRegistry.selectableCapabilities(task: .textToImage, referenceCount: 0, installed: [sd, missingKlein]).map(\.recipeID),
            [ImageCapabilityRegistry.sd15RecipeID]
        )
        XCTAssertEqual(
            ImageCapabilityRegistry.selectableCapabilities(task: .imageToImage, referenceCount: 2, installed: [sd, klein]).map(\.recipeID),
            [MediaModelCatalog.kleinRecipeID]
        )
        XCTAssertTrue(ImageCapabilityRegistry.selectableCapabilities(task: .textToImage, referenceCount: 0, installed: []).isEmpty)
    }

    func testNewAdaptersAreNotVerifiedWithoutLocalRenderEvidence() {
        // FLUX.2 Klein (MediaModelCatalog.kleinRecipeID) is excluded: both its capabilities now carry
        // a decoded local proof (docs/research/model-expansion/evidence/proofs/flux2-klein-reference),
        // checked below like every other verified capability.
        let unproven = [MediaModelCatalog.animateDiffRecipeID, MediaModelCatalog.lingBotRecipeID, MediaModelCatalog.wan22TI2VRecipeID]
        for id in unproven {
            XCTAssertFalse(VideoCapabilityRegistry.supportsRecipe(id) || ImageCapabilityRegistry.supportsRecipe(id), "\(id) has no decoded GenStudio render")
        }
        for capability in ImageCapabilityRegistry.shipped where capability.readiness.proven {
            guard case .verified(let evidence) = capability.readiness else { continue }
            XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot.appending(path: evidence).path), "Verified evidence must exist: \(evidence)")
        }
        for capability in VideoCapabilityRegistry.shipped where capability.readiness.proven {
            guard case .verified(let evidence) = capability.readiness else { continue }
            XCTAssertTrue(FileManager.default.fileExists(atPath: repositoryRoot.appending(path: evidence).path), "Verified evidence must exist: \(evidence)")
        }
    }

    func testCandidatesAndAdapterlessManifestsCannotInstall() async throws {
        let ids = Set(ModelCatalog.recipes.map(\.id))
        XCTAssertTrue(ModelCandidateCatalog.candidates.allSatisfy { !ids.contains($0.id) && !$0.blockers.isEmpty })
        XCTAssertTrue(ModelCandidateCatalog.candidates.allSatisfy { !$0.repositoryIDs.isEmpty })
        let ltx = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.ltx23RecipeID })
        let fit = RecipeFit.assess(recipe: ltx, hardware: FitFixtures.m1Max(), installed: [])
        XCTAssertEqual(fit.state, .adapterNeeded); XCTAssertFalse(fit.canInstall)
        let root = FileManager.default.temporaryDirectory.appending(path: "ltx-guard-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: root, diskAvailable: { _ in Int64.max })
        do { _ = try await library.install(recipe: ltx); XCTFail("No adapter, no install") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no adapter"), error.localizedDescription) }
        let registered = try await library.installedModels(); XCTAssertTrue(registered.isEmpty)
    }

    func testMiniMaxIsInstallableAndNotAlsoShownAsAnUnimplementedCandidate() throws {
        XCTAssertNil(ModelCandidateCatalog.candidate(forRepository: "leejet/MiniMax-H3-GGUF"))
        XCTAssertNil(ModelCandidateCatalog.candidate(forRepository: "COMFY-ORG/MINIMAX-H3"))
        let recipeIDs = Set(ModelCatalog.recipes.map(\.id))
        XCTAssertTrue(recipeIDs.contains(MediaModelCatalog.minimaxH3RecipeID))
        XCTAssertTrue(recipeIDs.contains(MediaModelCatalog.minimaxH3Ref2VARecipeID))
        XCTAssertNotNil(VideoCapabilityRegistry.capability(recipeID: MediaModelCatalog.minimaxH3RecipeID, task: .imageToVideo))
        XCTAssertNotNil(VideoCapabilityRegistry.capability(recipeID: MediaModelCatalog.minimaxH3Ref2VARecipeID, task: .videoToVideo))
    }

    func testReferencedMultiRepositoryRecipeKeepsCompleteRouteTotalSeparateFromRepositoryFiles() throws {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.lingBotRecipeID })
        let own = try XCTUnwrap(recipe.components.first { $0.repository == "robbyant/lingbot-video-dense-1.3b" })
        XCTAssertGreaterThan(recipe.totalBytes, own.byteSize)
        let model = DiscoveryModel(id: own.repository, sha: own.revision, pipelineTag: "text-to-video", library: nil,
            license: "Apache-2.0", gated: false, downloads: nil, likes: nil, createdAt: nil, lastModified: nil, tags: ["text-to-video"])
        let detail = DiscoveryDetail(model: model, files: [.init(path: own.filename, bytes: own.byteSize, sha256: own.sha256)],
            architectures: [], modelType: nil, contextLength: nil, requiresCustomCode: false, configNote: nil,
            ggufArchitectureHint: nil, fetchedAt: Date(), isCached: false)
        let reference = try XCTUnwrap(RecipeRepositoryReference.references(detail: detail).first { $0.id == recipe.id })
        XCTAssertTrue(reference.matchesInspectedRevision)
        XCTAssertFalse(reference.completeFromRepository)
        let inventory = ModelSizeSummary.summarize(repository: own.repository, revision: own.revision, files: detail.files)
        XCTAssertNotEqual(inventory.label, "Download", "One repository's files must not be presented as the full route")
        let plan = try XCTUnwrap(StoragePlan.make(recipe: recipe, installed: [], clonesShareStorage: false))
        XCTAssertEqual(plan.totalBytes, recipe.totalBytes)
        XCTAssertEqual(plan.downloadBytes, recipe.totalBytes)
    }
}

final class ModelExpansionTaskGatingTests: XCTestCase {
    func testTaskContractsStayDistinct() {
        XCTAssertNil(VideoCapabilityRegistry.capability(recipeID: VideoCapabilityRegistry.wanT2VRecipeID, task: .imageToVideo), "Wan2.1 T2V never animates images")
        for id in [MediaModelCatalog.animateDiffRecipeID, MediaModelCatalog.lingBotRecipeID, MediaModelCatalog.wan22TI2VRecipeID] {
            XCTAssertNotNil(VideoCapabilityRegistry.capability(recipeID: id, task: .textToVideo))
            XCTAssertNotNil(VideoCapabilityRegistry.capability(recipeID: id, task: .imageToVideo))
            for task in [VideoTask.firstLastFrame, .timedKeyframes, .videoToVideo] { XCTAssertNil(VideoCapabilityRegistry.capability(recipeID: id, task: task), "\(id) \(task)") }
        }
        XCTAssertEqual(ImageCapabilityRegistry.sd15ImageToImage.conditioning, .startImageStrength)
        XCTAssertEqual(ImageCapabilityRegistry.kleinReference.conditioning, .referenceImage)
        XCTAssertNil(ImageCapabilityRegistry.kleinReference.strength, "Reference editing has no re-noise strength")
        XCTAssertTrue(VideoCapabilityRegistry.capabilities(for: .imageToVideo).allSatisfy { $0.requiredRoles.contains(.startImage) })
        XCTAssertTrue(VideoCapabilityRegistry.capabilities(for: .textToVideo).allSatisfy { !$0.supportedRoles.contains(.startImage) })
    }

    func testImagePreflightNeverIgnoresAConnectedReference() throws {
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "a fruit bowl")
        let reference = StudioNode(kind: .imageInput, label: "R", position: .init(x: 0, y: 1), imagePath: #filePath)
        var generator = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 1, y: 0), model: "sd15-q4")
        func project(_ node: StudioNode) -> WorkflowProject {
            .init(name: "I2I", nodes: [prompt, reference, node], edges: [VideoFixtures.edge(prompt, "text", node, "prompt", .text), VideoFixtures.edge(reference, "image", node, "referenceImage", .image)])
        }
        let verified = [ImageCapabilityRegistry.sd15TextToImage, ImageCapabilityRegistry.sd15ImageToImage.with(readiness: .verified(evidence: "test"))]
        XCTAssertThrowsError(try GraphValidator(imageCapabilities: [ImageCapabilityRegistry.sd15TextToImage]).validate(project(generator), requireRunnableInputs: true)) {
            XCTAssertTrue($0.localizedDescription.contains("Reference"), $0.localizedDescription)
        }
        XCTAssertNoThrow(try GraphValidator(imageCapabilities: verified).validate(project(generator)))
        generator.imageStrength = 0.95
        XCTAssertThrowsError(try GraphValidator(imageCapabilities: verified).validate(project(generator))) { XCTAssertTrue($0.localizedDescription.contains("Strength"), $0.localizedDescription) }
        generator.imageStrength = nil; generator.width = 500
        XCTAssertThrowsError(try GraphValidator(imageCapabilities: verified).validate(project(generator))) { XCTAssertTrue($0.localizedDescription.contains("Image dimensions"), $0.localizedDescription) }
        // Proof is a label, not a permission: an adapter-backed route validates before it has any
        // local proof, and earns that proof from its first decoded result.
        generator.width = 512; generator.model = MediaModelCatalog.kleinRecipeID
        let unproven = [ImageCapabilityRegistry.kleinTextToImage.with(readiness: .awaitingProof), ImageCapabilityRegistry.kleinReference.with(readiness: .awaitingProof)]
        XCTAssertNoThrow(try GraphValidator(imageCapabilities: unproven).validate(project(generator)))
        // A withdrawn route stays a hard block, and its reason reaches the user unchanged.
        let withdrawn = [ImageCapabilityRegistry.kleinTextToImage.with(readiness: .unavailable(reason: "This route was withdrawn after it rendered static frames.")),
                         ImageCapabilityRegistry.kleinReference.with(readiness: .unavailable(reason: "This route was withdrawn after it rendered static frames."))]
        XCTAssertThrowsError(try GraphValidator(imageCapabilities: withdrawn).validate(project(generator))) { XCTAssertTrue($0.localizedDescription.contains("withdrawn"), $0.localizedDescription) }
    }

    func testImageExperimentalOptInIsExactAndPersisted() throws {
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID })
        let installed = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
            components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/models/\($0.id)"), source: $0) },
            installedAt: Date(), inferenceVerified: false, available: true, recipeSnapshot: recipe)
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "a product photograph")
        var generator = StudioNode(kind: .imageGenerator, label: "Klein", position: .init(x: 1, y: 0), model: recipe.id)
        generator.width = 768; generator.height = 768
        let project: (StudioNode) -> WorkflowProject = { node in
            .init(name: "Klein first run", nodes: [prompt, node], edges: [VideoFixtures.edge(prompt, "text", node, "prompt", .text)])
        }
        // An installed, adapter-backed recipe runs on first use without any opt-in. This is the
        // change that makes a newly downloaded model usable without a code change.
        let unproven = [ImageCapabilityRegistry.kleinTextToImage.with(readiness: .awaitingProof), ImageCapabilityRegistry.kleinReference.with(readiness: .awaitingProof)]
        XCTAssertNoThrow(try GraphValidator(imageCapabilities: unproven).validate(project(generator), installedGenerationModels: [installed]))
        // The opt-in flag is still persisted so older workflow documents decode unchanged, but it
        // is no longer what grants permission.
        generator.experimentalImageRecipeID = recipe.id
        XCTAssertNoThrow(try GraphValidator(imageCapabilities: unproven).validate(project(generator), installedGenerationModels: [installed]))
        let decoded = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(generator))
        XCTAssertEqual(decoded.experimentalImageRecipeID, recipe.id)
        let (request, _) = try ImageRequestPlanner.makeRequest(recipeID: recipe.id, task: .textToImage, prompt: "a product photograph", width: 768, height: 768, seed: 1, strength: nil, registry: ImageCapabilityRegistry.shipped, allowsUnverifiedLocalRun: true)
        XCTAssertEqual(request.allowsUnverifiedLocalRun, true)
    }

    func testVideoPlannerValidatesStrengthAndOnlyUsedControls() throws {
        let animate = VideoCapabilityRegistry.animateDiffImageToVideo.with(readiness: .verified(evidence: "test"))
        var settings = animate.recommended
        settings.flowShift = .nan
        let start = VideoMediaInput(role: .startImage, identity: .init(sha256: String(repeating: "a", count: 64), byteSize: 1), location: URL(fileURLWithPath: "/w/start.png"))
        let request = try VideoRequestPlanner.makeRequest(settings: settings, task: .imageToVideo, capability: animate, prompt: "wind", negativePrompt: nil, mediaInputs: [start])
        XCTAssertEqual(request.strength, 0.75); XCTAssertEqual(request.scheduler, "karras")
        settings.strength = 0.99
        XCTAssertThrowsError(try VideoRequestPlanner.makeRequest(settings: settings, task: .imageToVideo, capability: animate, prompt: "wind", negativePrompt: nil, mediaInputs: [start])) { XCTAssertTrue($0.localizedDescription.contains("Strength")) }
        XCTAssertThrowsError(try VideoRequestPlanner.makeRequest(settings: animate.recommended, task: .imageToVideo, capability: animate, prompt: "wind", negativePrompt: nil)) { XCTAssertTrue($0.localizedDescription.contains("startImage"), $0.localizedDescription) }
        XCTAssertNoThrow(try VideoRequestPlanner.makeRequest(settings: animate.recommended, task: .imageToVideo, capability: VideoCapabilityRegistry.animateDiffImageToVideo, prompt: "wind", negativePrompt: nil, mediaInputs: [start]))
        let lingBot = VideoCapabilityRegistry.lingBotTextToVideo.with(readiness: .verified(evidence: "test"))
        XCTAssertEqual(try VideoRequestPlanner.makeRequest(settings: lingBot.recommended, task: .textToVideo, capability: lingBot, prompt: "a cat", negativePrompt: nil).sampler, "default", "No sampler flag is recorded as the runtime default")
    }
}

final class ModelExpansionCommandTests: XCTestCase {
    private let neg = VideoGenerationSettings().negativePrompt
    private let pattern = URL(fileURLWithPath: "/w/frame_%03d.png")
    private func request(_ capability: VideoCapability, media: [VideoMediaInput] = []) throws -> VideoGenerationRequest {
        var settings = capability.recommended; settings.seed = 5
        return try VideoRequestPlanner.makeRequest(settings: settings, task: capability.task, capability: capability, prompt: "a storm", negativePrompt: nil, mediaInputs: media)
    }
    private var start: VideoMediaInput { .init(role: .startImage, identity: .init(sha256: String(repeating: "b", count: 64), byteSize: 1), location: URL(fileURLWithPath: "/w/start.png")) }

    func testAnimateDiffArgumentsFollowThePinnedGuide() throws {
        let components = ["checkpoint": URL(fileURLWithPath: "/m/ckpt.gguf"), "motionModule": URL(fileURLWithPath: "/m/mm.safetensors")]
        let t2v = VideoCapabilityRegistry.animateDiffTextToVideo
        XCTAssertEqual(try VideoAdapterCommand.arguments(try request(t2v), capability: t2v, components: components, framePattern: pattern),
                       ["-M", "vid_gen", "-m", "/m/ckpt.gguf", "--motion-module", "/m/mm.safetensors", "-p", "a storm", "-n", neg, "-W", "384", "-H", "384", "--steps", "20", "--cfg-scale", "8.0",
                        "--sampling-method", "euler", "--scheduler", "discrete", "--video-frames", "16", "--fps", "8", "--diffusion-fa", "--seed", "5", "-o", "/w/frame_%03d.png"])
        let i2v = VideoCapabilityRegistry.animateDiffImageToVideo
        XCTAssertEqual(try VideoAdapterCommand.arguments(try request(i2v, media: [start]), capability: i2v, components: components, framePattern: pattern),
                       ["-M", "vid_gen", "-m", "/m/ckpt.gguf", "--motion-module", "/m/mm.safetensors", "-p", "a storm", "-n", neg, "-W", "512", "-H", "512", "--steps", "25", "--cfg-scale", "7.0",
                        "--sampling-method", "euler", "--scheduler", "karras", "--video-frames", "8", "--fps", "8", "--diffusion-fa", "--seed", "5", "-i", "/w/start.png", "--strength", "0.75", "-o", "/w/frame_%03d.png"])
        XCTAssertThrowsError(try VideoAdapterCommand.arguments(try request(t2v), capability: i2v, components: components, framePattern: pattern), "A T2V request never runs through the I2V descriptor")
        XCTAssertThrowsError(try VideoAdapterCommand.arguments(try request(t2v), capability: t2v, components: ["checkpoint": URL(fileURLWithPath: "/m/ckpt.gguf")], framePattern: pattern), "Missing motion module")
        var withMedia = try request(t2v); withMedia = .init(task: withMedia.task, recipeID: withMedia.recipeID, engineBuild: withMedia.engineBuild, prompt: "x", negativePrompt: "", width: 384, height: 384, frameCount: 16, fps: 8, steps: 20, cfgScale: 8, flowShift: 3, sampler: "euler", seed: 1, mediaInputs: [start])
        XCTAssertThrowsError(try VideoAdapterCommand.arguments(withMedia, capability: t2v, components: components, framePattern: pattern), "Text to video rejects media inputs")
    }

    func testLingBotAndWan22ArgumentsUseTheirOwnEncodersAndControls() throws {
        let components = ["diffusion": URL(fileURLWithPath: "/m/d"), "textEncoder": URL(fileURLWithPath: "/m/t"), "vae": URL(fileURLWithPath: "/m/v")]
        let lingT2V = VideoCapabilityRegistry.lingBotTextToVideo
        var lingArgs = try VideoAdapterCommand.arguments(try request(lingT2V), capability: lingT2V, components: components, framePattern: pattern)
        let positiveIndex = try XCTUnwrap(lingArgs.firstIndex(of: "-p")).advanced(by: 1)
        let negativeIndex = try XCTUnwrap(lingArgs.firstIndex(of: "-n")).advanced(by: 1)
        let positive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lingArgs[positiveIndex].utf8)) as? [String: Any])
        let negativeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lingArgs[negativeIndex].utf8)) as? [String: Any])
        XCTAssertNotNil(positive["caption"], "A basic prompt is wrapped in LingBot's documented caption schema")
        XCTAssertNotNil(negativeJSON["universal_negative"])
        lingArgs[positiveIndex] = "<lingbot-caption>"; lingArgs[negativeIndex] = "<lingbot-negative>"
        XCTAssertEqual(lingArgs,
                       ["-M", "vid_gen", "--diffusion-model", "/m/d", "--llm", "/m/t", "--vae", "/m/v", "-p", "<lingbot-caption>", "-n", "<lingbot-negative>", "-W", "256", "-H", "448", "--steps", "10", "--cfg-scale", "3.0",
                        "--video-frames", "33", "--fps", "8", "--diffusion-fa", "--seed", "5", "--offload-to-cpu", "-o", "/w/frame_%03d.png"])
        let lingI2V = VideoCapabilityRegistry.lingBotImageToVideo
        let lingI2VArgs = try VideoAdapterCommand.arguments(try request(lingI2V, media: [start]), capability: lingI2V, components: components, framePattern: pattern)
        XCTAssertEqual(lingI2VArgs.suffix(4), ["-i", "/w/start.png", "-o", "/w/frame_%03d.png"])
        XCTAssertTrue(lingI2VArgs[try XCTUnwrap(lingI2VArgs.firstIndex(of: "-p")).advanced(by: 1)].contains("Preserve the supplied first frame"))
        let authored = #"{"caption":{"comprehensive_description":"authored"}}"#
        XCTAssertEqual(try LingBotPromptFormatter.positive(authored, task: .textToVideo), authored, "Advanced authored schema is not double wrapped")
        let wanT2V = VideoCapabilityRegistry.wan22TextToVideo
        XCTAssertEqual(try VideoAdapterCommand.arguments(try request(wanT2V), capability: wanT2V, components: components, framePattern: pattern),
                       ["-M", "vid_gen", "--diffusion-model", "/m/d", "--vae", "/m/v", "--t5xxl", "/m/t", "-p", "a storm", "-n", neg, "-W", "480", "-H", "832", "--steps", "20", "--cfg-scale", "6.0",
                        "--sampling-method", "euler", "--video-frames", "33", "--fps", "24", "--flow-shift", "3.0", "--diffusion-fa", "--seed", "5", "--offload-to-cpu", "-o", "/w/frame_%03d.png"])
        let wanI2V = VideoCapabilityRegistry.wan22ImageToVideo
        let i2vArgs = try VideoAdapterCommand.arguments(try request(wanI2V, media: [start]), capability: wanI2V, components: components, framePattern: pattern)
        XCTAssertEqual(i2vArgs.suffix(5), ["-i", "/w/start.png", "--offload-to-cpu", "-o", "/w/frame_%03d.png"]); XCTAssertFalse(i2vArgs.contains("--strength"))
        XCTAssertEqual(i2vArgs.filter { $0 == "--offload-to-cpu" }.count, 1, "The pinned Wan 2.2 guide uses CPU offload for the Apple Silicon-sized workload")
        XCTAssertThrowsError(try VideoAdapterCommand.arguments(try request(wanI2V), capability: wanI2V, components: components, framePattern: pattern), "I2V without its start image")
        XCTAssertEqual(wanT2V.recommended.width, wanI2V.recommended.width, "Wan 2.2 T2V and I2V recommendations must match")
        XCTAssertEqual(wanT2V.recommended.height, wanI2V.recommended.height, "Wan 2.2 T2V and I2V recommendations must match")

        var compiledWan = try request(wanT2V)
        compiledWan.compiledPrompt = "compiled motion prompt"
        let compiledArgs = try VideoAdapterCommand.arguments(compiledWan, capability: wanT2V, components: components, framePattern: pattern)
        XCTAssertEqual(compiledArgs[try XCTUnwrap(compiledArgs.firstIndex(of: "-p")).advanced(by: 1)], "compiled motion prompt")
    }

    func testWanT2VDispatchIsByteIdenticalToTheProvenAdapter() throws {
        let wan = VideoFixtures.verifiedRegistry[0]
        let components = ["diffusion": URL(fileURLWithPath: "/m/d.gguf"), "textEncoder": URL(fileURLWithPath: "/m/t.gguf"), "vae": URL(fileURLWithPath: "/m/v.safetensors")]
        let request = try VideoRequestPlanner.makeRequest(settings: .measuredProbe, task: .textToVideo, capability: wan, prompt: "a pinwheel", negativePrompt: nil)
        XCTAssertEqual(try VideoAdapterCommand.arguments(request, capability: wan, components: components, framePattern: pattern),
                       try WanTextToVideoCommand.arguments(request, components: .init(diffusion: components["diffusion"]!, textEncoder: components["textEncoder"]!, vae: components["vae"]!), framePattern: pattern))
    }

    func testLTX25CPUFallbackIsRetainedOnlyForDiagnosisAndCannotPlanARun() throws {
        let capability = VideoCapabilityRegistry.ltx25TextToVideo
        XCTAssertEqual(capability.command, .ltx25)
        XCTAssertFalse(capability.readiness.adapterAvailable)
        XCTAssertThrowsError(try request(capability)) { error in
            XCTAssertTrue(error.localizedDescription.contains("CPU-offloaded"), error.localizedDescription)
        }
    }

    func testMiniMaxH3Ref2VAUsesReferenceVideoDirectory() throws {
        let capability = VideoCapabilityRegistry.minimaxH3VideoToVideo
        let source = VideoMediaInput(role: .sourceVideo, identity: .init(sha256: String(repeating: "d", count: 64), byteSize: 42), location: URL(fileURLWithPath: "/r/ordered-frames"))
        let args = try VideoAdapterCommand.arguments(request(capability, media: [source]), capability: capability,
            components: ["diffusion": URL(fileURLWithPath: "/m/ref2va.gguf"), "textEncoder": URL(fileURLWithPath: "/m/h3-llm.gguf"), "vae": URL(fileURLWithPath: "/m/h3-vae.safetensors")], framePattern: pattern)
        XCTAssertTrue(args.contains("--ref-video")); XCTAssertEqual(args[args.firstIndex(of: "--ref-video")! + 1], "/r/ordered-frames")
        XCTAssertTrue(args.contains("--offload-to-cpu")); XCTAssertTrue(args.contains("--rng")); XCTAssertTrue(args.contains("cpu"))
        XCTAssertFalse(args.contains("--init-img")); XCTAssertFalse(args.contains("--end-img")); XCTAssertFalse(args.contains("-i"))
    }

    func testImageArgumentsForSD15AndKleinContracts() throws {
        let out = URL(fileURLWithPath: "/o/out.png")
        let sd = ["checkpoint": URL(fileURLWithPath: "/m/sd.gguf")]
        let (t2i, t2iCap) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .textToImage, prompt: "apple", width: 512, height: 512, seed: 42, strength: nil, registry: ImageCapabilityRegistry.shipped)
        XCTAssertEqual(try ImageAdapterCommand.arguments(t2i, capability: t2iCap, components: sd, output: out),
                       ["-M", "img_gen", "-m", "/m/sd.gguf", "-p", "apple", "-W", "512", "-H", "512", "--steps", "20", "--cfg-scale", "7.0", "--sampling-method", "euler_a", "--seed", "42", "-o", "/o/out.png"], "Unchanged from the proven SD 1.5 adapter")
        var withReference = t2i; withReference.referenceImage = URL(fileURLWithPath: "/r.png")
        XCTAssertThrowsError(try ImageAdapterCommand.arguments(withReference, capability: t2iCap, components: sd, output: out))
        var (i2i, i2iCap) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .imageToImage, prompt: "apple", width: 512, height: 512, seed: 42, strength: 0.5, registry: ImageCapabilityRegistry.shipped)
        XCTAssertThrowsError(try ImageAdapterCommand.arguments(i2i, capability: i2iCap, components: sd, output: out), "Image to image needs its reference")
        i2i.referenceImage = URL(fileURLWithPath: "/r.png")
        XCTAssertEqual(try ImageAdapterCommand.arguments(i2i, capability: i2iCap, components: sd, output: out),
                       ["-M", "img_gen", "-m", "/m/sd.gguf", "-p", "apple", "-W", "512", "-H", "512", "--steps", "20", "--cfg-scale", "7.0", "--sampling-method", "euler_a", "--seed", "42", "-i", "/r.png", "--strength", "0.5", "-o", "/o/out.png"])
        let klein = ["diffusion": URL(fileURLWithPath: "/m/k.gguf"), "textEncoder": URL(fileURLWithPath: "/m/q.gguf"), "vae": URL(fileURLWithPath: "/m/v.safetensors")]
        let (kt2i, kCap) = try ImageRequestPlanner.makeRequest(recipeID: MediaModelCatalog.kleinRecipeID, task: .textToImage, prompt: "apple", width: 768, height: 768, seed: 42, strength: nil, registry: ImageCapabilityRegistry.shipped)
        XCTAssertEqual(try ImageAdapterCommand.arguments(kt2i, capability: kCap, components: klein, output: out),
                       ["-M", "img_gen", "--diffusion-model", "/m/k.gguf", "--vae", "/m/v.safetensors", "--llm", "/m/q.gguf", "-p", "apple", "-W", "768", "-H", "768", "--steps", "4", "--cfg-scale", "1.0", "--diffusion-fa", "--offload-to-cpu", "--seed", "42", "-o", "/o/out.png"])
        var (edit, editCap) = try ImageRequestPlanner.makeRequest(recipeID: MediaModelCatalog.kleinRecipeID, task: .imageToImage, prompt: "make it blue", width: 768, height: 768, seed: 42, strength: 0.9, registry: ImageCapabilityRegistry.shipped)
        XCTAssertNil(edit.strength, "Strength is ignored by construction for reference editing")
        edit.referenceImage = URL(fileURLWithPath: "/r.png")
        XCTAssertEqual(try ImageAdapterCommand.arguments(edit, capability: editCap, components: klein, output: out),
                       ["-M", "img_gen", "--diffusion-model", "/m/k.gguf", "--vae", "/m/v.safetensors", "--llm", "/m/q.gguf", "-p", "make it blue", "-W", "768", "-H", "768", "--steps", "4", "--cfg-scale", "1.0", "--sampling-method", "euler", "--diffusion-fa", "--offload-to-cpu", "--seed", "42", "-r", "/r.png", "-o", "/o/out.png"])
        edit.additionalReferenceImages = [URL(fileURLWithPath: "/portrait.png"), URL(fileURLWithPath: "/scene.png")]
        let multiReferenceArguments = try ImageAdapterCommand.arguments(edit, capability: editCap, components: klein, output: out)
        let referencePaths = multiReferenceArguments.enumerated().compactMap { index, argument in
            argument == "-r" && index + 1 < multiReferenceArguments.count ? multiReferenceArguments[index + 1] : nil
        }
        XCTAssertEqual(referencePaths, ["/r.png", "/portrait.png", "/scene.png"])
        XCTAssertEqual(multiReferenceArguments.filter { $0 == "-r" }.count, 3, "Klein uses the runtime's repeatable -r contract in input-port order")
        XCTAssertTrue(multiReferenceArguments.contains("--increase-ref-index"))
        // Every pinned flux2.md example (text-to-image and reference edit alike) pairs
        // --diffusion-fa with --offload-to-cpu; SD 1.5 has no such pinned flag.
        XCTAssertEqual(try ImageAdapterCommand.arguments(kt2i, capability: kCap, components: klein, output: out).filter { $0 == "--offload-to-cpu" }.count, 1)
        XCTAssertFalse(try ImageAdapterCommand.arguments(i2i, capability: i2iCap, components: sd, output: out).contains("--offload-to-cpu"))
    }

    func testReferenceEditingDocumentsBoundedOrderedReferences() {
        XCTAssertTrue(ImageConditioning.referenceImage.explanation.localizedCaseInsensitiveContains("up to three"))
        XCTAssertEqual(ImageCapabilityRegistry.kleinReference.maximumReferenceImages, 3)
        XCTAssertEqual(ImageCapabilityRegistry.sd15ImageToImage.maximumReferenceImages, 1)
        let klein = try! XCTUnwrap(MediaModelCatalog.profile(MediaModelCatalog.kleinRecipeID))
        XCTAssertTrue(klein.notes.contains { $0.localizedCaseInsensitiveContains("character sheet") })
    }

    func testMultipleReferencesRequireKleinAdapter() throws {
        XCTAssertThrowsError(try ImageRequestPlanner.validate(recipeID: ImageCapabilityRegistry.sd15RecipeID, task: .imageToImage, width: 512, height: 512, seed: 7, strength: 0.5, registry: ImageCapabilityRegistry.shipped, referenceCount: 2)) { error in
            XCTAssertTrue(error.localizedDescription.contains("at most 1 Reference image"))
        }
        XCTAssertNoThrow(try ImageRequestPlanner.validate(recipeID: MediaModelCatalog.kleinRecipeID, task: .imageToImage, width: 512, height: 512, seed: 7, strength: nil, registry: ImageCapabilityRegistry.shipped, referenceCount: 3))
        XCTAssertThrowsError(try ImageRequestPlanner.validate(recipeID: MediaModelCatalog.kleinRecipeID, task: .imageToImage, width: 512, height: 512, seed: 7, strength: nil, registry: ImageCapabilityRegistry.shipped, referenceCount: 4))
    }

    func testUnsetImageToImageStrengthDefaultsToGenStudiosOnlyMeasuredSetting() throws {
        // Image to image re-renders the whole canvas with no mask, so an unset strength must
        // stay inside evidence GenStudio actually measured, not drift toward the aggressive end
        // of the recipe's bounds (0.1–0.9) and rewrite the source picture near-completely.
        XCTAssertEqual(ImageCapabilityRegistry.defaultStrength, 0.55)
        let (request, _) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .imageToImage, prompt: "apple", width: 512, height: 512, seed: 42, strength: nil, registry: ImageCapabilityRegistry.shipped)
        XCTAssertEqual(request.strength, 0.55)
    }

    /// The inpaint adapter contract (§4/§5 of docs/research/github-creative-workflows/IMPLEMENTATION_PLAN.md):
    /// -i/--mask/--strength are confirmed real flags in the bundled sd-cli --help, but this capability is
    /// deliberately kept out of ImageCapabilityRegistry.shipped until a mask port reaches Image Generator.
    func testInpaintCapabilityIsStagedNotShipped() {
        XCTAssertFalse(ImageCapabilityRegistry.shipped.contains { $0.task == .inpaint }, "Inpaint has no node wiring yet; it must not appear as a selectable adapter")
        XCTAssertFalse(ImageCapabilityRegistry.sd15Inpaint.readiness.proven, "No decoded local proof exists yet")
        XCTAssertEqual(ImageCapabilityRegistry.sd15Inpaint.recipeID, "sd15-q4")
        XCTAssertEqual(ImageCapabilityRegistry.sd15Inpaint.command, .sd15Checkpoint)
    }

    func testInpaintArgumentsUseTheConfirmedMaskFlagsAndRejectMissingMask() throws {
        let out = URL(fileURLWithPath: "/o/out.png")
        let sd = ["checkpoint": URL(fileURLWithPath: "/m/sd.gguf")]
        let registry = [ImageCapabilityRegistry.sd15Inpaint]
        var (request, capability) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .inpaint, prompt: "remove the sign", width: 512, height: 512, seed: 7, strength: 0.6, registry: registry)
        XCTAssertThrowsError(try ImageAdapterCommand.arguments(request, capability: capability, components: sd, output: out), "Inpaint needs its source image") { error in
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("mask"), "Missing source image should fail before the mask is ever checked")
        }
        request.referenceImage = URL(fileURLWithPath: "/source.png")
        XCTAssertThrowsError(try ImageAdapterCommand.arguments(request, capability: capability, components: sd, output: out)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("mask"))
        }
        request.maskImage = URL(fileURLWithPath: "/mask.png")
        XCTAssertEqual(try ImageAdapterCommand.arguments(request, capability: capability, components: sd, output: out),
                       ["-M", "img_gen", "-m", "/m/sd.gguf", "-p", "remove the sign", "-W", "512", "-H", "512", "--steps", "20", "--cfg-scale", "7.0", "--sampling-method", "euler_a", "--seed", "7", "-i", "/source.png", "--mask", "/mask.png", "--strength", "0.6", "-o", "/o/out.png"])
    }
}

enum FitFixtures {
    static let gib: UInt64 = 1024 * 1024 * 1024
    static func m1Max(memory: UInt64 = 64 * gib, disk: Int64 = 761 * 1024 * 1024 * 1024, clones: Bool = true, chip: String = "Apple M1 Max") -> HardwareProfile {
        .init(chip: chip, memoryBytes: memory, osVersion: "Version 26.6.2 (Build 25G100)", freeDiskBytes: disk, totalDiskBytes: 0, gpuWorkingSetBytes: 55_662_788_608, volumeSupportsCloning: clones)
    }
    static func installed(_ id: String, available: Bool = true) -> InstalledGenerationModel {
        let recipe = ModelCatalog.recipes.first { $0.id == id }!
        return .init(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
                     components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/lib/\(recipe.id)/\($0.id)"), source: $0) },
                     installedAt: Date(), inferenceVerified: true, available: available, recipeSnapshot: recipe)
    }
    static func recipe(_ id: String) -> ModelRecipe { ModelCatalog.recipes.first { $0.id == id }! }
}

final class ModelExpansionFitTests: XCTestCase {
    func testThisMacAssessmentReusesSharedComponentsAndDistinguishesStates() throws {
        let installed = [FitFixtures.installed("sd15-q4"), FitFixtures.installed(VideoCapabilityRegistry.wanT2VRecipeID)]
        let mac = FitFixtures.m1Max()
        let animate = RecipeFit.assess(recipe: FitFixtures.recipe(MediaModelCatalog.animateDiffRecipeID), hardware: mac, installed: installed)
        XCTAssertEqual(animate.state, .adapterUnverified); XCTAssertTrue(animate.canInstall)
        let storage = try XCTUnwrap(animate.storage)
        XCTAssertEqual(storage.downloadBytes, 836_618_008, "Only the motion module downloads")
        XCTAssertEqual(storage.reused.map(\.componentID), ["checkpoint"])
        XCTAssertEqual(storage.requiredFreeBytes, 836_618_008 * 2 + StoragePlan.reserveBytes)
        let lingBot = RecipeFit.assess(recipe: FitFixtures.recipe(MediaModelCatalog.lingBotRecipeID), hardware: mac, installed: installed)
        XCTAssertEqual(lingBot.storage?.reused.map(\.componentID), ["vae"])
        let wan22 = RecipeFit.assess(recipe: FitFixtures.recipe(MediaModelCatalog.wan22TI2VRecipeID), hardware: mac, installed: installed)
        XCTAssertEqual(wan22.storage?.reused.map(\.componentID), ["textEncoder"])
        XCTAssertEqual(wan22.state, .possibleDemanding); XCTAssertTrue(wan22.canInstall)
        XCTAssertEqual(RecipeFit.assess(recipe: FitFixtures.recipe("sd15-q4"), hardware: mac, installed: installed).state, .locallyVerified)
        XCTAssertFalse(RecipeFit.assess(recipe: FitFixtures.recipe("sd15-q4"), hardware: mac, installed: installed).canInstall, "Already installed")
        let fresh = RecipeFit.assess(recipe: FitFixtures.recipe(MediaModelCatalog.animateDiffRecipeID), hardware: mac, installed: [])
        XCTAssertEqual(fresh.storage?.downloadBytes, FitFixtures.recipe(MediaModelCatalog.animateDiffRecipeID).totalBytes)
        for recipe in ModelCatalog.recipes where recipe.kind == .image || recipe.kind == .video {
            let fit = RecipeFit.assess(recipe: recipe, hardware: mac, installed: installed)
            XCTAssertFalse(fit.label.localizedCaseInsensitiveContains("recommended"), "\(recipe.id): never recommended from size alone")
        }
    }

    func testResourceShortfallsAndPlatformAreExplicit() throws {
        let wan22 = FitFixtures.recipe(MediaModelCatalog.wan22TI2VRecipeID)
        XCTAssertEqual(RecipeFit.assess(recipe: wan22, hardware: FitFixtures.m1Max(memory: 8 * FitFixtures.gib), installed: []).state, .insufficientResources)
        XCTAssertEqual(RecipeFit.assess(recipe: wan22, hardware: FitFixtures.m1Max(chip: "Intel Core i9"), installed: []).state, .incompatible)
        let animate = FitFixtures.recipe(MediaModelCatalog.animateDiffRecipeID)
        let short = RecipeFit.assess(recipe: animate, hardware: FitFixtures.m1Max(disk: 1024 * 1024 * 1024), installed: [])
        XCTAssertEqual(short.state, .insufficientResources); XCTAssertFalse(short.canInstall)
        XCTAssertEqual(RecipeFit.assess(recipe: animate, hardware: FitFixtures.m1Max(disk: 0), installed: []).label, "Free storage unknown")
        XCTAssertEqual(RecipeFit.assess(recipe: animate, hardware: nil, installed: []).state, .insufficientResources)
        let copies = try XCTUnwrap(StoragePlan.make(recipe: animate, installed: [FitFixtures.installed("sd15-q4")], clonesShareStorage: false))
        let clones = try XCTUnwrap(StoragePlan.make(recipe: animate, installed: [FitFixtures.installed("sd15-q4")], clonesShareStorage: true))
        XCTAssertEqual(copies.requiredFreeBytes - clones.requiredFreeBytes, 1_566_768_416, "Without cloning, a reused component still needs its own space")
        XCTAssertNil(StoragePlan.make(recipe: animate, installed: [FitFixtures.installed("sd15-q4", available: false)], clonesShareStorage: true)?.reused.first, "Missing files are never reused")
    }
}

private final class RecordingTransport: ModelDownloadTransport, @unchecked Sendable {
    let files: [String: Data]
    private let lock = NSLock()
    private var requested: [String] = []
    init(_ files: [String: Data]) { self.files = files }
    var requests: [String] { lock.withLock { requested } }
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { requested.append(from.lastPathComponent) }
        try XCTUnwrap(files[from.lastPathComponent]).write(to: to)
    }
}
private final class DiskScript: @unchecked Sendable {
    private let lock = NSLock(); private var calls = 0; let values: [Int64]
    init(_ values: [Int64]) { self.values = values }
    func next() -> Int64 { lock.withLock { defer { calls += 1 }; return values[min(calls, values.count - 1)] } }
}

final class ModelExpansionInstallTests: XCTestCase {
    private func gguf(_ marker: UInt8) -> Data { Data([71, 71, 85, 70, 3, 0, 0, 0] + Array(repeating: marker, count: 64)) }
    private func component(_ id: String, file: String, _ data: Data, repo: String) -> ModelComponent {
        .init(id: id, role: id, repository: repo, revision: String(repeating: "c", count: 40), filename: file, byteSize: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), license: "test")
    }

    func testInstallReusesIdenticalInstalledComponentAndReverifiesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "reuse-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        let shared = gguf(1), extra = gguf(2)
        let base = ModelRecipe(id: "fixture-base", name: "Base", kind: .image, engineID: "stable-diffusion.cpp", components: [component("checkpoint", file: "base.gguf", shared, repo: "test/base")], runtimeReady: false, minimumMemoryBytes: 1)
        let derived = ModelRecipe(id: "fixture-derived", name: "Derived", kind: .video, engineID: "stable-diffusion.cpp", components: [component("checkpoint", file: "shared.gguf", shared, repo: "test/other"), component("motionModule", file: "extra.gguf", extra, repo: "test/other")], runtimeReady: false, minimumMemoryBytes: 1)
        let transport = RecordingTransport(["base.gguf": shared, "shared.gguf": shared, "extra.gguf": extra])
        let library = ModelLibrary(root: root, catalog: [base, derived], transport: transport, diskAvailable: { _ in Int64.max })
        _ = try await library.install(recipe: base)
        let installed = try await library.install(recipe: derived)
        XCTAssertEqual(transport.requests, ["base.gguf", "extra.gguf"], "The shared checkpoint is not downloaded again")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(installed.componentURL(role: "checkpoint"))), shared)
        try await library.remove(id: base.id)
        let resolved = try await library.resolveInstalledModel(id: derived.id)
        XCTAssertEqual(resolved.components.count, 2, "Removing the source install leaves the reusing install intact")
    }

    func testOverflowInDiskSpaceCalculationRejectsInstallRegardlessOfAvailableSpace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "overflow-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        // Create a component with size close to Int64.max; sum with another would overflow.
        let hugeSize = Int64.max - 100
        let tinyData = gguf(0)
        let recipe = ModelRecipe(id: "overflow-test", name: "Overflow", kind: .image, engineID: "stable-diffusion.cpp",
            components: [.init(id: "huge", role: "huge", repository: "test/overflow", revision: String(repeating: "c", count: 40), filename: "huge.gguf", byteSize: hugeSize, sha256: String(repeating: "a", count: 64), license: "test")], runtimeReady: false, minimumMemoryBytes: 1)
        let library = ModelLibrary(root: root, catalog: [recipe], transport: RecordingTransport(["huge.gguf": tinyData]), diskAvailable: { _ in Int64.max })
        do { _ = try await library.install(recipe: recipe); XCTFail("Must reject when sizes overflow") }
        catch { XCTAssertTrue(error.localizedDescription.contains("overflow") || error.localizedDescription.contains("Invalid"), error.localizedDescription) }
        let models = try await library.installedModels(); XCTAssertTrue(models.isEmpty)
    }

    func testFreeSpaceDropAfterReuseCatchesFailureAndCleansStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "reuse-diskdrop-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        let shared = gguf(1), extra = gguf(2)
        let base = ModelRecipe(id: "fixture-base", name: "Base", kind: .image, engineID: "stable-diffusion.cpp", components: [component("checkpoint", file: "base.gguf", shared, repo: "test/base")], runtimeReady: false, minimumMemoryBytes: 1)
        let derived = ModelRecipe(id: "fixture-derived", name: "Derived", kind: .video, engineID: "stable-diffusion.cpp", components: [component("checkpoint", file: "shared.gguf", shared, repo: "test/other"), component("motionModule", file: "extra.gguf", extra, repo: "test/other")], runtimeReady: false, minimumMemoryBytes: 1)
        let transport = RecordingTransport(["base.gguf": shared, "shared.gguf": shared, "extra.gguf": extra])
        let library = ModelLibrary(root: root, catalog: [base, derived], transport: transport, diskAvailable: { _ in Int64.max })
        _ = try await library.install(recipe: base)
        // Simulate disk space dropping after the reuse clone/copy but before the next download: return max for init/reuse, then 0 for download.
        let script = DiskScript([Int64.max, Int64.max, 0])
        let library2 = ModelLibrary(root: root, catalog: [derived], transport: transport, diskAvailable: { _ in script.next() })
        do { _ = try await library2.install(recipe: derived); XCTFail("Must stop when space drops after reuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Free disk space dropped"), error.localizedDescription) }
        let models = try await library2.installedModels()
        let derivedModel = models.first { $0.id == "fixture-derived" }
        XCTAssertNil(derivedModel, "Failed derived install must not register")
        let staging = root.appending(path: ".staging")
        let stagingExists = FileManager.default.fileExists(atPath: staging.path)
        if stagingExists {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            XCTAssertTrue(contents.isEmpty, "Staging directory must be empty after failed install, but contains: \(contents)")
        }
    }

    func testFreeSpaceDropDuringInstallRegistersNothingAndCleansStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "diskdrop-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        let a = gguf(3), b = gguf(4)
        let recipe = ModelRecipe(id: "fixture-two", name: "Two", kind: .image, engineID: "stable-diffusion.cpp", components: [component("first", file: "a.gguf", a, repo: "test/two"), component("second", file: "b.gguf", b, repo: "test/two")], runtimeReady: false, minimumMemoryBytes: 1)
        let script = DiskScript([Int64.max, Int64.max, 0])
        let library = ModelLibrary(root: root, catalog: [recipe], transport: RecordingTransport(["a.gguf": a, "b.gguf": b]), diskAvailable: { _ in script.next() })
        do { _ = try await library.install(recipe: recipe); XCTFail("Must stop when space disappears") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Free disk space dropped"), error.localizedDescription) }
        let models = try await library.installedModels(); XCTAssertTrue(models.isEmpty)
        let staging = root.appending(path: ".staging")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty)
    }
}

private actor CapturingImageEngine: ImageGenerationEngine {
    let result: URL
    private(set) var requests: [ImageGenerationRequest] = []
    init(_ result: URL) { self.result = result }
    func generate(_ request: ImageGenerationRequest) async throws -> URL { requests.append(request); return result }
    func captured() -> [ImageGenerationRequest] { requests }
}

final class ModelExpansionExecutionTests: XCTestCase {
    private func size(_ url: URL) throws -> (Int, Int) {
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        return (image.width, image.height)
    }

    func testImageToImagePreparesAndHashesReferenceBeforeEngine() async throws {
        let root = try VideoFixtures.root("i2i-wiring"); defer { try? FileManager.default.removeItem(at: root) }
        let still = try VideoFixtures.solidPNG((10, 120, 200), width: 64, height: 36, in: root, name: "reference")
        let output = try VideoFixtures.solidPNG((0, 0, 0), width: 512, height: 512, in: root, name: "result")
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "a watercolor")
        let reference = StudioNode(kind: .imageInput, label: "R", position: .init(x: 0, y: 1), imagePath: still.path)
        var generator = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 1, y: 0), model: "sd15-q4"); generator.imageStrength = 0.4
        let project = WorkflowProject(name: "I2I", nodes: [prompt, reference, generator], edges: [VideoFixtures.edge(prompt, "text", generator, "prompt", .text), VideoFixtures.edge(reference, "image", generator, "referenceImage", .image)])
        let engine = CapturingImageEngine(output)
        let registry = [ImageCapabilityRegistry.sd15TextToImage, ImageCapabilityRegistry.sd15ImageToImage.with(readiness: .verified(evidence: "test"))]
        _ = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), imageEngine: engine, imageCapabilities: registry).execute(project: project, targetID: generator.id)
        let capturedImages = await engine.captured()
        let request = try XCTUnwrap(capturedImages.first)
        XCTAssertEqual(request.task, .imageToImage); XCTAssertEqual(request.strength, 0.4)
        let prepared = try XCTUnwrap(request.referenceImage)
        XCTAssertEqual(try size(prepared).0, 512); XCTAssertEqual(try size(prepared).1, 512)
        XCTAssertEqual(request.referenceIdentity, try MediaIdentity.of(prepared))
        XCTAssertEqual(request.sourceReferenceIdentity, try MediaIdentity.of(still))
        let runs = try await StudioPersistence(root: root).loadRuns()
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.snapshot.imageRequest, request); XCTAssertEqual(run.status, .succeeded)
    }

    func testImageToVideoPreparesStartImageAndRecordsProvenance() async throws {
        let root = try VideoFixtures.root("i2v-wiring"); defer { try? FileManager.default.removeItem(at: root) }
        let still = try VideoFixtures.solidPNG((200, 40, 40), width: 64, height: 36, in: root, name: "start")
        let clip = try await VideoFixtures.colorClip((90, 90, 90), frames: 8, fps: 8, width: 448, height: 256, in: root, name: "fixture")
        let capability = VideoCapabilityRegistry.lingBotImageToVideo.with(readiness: .verified(evidence: "test"))
        let image = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: still.path)
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 1), prompt: "gentle wind")
        var i2v = StudioNode(kind: .imageToVideo, label: "I2V", position: .init(x: 1, y: 0), model: MediaModelCatalog.lingBotRecipeID); i2v.video = capability.recommended
        let project = WorkflowProject(name: "I2V", nodes: [image, prompt, i2v], edges: [VideoFixtures.edge(image, "image", i2v, "startImage", .image), VideoFixtures.edge(prompt, "text", i2v, "prompt", .text)])
        let engine = FixtureVideoEngine(.succeed(clip))
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), videoEngine: engine, videoCapabilities: [capability]).execute(project: project, targetID: i2v.id)
        let capturedVideos = await engine.captured()
        let request = try XCTUnwrap(capturedVideos.first)
        XCTAssertEqual(request.task, .imageToVideo); XCTAssertEqual(request.mediaInputs.map(\.role), [.startImage])
        let prepared = request.mediaInputs[0]
        XCTAssertEqual(request.width, 448); XCTAssertEqual(request.height, 256)
        XCTAssertEqual(try size(prepared.location).0, 448); XCTAssertEqual(try size(prepared.location).1, 256)
        XCTAssertEqual(try MediaIdentity.of(prepared.location), prepared.identity)
        XCTAssertEqual(request.sourceIdentities, [try MediaIdentity.of(still)])
        XCTAssertEqual(result.run?.snapshot.outputMedia?.operation, .imageToVideo)
        XCTAssertEqual(result.run?.snapshot.outputMedia?.inputs.count, 2)
    }

    func testWan22ImageToVideoRunsWhenInstalledWithoutPersistedFirstRunOptIn() async throws {
        let root = try VideoFixtures.root("wan22-i2v-first-run"); defer { try? FileManager.default.removeItem(at: root) }
        let still = try VideoFixtures.solidPNG((30, 80, 180), width: 64, height: 36, in: root, name: "start")
        let capability = VideoCapabilityRegistry.wan22ImageToVideo
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == capability.recipeID })
        let installedComponents = recipe.components.map { component in
            InstalledModelComponent(id: component.id, role: component.role, fileURL: root.appending(path: component.id), source: component)
        }
        let unverified = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID, components: installedComponents, installedAt: Date(), inferenceVerified: false, available: true, recipeSnapshot: recipe)
        let verified = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID, components: installedComponents, installedAt: Date(), inferenceVerified: true, available: true, recipeSnapshot: recipe)
        let image = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: still.path)
        let prompt = StudioNode(kind: .prompt, label: "Motion", position: .init(x: 0, y: 1), prompt: "slow camera push")
        var i2v = StudioNode(kind: .imageToVideo, label: "Wan I2V", position: .init(x: 1, y: 0), model: recipe.id)
        i2v.video = capability.recommended
        func project(_ node: StudioNode) -> WorkflowProject {
            .init(name: "Wan first run", nodes: [image, prompt, node], edges: [VideoFixtures.edge(image, "image", node, "startImage", .image), VideoFixtures.edge(prompt, "text", node, "prompt", .text)])
        }
        XCTAssertNoThrow(try GraphValidator().validate(project(i2v), installedGenerationModels: [unverified]))

        let clip = try await VideoFixtures.colorClip((80, 80, 80), frames: capability.recommended.frameCount, fps: capability.recommended.fps, width: capability.recommended.width, height: capability.recommended.height, in: root, name: "fixture")
        let engine = FixtureVideoEngine(.succeed(clip))
        _ = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), videoEngine: engine).execute(project: project(i2v), targetID: i2v.id, installedGenerationModels: [unverified])
        let captured = await engine.captured()
        let firstRequest = try XCTUnwrap(captured.first)
        XCTAssertEqual(firstRequest.task, .imageToVideo)
        XCTAssertEqual(firstRequest.recipeID, recipe.id)
        XCTAssertNil(firstRequest.allowsUnverifiedLocalRun, "Video execution no longer carries a first-run authorization flag")

        XCTAssertNoThrow(try GraphValidator().validate(project(i2v), installedGenerationModels: [verified]))
    }

    func testMiniMaxRef2VAPreparesReferenceFramesAndPreservesSourceProvenance() async throws {
        let root = try VideoFixtures.root("ref2va-wiring"); defer { try? FileManager.default.removeItem(at: root) }
        let capability = VideoCapabilityRegistry.minimaxH3VideoToVideo
        let source = try await VideoFixtures.colorClip((30, 90, 160), frames: capability.recommended.frameCount, fps: capability.recommended.fps,
                                                        width: capability.recommended.width, height: capability.recommended.height, in: root, name: "source")
        let generated = try await VideoFixtures.colorClip((160, 90, 30), frames: capability.recommended.frameCount, fps: capability.recommended.fps,
                                                           width: capability.recommended.width, height: capability.recommended.height, in: root, name: "generated")
        let videoInput = StudioNode(kind: .videoInput, label: "Source", position: .init(x: 0, y: 0), videoPath: source.path)
        let prompt = StudioNode(kind: .prompt, label: "Edit", position: .init(x: 0, y: 1), prompt: "make the lighting warmer")
        var node = StudioNode(kind: .videoToVideo, label: "Ref2VA", position: .init(x: 1, y: 0), model: capability.recipeID)
        node.video = capability.recommended
        let project = WorkflowProject(name: "Ref2VA", nodes: [videoInput, prompt, node], edges: [
            VideoFixtures.edge(videoInput, "video", node, "sourceVideo", .video),
            VideoFixtures.edge(prompt, "text", node, "prompt", .text)
        ])
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == capability.recipeID })
        let installed = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
            components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: root.appending(path: $0.id), source: $0) },
            installedAt: Date(), inferenceVerified: false, available: true, recipeSnapshot: recipe)
        let engine = FixtureVideoEngine(.succeed(generated))
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), videoEngine: engine,
            videoCapabilities: [capability]).execute(project: project, targetID: node.id, installedGenerationModels: [installed])
        let captured = await engine.captured()
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.task, .videoToVideo)
        XCTAssertEqual(request.mediaInputs.map(\.role), [.sourceVideo])
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.mediaInputs[0].location.path), "Temporary reference frames are removed after the engine consumes them")
        XCTAssertEqual(request.sourceIdentities, [try MediaIdentity.of(source)])
        XCTAssertNil(request.allowsUnverifiedLocalRun)
        XCTAssertEqual(result.run?.snapshot.outputMedia?.operation, .videoToVideo)
        XCTAssertEqual(result.run?.snapshot.outputMedia?.inputs, [try MediaIdentity.of(source), request.mediaInputs[0].identity])
    }

    func testLegacyExperimentalVideoOptInDoesNotAffectRequestPlanning() throws {
        let capability = VideoCapabilityRegistry.wan22ImageToVideo
        var node = StudioNode(kind: .imageToVideo, label: "I2V", position: .init(x: 0, y: 0), model: capability.recipeID)
        node.video = capability.recommended
        node.experimentalVideoRecipeID = MediaModelCatalog.animateDiffRecipeID
        let input = VideoMediaInput(role: .startImage, identity: .init(sha256: String(repeating: "c", count: 64), byteSize: 1), location: URL(fileURLWithPath: "/w/start.png"))
        let request = try VideoRequestPlanner.makeRequest(settings: node.video, task: .imageToVideo, capability: capability, prompt: "motion", negativePrompt: nil, mediaInputs: [input])
        XCTAssertNil(request.allowsUnverifiedLocalRun)
    }

    func testWanFirstLastFrameCommandAndExecutorKeepBothImageRoles() async throws {
        let capability = VideoCapabilityRegistry.wan21FirstLastFrame
        let start = VideoMediaInput(role: .startImage, identity: .init(sha256: String(repeating: "1", count: 64), byteSize: 1), location: URL(fileURLWithPath: "/w/start.png"))
        let end = VideoMediaInput(role: .endImage, identity: .init(sha256: String(repeating: "2", count: 64), byteSize: 1), location: URL(fileURLWithPath: "/w/end.png"))
        let request = try VideoRequestPlanner.makeRequest(settings: capability.recommended, task: .firstLastFrame, capability: capability, prompt: "transform", negativePrompt: nil, mediaInputs: [start, end], allowsUnverifiedLocalRun: true)
        let components = ["diffusion": URL(fileURLWithPath: "/m/d"), "textEncoder": URL(fileURLWithPath: "/m/t"), "vae": URL(fileURLWithPath: "/m/v"), "clipVision": URL(fileURLWithPath: "/m/c")]
        let args = try VideoAdapterCommand.arguments(request, capability: capability, components: components, framePattern: URL(fileURLWithPath: "/w/frame_%03d.png"))
        XCTAssertEqual(args, ["-M", "vid_gen", "--diffusion-model", "/m/d", "--t5xxl", "/m/t", "--vae", "/m/v", "--clip_vision", "/m/c", "-p", "transform", "-n", capability.recommended.negativePrompt, "-W", "480", "-H", "832", "--steps", "20", "--cfg-scale", "6.0", "--sampling-method", "euler", "--video-frames", "17", "--fps", "24", "--flow-shift", "3.0", "--diffusion-fa", "--seed", "424243", "--init-img", "/w/start.png", "--end-img", "/w/end.png", "--offload-to-cpu", "-o", "/w/frame_%03d.png"])
        XCTAssertThrowsError(try VideoRequestPlanner.makeRequest(settings: capability.recommended, task: .firstLastFrame, capability: capability, prompt: "transform", negativePrompt: nil, mediaInputs: [start]))

        let root = try VideoFixtures.root("flf-wiring"); defer { try? FileManager.default.removeItem(at: root) }
        // Wan FLF's pinned recipe is portrait-only, so use portrait sources. A landscape source
        // now correctly fails instead of being silently center-cropped into this fixed canvas.
        let startFile = try VideoFixtures.solidPNG((200, 20, 20), width: 36, height: 64, in: root, name: "start")
        let endFile = try VideoFixtures.solidPNG((20, 20, 200), width: 36, height: 64, in: root, name: "end")
        let clip = try await VideoFixtures.colorClip((90, 90, 90), frames: capability.recommended.frameCount, fps: capability.recommended.fps, width: capability.recommended.width, height: capability.recommended.height, in: root, name: "fixture")
        let startNode = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: startFile.path)
        let endNode = StudioNode(kind: .imageInput, label: "End", position: .init(x: 0, y: 1), imagePath: endFile.path)
        let promptNode = StudioNode(kind: .prompt, label: "Transition", position: .init(x: 0, y: 2), prompt: "transform")
        var flf = StudioNode(kind: .startEndVideo, label: "FLF", position: .init(x: 1, y: 0), model: capability.recipeID)
        flf.video = capability.recommended; flf.experimentalVideoRecipeID = capability.recipeID
        let project = WorkflowProject(name: "FLF", nodes: [startNode, endNode, promptNode, flf], edges: [VideoFixtures.edge(startNode, "image", flf, "startImage", .image), VideoFixtures.edge(endNode, "image", flf, "endImage", .image), VideoFixtures.edge(promptNode, "text", flf, "prompt", .text)])
        let engine = FixtureVideoEngine(.succeed(clip))
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), videoEngine: engine, videoCapabilities: [capability]).execute(project: project, targetID: flf.id)
        let capturedRequests = await engine.captured()
        let captured = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(captured.mediaInputs.map(\.role), [.startImage, .endImage])
        XCTAssertEqual(captured.sourceIdentities?.count, 2)
        XCTAssertEqual(result.run?.snapshot.outputMedia?.operation, .firstLastFrame)
        XCTAssertEqual(result.run?.snapshot.outputMedia?.inputs.count, 4)
    }

    func testOlderNodesGainNoImageStrengthKey() throws {
        let node = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 0, y: 0), model: "sd15-q4")
        let json = String(decoding: try JSONEncoder().encode(node), as: UTF8.self)
        XCTAssertNil(json.range(of: "imageStrength"))
        XCTAssertNil(try JSONDecoder().decode(StudioNode.self, from: Data(json.utf8)).imageStrength)
    }

    /// Inpaint's new request fields must not appear in a request encoded before inpaint existed,
    /// so older persisted RunInputSnapshot/.recipe.json documents keep decoding unchanged.
    func testOlderImageRequestsGainNoMaskKeys() throws {
        let (request, _) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .textToImage, prompt: "apple", width: 512, height: 512, seed: 42, strength: nil, registry: ImageCapabilityRegistry.shipped)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertNil(json.range(of: "maskImage")); XCTAssertNil(json.range(of: "maskIdentity")); XCTAssertNil(json.range(of: "sourceMaskIdentity"))
        let decoded = try JSONDecoder().decode(ImageGenerationRequest.self, from: Data(json.utf8))
        XCTAssertNil(decoded.maskImage); XCTAssertNil(decoded.maskIdentity); XCTAssertNil(decoded.sourceMaskIdentity)
    }
}
