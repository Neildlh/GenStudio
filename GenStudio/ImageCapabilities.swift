import Foundation

/// Distinct image contracts. A text-to-image adapter never implies image-to-image support.
enum ImageTask: String, Codable, CaseIterable, Sendable {
    case textToImage, imageToImage, inpaint

    var title: String {
        switch self {
        case .textToImage: "Text to image"
        case .imageToImage: "Image to image"
        case .inpaint: "Inpaint / Replace Area"
        }
    }
}

/// How an image-to-image adapter uses the connected Reference image. These are not interchangeable.
enum ImageConditioning: String, Codable, Sendable {
    case none
    /// Encoded as the starting latent and re-noised by strength (Stable Diffusion img2img).
    case startImageStrength
    /// Conditions a reference-editing model; it is not a starting latent (FLUX.2 Klein `-r`).
    case referenceImage
    /// Encoded as the starting latent alongside an explicit mask using the bundled runtime's
    /// real `-i`/`--mask`/`--strength` flags (confirmed in `.vendor/sd/logs/help.log`). Only the
    /// masked region is intended to change; GenStudio has not yet decoded a local proof of this.
    case maskedStartImage

    var explanation: String {
        switch self {
        case .none: "Uses the prompt only."
        case .startImageStrength: "The Reference image is center-cropped to the output size and used as the starting picture. Strength sets how far the result may move away from it."
        case .referenceImage: "Reference images guide an edit of their content; they are not re-noised as a starting picture. FLUX.2 Klein accepts up to three ordered references through repeatable -r flags. Other bundled adapters accept one reference only."
        case .maskedStartImage: "The source image and an explicit mask are both passed to the runtime. White marks the area to change; black is preserved. Untouched-area preservation depends on the runtime's own inpainting behavior, which GenStudio has not yet measured locally."
        }
    }
}

struct DoubleBounds: Codable, Hashable, Sendable {
    let minimum: Double
    let maximum: Double
    func contains(_ value: Double) -> Bool { value.isFinite && (minimum...maximum).contains(value) }
    var summary: String { "\(minimum.formatted())–\(maximum.formatted())" }
}

/// Typed command dispatch key. Each profile has exactly one argument builder and one component-role set.
enum ImageCommandProfile: String, Codable, Sendable {
    case sd15Checkpoint, flux2Klein, genericStableDiffusionCheckpoint
    /// Z-Image: the same three-file split as Klein (diffusion model, Qwen3 `--llm` encoder, VAE), per the pinned z_image.md.
    case zImage
    /// No local sd-cli invocation: ImageEngineRouter sends this capability's requests to
    /// ChatGPTSubscriptionImageEngine instead, so ImageAdapterCommand.arguments never runs for it.
    case chatGPTSubscriptionCloud

    var componentRoles: [String] {
        switch self {
        case .sd15Checkpoint, .genericStableDiffusionCheckpoint: ["checkpoint"]
        case .flux2Klein, .zImage: ["diffusion", "textEncoder", "vae"]
        case .chatGPTSubscriptionCloud: []
        }
    }
}

/// Keyed to the exact recipe, engine build and task, like VideoCapability. Controls are advertised only from this descriptor.
struct ImageCapability: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(recipeID)@\(engineBuild):\(task.rawValue)" }
    let recipeID: String
    let engineID: String
    let engineBuild: String
    let task: ImageTask
    let conditioning: ImageConditioning
    let command: ImageCommandProfile
    let width: IntegerBounds
    let height: IntegerBounds
    let steps: Int
    let cfgScale: Double
    /// Nil means the pinned guide does not pass a sampler, so the runtime default is used and recorded as such.
    let sampler: String?
    let strength: DoubleBounds?
    /// Bounded by the exact adapter contract; this is not a generic model claim.
    let maximumReferenceImages: Int
    let readiness: CapabilityReadiness
    let qualityNote: String
    let measuredBaseline: String?

    /// The pixel count a ratio button starts from: each family's native sweet spot, not the largest
    /// canvas the bounds allow. SD 1.5 was trained at 512², FLUX.2 and SDXL-class checkpoints at ~1 MP.
    var optimalPixels: Int { command == .sd15Checkpoint ? 512 * 512 : 1024 * 1024 }

    func with(readiness: CapabilityReadiness) -> ImageCapability {
        .init(recipeID: recipeID, engineID: engineID, engineBuild: engineBuild, task: task, conditioning: conditioning, command: command, width: width, height: height, steps: steps, cfgScale: cfgScale, sampler: sampler, strength: strength, maximumReferenceImages: maximumReferenceImages, readiness: readiness, qualityNote: qualityNote, measuredBaseline: measuredBaseline)
    }
}

enum ImageCapabilityRegistry {
    static let sd15RecipeID = "sd15-q4"
    /// The only strength GenStudio has actually measured locally for image-to-image (see
    /// sd15ImageToImage's measuredBaseline). Image-to-image re-renders the whole canvas with
    /// no mask, so a higher, unmeasured default would move further from the source picture
    /// than anything GenStudio has verified; this keeps the unset default inside evidence.
    static let defaultStrength = 0.55

    static let sd15TextToImage = ImageCapability(
        recipeID: sd15RecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .textToImage,
        conditioning: .none, command: .sd15Checkpoint, width: .init(minimum: 256, maximum: 768, multiple: 64), height: .init(minimum: 256, maximum: 768, multiple: 64),
        steps: 20, cfgScale: 7.0, sampler: "euler_a", strength: nil, maximumReferenceImages: 0,
        readiness: .verified(evidence: "docs/evidence/native-model-library/README.md"),
        qualityNote: "Older SD 1.5 model; start at 512 × 512.",
        measuredBaseline: "A standalone 512 × 512, 20-step run took about 94 seconds on Apple M1 Max / 64 GB (engine time). Other sizes are unmeasured.")

    static let sd15ImageToImage = ImageCapability(
        recipeID: sd15RecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .imageToImage,
        conditioning: .startImageStrength, command: .sd15Checkpoint, width: .init(minimum: 256, maximum: 768, multiple: 64), height: .init(minimum: 256, maximum: 768, multiple: 64),
        steps: 20, cfgScale: 7.0, sampler: "euler_a", strength: .init(minimum: 0.1, maximum: 0.9), maximumReferenceImages: 1,
        readiness: shippedSD15ImageToImageReadiness,
        qualityNote: "Re-renders the whole starting picture with SD 1.5; there is no mask, so every pixel is re-noised by strength, not just an edited region. The unset default (0.55) is GenStudio's only measured local setting: it keeps composition and changed the picture only subtly in the local proof, largely ignoring a colour change in the prompt. Raising strength follows the prompt more but moves further from the source picture; GenStudio has not measured that trade-off locally.",
        measuredBaseline: "Measured once through GenStudio on Apple M1 Max / 64 GB (13 Sep 2026): 512 × 512, 20 steps, strength 0.55 took about 61 s including checksum validation, model load, sampling and retention. Other settings are unmeasured.")

    /// Promoted only after a decoded local render through NativeImageEngine.
    static let shippedSD15ImageToImageReadiness: CapabilityReadiness = .verified(evidence: "docs/research/model-expansion/evidence/proofs/sd15-image-integration.json")

    /// Inpaint adapter contract: `-i`/`--mask`/`--strength` are confirmed real flags in the exact
    /// bundled `sd-cli --help` (`.vendor/sd/logs/help.log`, commit 7f410a3), but no pinned per-model
    /// doc shows a complete SD 1.5 inpaint example and GenStudio has not decoded a local proof.
    /// Deliberately **not** in `shipped`: no node yet connects a mask to the Image Generator, so
    /// listing this here would show an "adapter available" chip with no way to actually run it.
    /// See docs/research/github-creative-workflows/IMPLEMENTATION_PLAN.md §4–5 for the staged wiring.
    static let sd15Inpaint = ImageCapability(
        recipeID: sd15RecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .inpaint,
        conditioning: .maskedStartImage, command: .sd15Checkpoint, width: .init(minimum: 256, maximum: 768, multiple: 64), height: .init(minimum: 256, maximum: 768, multiple: 64),
        steps: 20, cfgScale: 7.0, sampler: "euler_a", strength: .init(minimum: 0.1, maximum: 0.9), maximumReferenceImages: 1,
        readiness: .awaitingProof,
        qualityNote: "Uses the bundled runtime's documented -i/--mask/--strength inpaint contract with SD 1.5. Untouched-area preservation depends on the runtime's own inpainting behavior, which GenStudio has not measured locally. Not reachable from any node yet.",
        measuredBaseline: nil)

    static let kleinTextToImage = ImageCapability(
        recipeID: MediaModelCatalog.kleinRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .textToImage,
        conditioning: .none, command: .flux2Klein, width: .init(minimum: 512, maximum: 1024, multiple: 16), height: .init(minimum: 512, maximum: 1024, multiple: 16),
        steps: 4, cfgScale: 1.0, sampler: nil, strength: nil, maximumReferenceImages: 0,
        readiness: .verified(evidence: "docs/research/model-expansion/evidence/proofs/flux2-klein-reference/klein-reference-integration.json"),
        qualityNote: "Four-step distilled model; start at 512 × 512.",
        measuredBaseline: "A standalone 512 × 512, 4-step run took about 48 seconds on Apple M1 Max / 64 GB (engine time, including component SHA-256 validation and model load). Other sizes are unmeasured.")

    static let kleinReference = ImageCapability(
        recipeID: MediaModelCatalog.kleinRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .imageToImage,
        conditioning: .referenceImage, command: .flux2Klein, width: .init(minimum: 512, maximum: 1024, multiple: 16), height: .init(minimum: 512, maximum: 1024, multiple: 16),
        steps: 4, cfgScale: 1.0, sampler: "euler", strength: nil, maximumReferenceImages: 3,
        readiness: .verified(evidence: "docs/research/model-expansion/evidence/proofs/flux2-klein-reference/klein-reference-integration.json"),
        qualityNote: "Reference-image editing with one to three ordered references. Measured once with three synthetic solid-colour references at 512 × 512: the decoded output visibly took hue and composition cues from all three, so the ordered multi-reference command path is proven end to end. Subject-identity fidelity with real character/portrait/scene photos is unmeasured.",
        measuredBaseline: "A 512 × 512, 4-step run with three ordered references took about 131 seconds on Apple M1 Max / 64 GB (14 Sep 2026, engine time including component SHA-256 validation, model load, sampling, decode and artifact retention). Other reference counts and sizes are unmeasured.")

    /// FLUX.2 Klein 9B uses the same stable-diffusion.cpp command contract as Klein 4B.
    /// The manifest is installable and the route is resource-checked, but it remains awaiting
    /// a decoded local proof until the user runs it on this Mac.
    static let klein9BTextToImage = ImageCapability(
        recipeID: MediaModelCatalog.klein9BRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .textToImage,
        conditioning: .none, command: .flux2Klein, width: .init(minimum: 512, maximum: 1024, multiple: 16), height: .init(minimum: 512, maximum: 1024, multiple: 16),
        steps: 4, cfgScale: 1.0, sampler: nil, strength: nil, maximumReferenceImages: 0,
        readiness: .awaitingProof,
        qualityNote: "Larger nine-billion-parameter distilled model; start at 512 × 512. It is intended as a quality/identity step up from Klein 4B, but this exact quantized route has not yet been benchmarked in GenStudio.",
        measuredBaseline: nil)

    static let klein9BReference = ImageCapability(
        recipeID: MediaModelCatalog.klein9BRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .imageToImage,
        conditioning: .referenceImage, command: .flux2Klein, width: .init(minimum: 512, maximum: 1024, multiple: 16), height: .init(minimum: 512, maximum: 1024, multiple: 16),
        steps: 4, cfgScale: 1.0, sampler: "euler", strength: nil, maximumReferenceImages: 3,
        readiness: .awaitingProof,
        qualityNote: "Reference-image editing with one to three ordered references. Subject-identity fidelity and generation speed for this 9B route are unmeasured; test with a fixed seed and the same character references used for Klein 4B.",
        measuredBaseline: nil)

    /// Z-Image Turbo follows the pinned z_image.md Turbo example: 8 steps, CFG 1.0, flash attention and
    /// CPU offload. It runs on first use and earns its proof from the decoded image.
    static let zImageTurboTextToImage = ImageCapability(
        recipeID: MediaModelCatalog.zImageTurboRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .textToImage,
        conditioning: .none, command: .zImage, width: .init(minimum: 512, maximum: 1024, multiple: 16), height: .init(minimum: 512, maximum: 1024, multiple: 16),
        steps: 8, cfgScale: 1.0, sampler: nil, strength: nil, maximumReferenceImages: 0,
        readiness: .awaitingProof,
        qualityNote: "Eight-step distilled model, rated level with FLUX.2 Klein 9B in independent blind votes and good at lettering inside the image. Text to image only. Apache-2.0. Not yet run on this Mac; start at 512 × 512.",
        measuredBaseline: nil)

    /// Juggernaut XL v9 is a complete single-file SDXL checkpoint.  Its route is
    /// intentionally separate from the generic import profile so the picker can
    /// give it suitable SDXL dimensions and the publisher's quality-oriented
    /// baseline without pretending a local render has already been measured.
    static let juggernautXLTextToImage = ImageCapability(
        recipeID: MediaModelCatalog.juggernautXLRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .textToImage,
        conditioning: .none, command: .genericStableDiffusionCheckpoint, width: .init(minimum: 512, maximum: 1536, multiple: 64), height: .init(minimum: 512, maximum: 1536, multiple: 64),
        steps: 35, cfgScale: 5.0, sampler: "euler_a", strength: nil, maximumReferenceImages: 0,
        readiness: .awaitingProof,
        qualityNote: "SDXL photographic comparison model. Start at 1024 × 1024 or 832 × 1216; its first GenStudio render is an explicit test, not a claimed benchmark.",
        measuredBaseline: nil)

    static let juggernautXLImageToImage = ImageCapability(
        recipeID: MediaModelCatalog.juggernautXLRecipeID, engineID: "stable-diffusion.cpp", engineBuild: VideoCapabilityRegistry.sdCppBuild, task: .imageToImage,
        conditioning: .startImageStrength, command: .genericStableDiffusionCheckpoint, width: .init(minimum: 512, maximum: 1536, multiple: 64), height: .init(minimum: 512, maximum: 1536, multiple: 64),
        steps: 35, cfgScale: 5.0, sampler: "euler_a", strength: .init(minimum: 0.1, maximum: 0.9), maximumReferenceImages: 1,
        readiness: .awaitingProof,
        qualityNote: "Whole-image SDXL image-to-image. It re-renders the connected starting image; use Klein 9B when you need up to three ordered reference images.",
        measuredBaseline: nil)

    /// Cloud, subscription-billed route: not a local runtime, so it carries no
    /// engineBuild/component contract and its readiness cannot come from a decoded
    /// local render. `.awaitingProof` here just means "not yet exercised in this
    /// install," matching how every other not-yet-run adapter is labeled.
    static let chatGPTCloudEngineBuild = "cloud"

    static let chatGPTSubscriptionTextToImage = ImageCapability(
        recipeID: ChatGPTSubscriptionImageEngine.recipeID, engineID: ChatGPTSubscriptionImageEngine.engineID, engineBuild: chatGPTCloudEngineBuild, task: .textToImage,
        conditioning: .none, command: .chatGPTSubscriptionCloud, width: .init(minimum: 1024, maximum: 1536, multiple: 512), height: .init(minimum: 1024, maximum: 1536, multiple: 512),
        steps: 1, cfgScale: 1.0, sampler: nil, strength: nil, maximumReferenceImages: 0,
        readiness: .awaitingProof,
        qualityNote: "Generates through your signed-in ChatGPT subscription instead of a local model — experimental and unofficial (see Settings). Requests snap to the nearest of gpt-image-2's three fixed sizes: 1024 × 1024, 1024 × 1536, 1536 × 1024.",
        measuredBaseline: nil)

    static let chatGPTSubscriptionReference = ImageCapability(
        recipeID: ChatGPTSubscriptionImageEngine.recipeID, engineID: ChatGPTSubscriptionImageEngine.engineID, engineBuild: chatGPTCloudEngineBuild, task: .imageToImage,
        conditioning: .referenceImage, command: .chatGPTSubscriptionCloud, width: .init(minimum: 1024, maximum: 1536, multiple: 512), height: .init(minimum: 1024, maximum: 1536, multiple: 512),
        steps: 1, cfgScale: 1.0, sampler: nil, strength: nil, maximumReferenceImages: 4,
        readiness: .awaitingProof,
        qualityNote: "Reference-guided edit through your signed-in ChatGPT subscription instead of a local model — experimental and unofficial (see Settings). Reference-count support beyond one image is unverified against a live account.",
        measuredBaseline: nil)

    static let shipped: [ImageCapability] = [sd15TextToImage, sd15ImageToImage, kleinTextToImage, kleinReference, klein9BTextToImage, klein9BReference, zImageTurboTextToImage, juggernautXLTextToImage, juggernautXLImageToImage, chatGPTSubscriptionTextToImage, chatGPTSubscriptionReference]

    static func capabilities(for task: ImageTask, in registry: [ImageCapability] = shipped) -> [ImageCapability] { registry.filter { $0.task == task } }
    static func capability(recipeID: String, task: ImageTask, in registry: [ImageCapability] = shipped) -> ImageCapability? {
        registry.first { $0.recipeID == recipeID && $0.task == task }
    }
    /// True when at least one task for this recipe has a decoded local proof.
    static func supportsRecipe(_ recipeID: String, in registry: [ImageCapability] = shipped) -> Bool {
        registry.contains { $0.recipeID == recipeID && $0.readiness.proven }
    }
    static func hasAdapter(_ recipeID: String, in registry: [ImageCapability] = shipped) -> Bool { registry.contains { $0.recipeID == recipeID } }
    static func hasUsableAdapter(_ recipeID: String, in registry: [ImageCapability] = shipped) -> Bool {
        registry.contains { $0.recipeID == recipeID && $0.readiness.adapterAvailable }
    }
    static func task(referenceConnected: Bool) -> ImageTask { referenceConnected ? .imageToImage : .textToImage }
    static func task(referenceCount: Int) -> ImageTask { referenceCount > 0 ? .imageToImage : .textToImage }

    /// Builds the generic capability from user data. This is intentionally
    /// conservative: a single checkpoint is exposed only for the two modes
    /// the bundled CLI can express without model-specific code.
    static func userCapability(recipe: ModelRecipe, task: ImageTask) -> ImageCapability? {
        guard task == .textToImage || task == .imageToImage,
              UserModelCatalog.isSupported(recipe),
              (recipe.supportedImageTasks ?? [.textToImage, .imageToImage]).contains(task) else { return nil }
        return ImageCapability(recipeID: recipe.id, engineID: recipe.engineID, engineBuild: VideoCapabilityRegistry.sdCppBuild, task: task,
            conditioning: task == .textToImage ? .none : .startImageStrength, command: .genericStableDiffusionCheckpoint,
            width: .init(minimum: 256, maximum: 1024, multiple: 64), height: .init(minimum: 256, maximum: 1024, multiple: 64),
            steps: 20, cfgScale: 7.0, sampler: "euler_a", strength: task == .textToImage ? nil : .init(minimum: 0.1, maximum: 0.9), maximumReferenceImages: task == .textToImage ? 0 : 1,
            readiness: .awaitingProof, qualityNote: "Imported user checkpoint. Resolution, sampler and quality are conservative defaults; test this model with a fixed seed before relying on it.", measuredBaseline: nil)
    }

    /// Adds capabilities declared by installed, validated runtime profiles to
    /// the built-in registry. Exact built-in descriptors always win.
    static func runtimeRegistry(base: [ImageCapability] = shipped, installed: [InstalledGenerationModel]?) -> [ImageCapability] {
        guard let installed else { return base }
        var result = base
        var known = Set(base.map(\.id))
        for model in installed where model.available {
            guard let recipe = model.recipeSnapshot else { continue }
            for task in ImageTask.allCases {
                guard let capability = userCapability(recipe: recipe, task: task), known.insert(capability.id).inserted else { continue }
                result.append(capability)
            }
        }
        return result
    }

    /// Node inspectors list only complete local installs that can handle the
    /// task implied by the node's current wiring, plus the ChatGPT subscription
    /// route when `cloudSignedIn` is true — it has no local install to gate on.
    static func selectableCapabilities(task: ImageTask, referenceCount: Int, installed: [InstalledGenerationModel], cloudSignedIn: Bool = false) -> [ImageCapability] {
        let availableIDs = Set(installed.filter(\.available).map(\.id))
        var results = runtimeRegistry(installed: installed)
            .filter { $0.task == task && availableIDs.contains($0.recipeID) }
        if cloudSignedIn {
            results += shipped.filter { $0.task == task && $0.engineID == ChatGPTSubscriptionImageEngine.engineID }
        }
        return results.filter { referenceCount == 0 || $0.maximumReferenceImages >= referenceCount }
    }
}

/// A fully resolved image job: every value the adapter uses and provenance records.
struct ImageGenerationRequest: Codable, Hashable, Sendable {
    let task: ImageTask
    let recipeID: String
    let engineBuild: String
    let prompt: String
    /// `prompt` is the adapter-ready value. These fields preserve the
    /// human-authored value and compiler provenance alongside it.
    var authoredPrompt: String? = nil
    var compiledPrompt: String? = nil
    var promptCompilerModelID: String? = nil
    var promptCompilerVersion: String? = nil
    var promptCompilerUsedFallback: Bool? = nil
    let width: Int
    let height: Int
    let seed: Int
    let steps: Int
    let cfgScale: Double
    let sampler: String?
    let strength: Double?
    /// Prepared file actually passed to the engine, with its content identity.
    var referenceImage: URL? = nil
    var referenceIdentity: MediaIdentity? = nil
    /// Identity of the connected image before any crop/resize.
    var sourceReferenceIdentity: MediaIdentity? = nil
    /// Additional references preserve the old single-reference fields above so
    /// saved run snapshots decode unchanged.
    /// The deterministic role preamble folded into `prompt`, kept separately so run
    /// history shows what the roles contributed rather than only the merged result.
    /// Additive and optional so snapshots saved before roles existed decode unchanged.
    var referenceRolePreamble: String? = nil
    var additionalReferenceImages: [URL]? = nil
    var additionalReferenceIdentities: [MediaIdentity]? = nil
    var sourceAdditionalReferenceIdentities: [MediaIdentity]? = nil
    var referenceImages: [URL] { [referenceImage].compactMap { $0 } + (additionalReferenceImages ?? []) }
    var referenceIdentities: [MediaIdentity] { [referenceIdentity].compactMap { $0 } + (additionalReferenceIdentities ?? []) }
    /// True only when the workflow explicitly authorized a first run of this
    /// exact image recipe before a decoded local proof existed.
    var allowsUnverifiedLocalRun: Bool? = nil
    /// Inpaint's explicit mask (`.maskedStartImage` conditioning only). Prepared file actually
    /// passed to the engine's `--mask` flag, with its content identity. Additive and optional so
    /// persisted `RunInputSnapshot`/run-history documents from before inpaint existed decode unchanged.
    var maskImage: URL? = nil
    var maskIdentity: MediaIdentity? = nil
    /// Identity of the connected mask before any crop/resize.
    var sourceMaskIdentity: MediaIdentity? = nil
}

enum ImageRequestPlanner {
    /// Pure validation shared by preflight and execution. Throws before any model loads.
    static func validate(recipeID: String, task: ImageTask, width: Int, height: Int, seed: Int, strength: Double?, registry: [ImageCapability], referenceCount: Int? = nil) throws -> ImageCapability {
        guard let capability = ImageCapabilityRegistry.capability(recipeID: recipeID, task: task, in: registry) else {
            if task == .imageToImage {
                throw StudioError.validation("Recipe \(recipeID) has no image-to-image adapter, so its connected Reference image cannot be used. Disconnect the reference explicitly or choose a recipe that supports image to image; GenStudio never ignores a connected image.")
            }
            throw StudioError.validation("Recipe \(recipeID) has no text-to-image adapter in GenStudio.")
        }
        // Proof is a label, not a permission. An adapter-backed route runs on first use and
        // earns its proof from the decoded result; requiring proof beforehand made proof
        // unobtainable without a code change. `.unavailable` stays a hard block because those
        // routes are known broken, not merely unmeasured.
        if case .unavailable(let reason) = capability.readiness { throw StudioError.validation(reason) }
        guard capability.width.contains(width), capability.height.contains(height) else {
            if capability.width == capability.height {
                throw StudioError.validation("Image dimensions must be \(capability.width.minimum)–\(capability.width.maximum) pixels in multiples of \(capability.width.multiple).")
            }
            throw StudioError.validation("Image width must be \(capability.width.summary) and height \(capability.height.summary) pixels.")
        }
        guard seed >= 0, seed <= Int(UInt32.max) else { throw StudioError.validation("Seed must be from 0 to 4294967295.") }
        if let bounds = capability.strength {
            guard bounds.contains(strength ?? ImageCapabilityRegistry.defaultStrength) else { throw StudioError.validation("Strength must be \(bounds.summary) for this recipe.") }
        }
        if let referenceCount { try validateReferenceCount(referenceCount, capability: capability) }
        return capability
    }

    static func validateReferenceCount(_ count: Int, capability: ImageCapability) throws {
        guard count >= 0 else { throw StudioError.validation("Reference image count cannot be negative.") }
        switch capability.conditioning {
        case .none:
            guard count == 0 else { throw StudioError.validation("Text to image does not accept reference images. Disconnect them to run this recipe.") }
        case .startImageStrength, .referenceImage, .maskedStartImage:
            guard count >= 1 else { throw StudioError.validation("\(capability.task.title) needs its connected Reference image.") }
            guard count <= capability.maximumReferenceImages else {
                throw StudioError.validation("\(capability.recipeID) accepts at most \(capability.maximumReferenceImages) Reference image\(capability.maximumReferenceImages == 1 ? "" : "s") in this adapter. Choose FLUX.2 Klein for up to three ordered references.")
            }
        }
    }

    /// `referenceRoles` and `connectedReferencePortIDs` are folded in here, after
    /// the capability is resolved, because only the capability knows whether this
    /// adapter indexes references positionally. Composing at this point also keeps
    /// the role text clear of the prompt compiler, which runs before this call.
    static func makeRequest(recipeID: String, task: ImageTask, prompt: String, width: Int, height: Int, seed: Int, strength: Double?, registry: [ImageCapability], allowsUnverifiedLocalRun: Bool = false, referenceCount: Int? = nil, referenceRoles: [String: String]? = nil, connectedReferencePortIDs: [String] = []) throws -> (ImageGenerationRequest, ImageCapability) {
        let capability = try validate(recipeID: recipeID, task: task, width: width, height: height, seed: seed, strength: strength, registry: registry, referenceCount: referenceCount)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.validation("Use a nonempty prompt up to 32 KB.") }
        let preamble = ReferenceRoleComposer.preamble(roles: referenceRoles, connectedPortIDs: connectedReferencePortIDs, conditioning: capability.conditioning)
        let adapterPrompt = try ReferenceRoleComposer.compose(preamble: preamble, prompt: prompt, maximumBytes: 32_768)
        try EnginePromptSyntax.validate(adapterPrompt)
        let effectiveStrength = capability.strength == nil ? nil : (strength ?? ImageCapabilityRegistry.defaultStrength)
        return (.init(task: task, recipeID: recipeID, engineBuild: capability.engineBuild, prompt: adapterPrompt, width: width, height: height, seed: seed, steps: capability.steps, cfgScale: capability.cfgScale, sampler: capability.sampler, strength: effectiveStrength, referenceRolePreamble: preamble.isEmpty ? nil : preamble, allowsUnverifiedLocalRun: allowsUnverifiedLocalRun ? true : nil), capability)
    }
}

/// Exact sd-cli argument mapping per image command profile. Pure, so it is tested without weights.
enum ImageAdapterCommand {
    static func arguments(_ request: ImageGenerationRequest, capability: ImageCapability, components: [String: URL], output: URL) throws -> [String] {
        guard request.recipeID == capability.recipeID, request.task == capability.task, request.engineBuild == capability.engineBuild else {
            throw StudioError.validation("This image request does not match its recipe adapter.")
        }
        let roles = capability.command.componentRoles
        guard roles.allSatisfy({ components[$0] != nil }) else { throw StudioError.validation("The installed recipe is missing a required component (\(roles.joined(separator: ", "))).") }
        try ImageRequestPlanner.validateReferenceCount(request.referenceImages.count, capability: capability)
        try EnginePromptSyntax.validate(request.prompt)
        var arguments = ["-M", "img_gen"]
        switch capability.command {
        case .sd15Checkpoint, .genericStableDiffusionCheckpoint:
            arguments += ["-m", components["checkpoint"]!.path]
        case .flux2Klein, .zImage:
            arguments += ["--diffusion-model", components["diffusion"]!.path, "--vae", components["vae"]!.path, "--llm", components["textEncoder"]!.path]
        case .chatGPTSubscriptionCloud:
            throw StudioError.validation("The ChatGPT subscription route has no local sd-cli command; it should never reach ImageAdapterCommand.")
        }
        arguments += ["-p", request.prompt, "-W", String(request.width), "-H", String(request.height), "--steps", String(request.steps), "--cfg-scale", String(request.cfgScale)]
        if let sampler = request.sampler { arguments += ["--sampling-method", sampler] }
        // Every pinned flux2.md example for Klein (text-to-image and reference edit alike) pairs
        // --diffusion-fa with --offload-to-cpu; omitting it deviates from the only local evidence
        // GenStudio has for this adapter's memory strategy.
        //
        // Removing --offload-to-cpu was measured on Apple M1 Max / 64 GB (18 Sep 2026) and is
        // NOT adopted. A first sequential pass suggested a 15% gain, but an A/B/A repeat showed
        // the identical configuration varying 66.02 s -> 41.24 s on Klein 9B, so run-to-run
        // thermal drift exceeds the effect. Klein 4B measured 20.07 s / 16.75 s / 17.20 s for
        // with / without / with, which is inside that noise. See
        // docs/evidence/engine-benchmark-m1max-2026-09-18.md. Revisit only with a repeated-measures
        // benchmark on a thermally settled machine.
        // The pinned z_image.md Turbo example uses the same pair.
        if capability.command == .flux2Klein || capability.command == .zImage { arguments += ["--diffusion-fa", "--offload-to-cpu"] }
        arguments += ["--seed", String(request.seed)]
        switch capability.conditioning {
        case .none: break
        case .startImageStrength:
            guard let strength = request.strength, capability.strength?.contains(strength) == true else { throw StudioError.validation("Image to image needs a strength within the recipe's bounds.") }
            guard let source = request.referenceImage else { throw StudioError.validation("Image to image needs its connected Reference image.") }
            arguments += ["-i", source.path, "--strength", String(strength)]
        case .maskedStartImage:
            guard let strength = request.strength, capability.strength?.contains(strength) == true else { throw StudioError.validation("Inpaint needs a strength within the recipe's bounds.") }
            guard let source = request.referenceImage else { throw StudioError.validation("Inpaint needs its connected Reference image.") }
            guard let mask = request.maskImage else { throw StudioError.validation("Inpaint needs a mask image.") }
            arguments += ["-i", source.path, "--mask", mask.path, "--strength", String(strength)]
        case .referenceImage:
            for reference in request.referenceImages { arguments += ["-r", reference.path] }
            if request.referenceImages.count > 1 { arguments.append("--increase-ref-index") }
        }
        arguments += ["-o", output.path]
        return arguments
    }
}
