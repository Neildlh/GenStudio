import Foundation

/// What a Hugging Face repository publishes, derived only from machine-readable metadata (tags, card
/// fields, file layout). Names and prose are never interpreted, and no repository code or weights are read.
/// Package type is independent of adult-content labels and of GenStudio compatibility.
struct ModelPackageClassification: Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        /// A standalone model whose single weight file includes everything the task needs.
        case completeModel
        /// Weight files whose required encoders/decoders are not established by metadata alone.
        case modelWeights
        /// Low-rank adapter; modifies a base model and can never generate by itself.
        case lora
        /// ControlNet, IP-Adapter, motion module or generic PEFT adapter.
        case adapter
        /// Separately published parts (VAEs, text encoders, diffusion weights) for assembly into a package.
        case components
        /// Multi-folder Diffusers pipeline layout.
        case diffusersPipeline
        case unknown

        var title: String {
            switch self {
            case .completeModel: "Complete model"
            case .modelWeights: "Model weights"
            case .lora: "LoRA adapter"
            case .adapter: "Adapter"
            case .components: "Component repository"
            case .diffusersPipeline: "Diffusers pipeline"
            case .unknown: "Package type unknown"
            }
        }
    }
    enum BaseRelation: String, Sendable { case adapter, finetune, quantized, merge }

    let kind: Kind
    /// Specific adapter family when metadata states it, e.g. "ControlNet".
    let adapterType: String?
    /// Publisher-declared base repositories (card `base_model` and `base_model:` tags), validated as owner/name.
    let baseModels: [String]
    let baseRelations: Set<BaseRelation>
    /// Publisher-declared trigger phrases (card `instance_prompt`). Shown as help, never injected automatically.
    let triggerWords: [String]
    /// Which metadata decided the classification, for display and review.
    let evidence: [String]

    var title: String { adapterType.map { "\($0) adapter" } ?? kind.title }
    /// Short plain label for chips; the technical `title` is secondary.
    var friendlyTitle: String {
        switch kind {
        case .completeModel: "Complete model"
        case .modelWeights: "Model files"
        case .lora: "Add-on · LoRA"
        case .adapter: "Add-on · \(adapterType ?? "adapter")"
        case .components: "Model part"
        case .diffusersPipeline: "Unsupported format"
        case .unknown: "Type unknown"
        }
    }
    /// Never true for adapters or component sets: they cannot generate alone.
    var isStandalone: Bool { kind == .completeModel }

    static let componentDirectories: Set<String> = [
        "vae", "text_encoder", "text_encoders", "text_encoder_2", "clip", "clip_vision", "diffusion_models", "unet", "transformer", "loras", "controlnet", "tokenizer"
    ]
    static let weightFormats: Set<String> = ["gguf", "safetensors", "ckpt", "bin", "pt", "pth"]
    static let rootLoRAFilename = "lora.safetensors"

    static func classify(model: DiscoveryModel, files: [DiscoveryFile]) -> ModelPackageClassification {
        let tags = Set(model.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let (declaredBases, relations) = declaredBaseModels(model)
        let triggers = sanitizedTriggers(model.instancePrompts ?? [])
        let paths = files.map(\.path)
        let rootFiles = Set(paths.filter { !$0.contains("/") })
        let weights = paths.filter { weightFormats.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        func result(_ kind: Kind, adapter: String? = nil, _ evidence: [String]) -> Self {
            .init(kind: kind, adapterType: adapter, baseModels: declaredBases, baseRelations: relations, triggerWords: triggers, evidence: evidence)
        }

        // Adapters first: an adapter repository may also carry a pipeline tag such as text-to-image.
        let nonAdapterRelation = !relations.isDisjoint(with: [.finetune, .quantized, .merge])
        let peftConfig = rootFiles.contains("adapter_config.json")
        // Diffusers' `save_lora_weights` writes this exact filename; it is a file-format convention, not a name guess.
        let diffusersLoRA = paths.contains { URL(fileURLWithPath: $0).lastPathComponent == "pytorch_lora_weights.safetensors" }
        if tags.contains("lora") && (relations.contains(.adapter) || !nonAdapterRelation) {
            return result(.lora, ["Publisher tag: lora"] + (relations.contains(.adapter) ? ["Declared as an adapter of its base model"] : []))
        }
        if diffusersLoRA { return result(.lora, ["Diffusers LoRA weight file"]) }
        // Hosted LoRA trainers that push to the Hub (for example Replicate's FLUX LoRA trainer) publish a single root
        // `lora.safetensors`; Heartsync/Flux-NSFW-uncensored has exactly this layout. The exact filename counts only when it is the repository's sole weight file, so a
        // full or quantized checkpoint that also ships a LoRA is not reclassified. Substrings such as `my-lora` never match.
        // Hub tooling derives `base_model:finetune:` from a card's base_model when no relation is given, so finetune alone
        // does not contradict this layout; quantized or merged releases do.
        if rootFiles.contains(Self.rootLoRAFilename), weights == [Self.rootLoRAFilename], relations.isDisjoint(with: [.quantized, .merge]) {
            return result(.lora, ["Sole root weight file named \(Self.rootLoRAFilename)"])
        }
        if peftConfig { return result(tags.contains("lora") ? .lora : .adapter, adapter: tags.contains("lora") ? nil : "PEFT", ["PEFT adapter_config.json"]) }
        for (tag, name) in [("controlnet", "ControlNet"), ("ip-adapter", "IP-Adapter"), ("t2i-adapter", "T2I-Adapter"), ("motion-module", "Motion module")] where tags.contains(tag) {
            return result(.adapter, adapter: name, ["Publisher tag: \(tag)"])
        }
        if relations.contains(.adapter) { return result(.adapter, ["Declared as an adapter of its base model"]) }

        if rootFiles.contains("model_index.json") { return result(.diffusersPipeline, ["Diffusers model_index.json"]) }
        let componentFolders = Set(weights.compactMap { path -> String? in
            let parts = path.split(separator: "/").map { String($0).lowercased() }
            return parts.dropLast().first { componentDirectories.contains($0) }
        })
        if componentFolders.count >= 1 && weights.allSatisfy({ $0.contains("/") }) {
            return result(.components, ["Weights are grouped in component folders: \(componentFolders.sorted().joined(separator: ", "))"])
        }
        guard !weights.isEmpty else { return result(.unknown, files.isEmpty ? ["No file inventory"] : ["No recognised weight files"]) }
        if model.pipelineTag == "text-generation" && weights.contains(where: { $0.lowercased().hasSuffix(".gguf") && !$0.lowercased().contains("mmproj") }) {
            return result(.completeModel, ["Text-generation GGUF"])
        }
        return result(.modelWeights, ["Weight files without a declared dependency set"])
    }

    /// A verified GenStudio recipe made entirely from this repository establishes a complete package.
    func promoted(byCompleteRecipe: Bool) -> Self {
        guard byCompleteRecipe, kind == .modelWeights || kind == .unknown else { return self }
        return .init(kind: .completeModel, adapterType: nil, baseModels: baseModels, baseRelations: baseRelations, triggerWords: triggerWords, evidence: evidence + ["Matches a verified single-repository GenStudio recipe"])
    }

    private static func declaredBaseModels(_ model: DiscoveryModel) -> ([String], Set<BaseRelation>) {
        var ids: [String] = []
        var relations = Set<BaseRelation>()
        func add(_ raw: String) {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = try? ModelLibrary.parseHubLink(id), parsed == id, !ids.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
            ids.append(id)
        }
        for tag in model.tags where tag.hasPrefix("base_model:") {
            let parts = tag.dropFirst("base_model:".count).split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let relation = BaseRelation(rawValue: parts[0]) { relations.insert(relation); add(parts[1]) }
            else if parts.count == 1 { add(parts[0]) }
        }
        for id in model.baseModels ?? [] { add(id) }
        return (Array(ids.prefix(8)), relations)
    }

    private static func sanitizedTriggers(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 200 && !$0.contains("<") }
            .prefix(8).map { $0 }
    }
}

/// Base families GenStudio can name exactly. A LoRA is only associated with a recipe when the publisher's
/// declared base repository is listed here; similar names, sizes or families are never treated as matches.
enum LoRABaseFamily: String, Sendable, CaseIterable {
    case sd15, sdxl, flux1, flux2Klein4B, wan21T2V13B, wan22TI2V5B

    var title: String {
        switch self {
        case .sd15: "Stable Diffusion 1.5"
        case .sdxl: "Stable Diffusion XL"
        case .flux1: "FLUX.1"
        case .flux2Klein4B: "FLUX.2 Klein 4B"
        case .wan21T2V13B: "Wan 2.1 T2V 1.3B"
        case .wan22TI2V5B: "Wan 2.2 TI2V 5B"
        }
    }
    var baseRepositories: [String] {
        switch self {
        case .sd15: ["stable-diffusion-v1-5/stable-diffusion-v1-5", "runwayml/stable-diffusion-v1-5"]
        case .sdxl: ["stabilityai/stable-diffusion-xl-base-1.0"]
        case .flux1: ["black-forest-labs/FLUX.1-dev", "black-forest-labs/FLUX.1-schnell"]
        case .flux2Klein4B: ["black-forest-labs/FLUX.2-klein-4B"]
        case .wan21T2V13B: ["Wan-AI/Wan2.1-T2V-1.3B", "Wan-AI/Wan2.1-T2V-1.3B-Diffusers"]
        case .wan22TI2V5B: ["Wan-AI/Wan2.2-TI2V-5B", "Wan-AI/Wan2.2-TI2V-5B-Diffusers"]
        }
    }
    /// The GenStudio recipe whose weights derive from this base, when one exists.
    var recipeID: String? {
        switch self {
        case .sd15: ImageCapabilityRegistry.sd15RecipeID
        case .flux2Klein4B: MediaModelCatalog.kleinRecipeID
        case .wan21T2V13B: VideoCapabilityRegistry.wanT2VRecipeID
        case .wan22TI2V5B: MediaModelCatalog.wan22TI2VRecipeID
        case .sdxl, .flux1: nil
        }
    }
    var mediaKind: GenerationModelKind {
        switch self {
        case .sd15, .sdxl, .flux1, .flux2Klein4B: .image
        case .wan21T2V13B, .wan22TI2V5B: .video
        }
    }
    static func family(forBase repository: String) -> LoRABaseFamily? {
        allCases.first { $0.baseRepositories.contains { $0.caseInsensitiveCompare(repository) == .orderedSame } }
    }
}

/// A GenStudio recipe that pins files from the inspected repository.
struct RecipeRepositoryReference: Sendable, Identifiable {
    var id: String { recipe.id }
    let recipe: ModelRecipe
    let roles: [String]
    /// Every file this recipe takes from the repository matches the inspected revision, path, size and SHA-256.
    let matchesInspectedRevision: Bool
    /// Every component of the recipe comes from this repository.
    let completeFromRepository: Bool

    static func references(detail: DiscoveryDetail, recipes: [ModelRecipe] = ModelCatalog.recipes) -> [RecipeRepositoryReference] {
        recipes.compactMap { recipe in
            let own = recipe.components.filter { $0.repository.caseInsensitiveCompare(detail.model.id) == .orderedSame }
            guard !own.isEmpty else { return nil }
            let exact = own.allSatisfy { component in
                component.revision == detail.model.sha && detail.files.contains { $0.path == component.filename && $0.bytes == component.byteSize && $0.sha256 == component.sha256 }
            }
            return .init(recipe: recipe, roles: own.map(\.role), matchesInspectedRevision: exact, completeFromRepository: own.count == recipe.components.count)
        }
    }
}

/// Plain-language decision guidance for a discovered package, answering five questions for a non-expert:
/// what is it, how could it help, what does it need, where would I use it, and what should I do.
/// Every statement comes from metadata or exact recipe matches; nothing is inferred from names or prose.
struct ModelPackageGuidance: Sendable {
    enum Recommendation: String, Sendable {
        case reviewRecipe, chooseTextFile, keepForLater, unsupported, unknown

        var title: String {
            switch self {
            case .reviewRecipe: "Recommended: review and install"
            case .chooseTextFile: "Recommended: choose one file below"
            case .keepForLater: "Keep for later"
            case .unsupported: "Not usable in GenStudio yet"
            case .unknown: "Not enough information"
            }
        }
        var systemImage: String {
            switch self {
            case .reviewRecipe, .chooseTextFile: "checkmark.circle"
            case .keepForLater: "bookmark"
            case .unsupported: "xmark.circle"
            case .unknown: "questionmark.circle"
            }
        }
    }

    let classification: ModelPackageClassification
    let references: [RecipeRepositoryReference]
    let baseFamilies: [LoRABaseFamily]
    /// The exact GenStudio base recipe for a LoRA/adapter's declared base, when one exists.
    let baseRecipe: ModelRecipe?
    let baseInstalled: Bool
    /// 1. One plain sentence. The technical label stays in `classification.title`.
    let whatItIs: String
    /// 2. Concrete uses established by publisher tags, task metadata or an exact recipe. May be empty.
    let benefits: [String]
    /// Always shown with benefits, so users know where the claims come from or where to look.
    let benefitsNote: String
    /// 3. Works alone, needs a base, or is one component.
    let needs: String
    /// 4. Which node, add-on placement, or not usable yet.
    let whereToUse: String
    /// 5. A single recommendation with its explanation.
    let recommendation: Recommendation
    let nextAction: String

    static func make(detail: DiscoveryDetail, recipes: [ModelRecipe] = ModelCatalog.recipes, installedIDs: Set<String> = []) -> ModelPackageGuidance {
        let references = RecipeRepositoryReference.references(detail: detail, recipes: recipes)
        let completeExact = references.contains { $0.completeFromRepository && $0.matchesInspectedRevision }
        let classification = ModelPackageClassification.classify(model: detail.model, files: detail.files).promoted(byCompleteRecipe: completeExact)
        var families: [LoRABaseFamily] = []
        for family in classification.baseModels.compactMap(LoRABaseFamily.family(forBase:)) where !families.contains(family) { families.append(family) }
        let isAddOn = classification.kind == .lora || classification.kind == .adapter
        // Only an unambiguous, exact declared base is matched.
        let family = isAddOn && families.count == 1 ? families[0] : nil
        let baseRecipe = family?.recipeID.flatMap { id in recipes.first { $0.id == id } }
        let baseInstalled = baseRecipe.map { installedIDs.contains($0.id) } ?? false
        let baseTitle = baseRecipe.map(ModelRecipePresentation.title)
        let declared = classification.baseModels.isEmpty ? nil : classification.baseModels.joined(separator: ", ")
        let names = references.map { ModelRecipePresentation.title($0.recipe) }.joined(separator: ", ")
        let recipeKinds = Set(references.map(\.recipe.kind))
        // Recipes pin exact files; a newer repository head is never substituted for them.
        let viaRecipe: String? = references.isEmpty ? nil
            : references.allSatisfy(\.matchesInspectedRevision) ? "Review \(names) below. Installing downloads only its pinned files and adds any other parts it needs."
            : "Review \(names) below. It uses specific earlier files from this repository, so installing downloads those pinned files, not necessarily this latest revision."
        let placementFromRecipes = recipeKinds.isEmpty ? nil : recipeKinds.sorted { $0.rawValue < $1.rawValue }.map(placement).joined(separator: " or ")
        let pipelineMedia: GenerationModelKind? = {
            switch detail.model.pipelineTag {
            case "text-to-image", "image-to-image": .image
            case "text-to-video", "image-to-video": .video
            default: nil
            }
        }()
        let addOnMedia = family?.mediaKind ?? pipelineMedia

        var benefits = tagBenefits(detail.model, triggers: classification.triggerWords)
        var benefitsNote = "Based on the publisher’s tags and task. Quality and results have not been checked by GenStudio."
        let whatItIs: String
        let needs: String
        var whereToUse: String
        var recommendation: Recommendation
        var next: String

        switch classification.kind {
        case .lora:
            let media = addOnMedia == .video ? "video" : addOnMedia == .image ? "image" : "image or video"
            whatItIs = "A small add-on for an existing \(media) model, not a model you can generate with on its own."
            benefitsNote = "A LoRA can teach its base model a style, subject, character, product, motion or behaviour. What this one does depends on how the publisher trained it — check their description and example images."
            if benefits.isEmpty { benefitsNote = "The publisher’s metadata does not say what this add-on changes. " + benefitsNote }
            needs = baseNeeds(declared: declared, family: families.count == 1 ? families[0] : nil, ambiguous: families.count > 1, baseTitle: baseTitle, installed: baseInstalled)
            whereToUse = addOnMedia.map { "It would attach to \(placement($0)) that uses its base model. Applying add-ons is not available in this version yet." }
                ?? "It would attach to a generator node that uses its base model. Applying add-ons is not available in this version yet."
            if let baseTitle {
                recommendation = .keepForLater
                next = baseInstalled
                    ? "You already have \(baseTitle). Applying add-ons comes in a later version, so there is nothing to install from this page yet."
                    : "Applying add-ons comes in a later version. If you want to use this one then, its base model \(baseTitle) already works on its own today — you can review and install it now."
            } else if let family = families.count == 1 ? families[0] : nil {
                recommendation = .unsupported
                next = "GenStudio has no \(family.title) base model, so this add-on can’t be used here."
            } else if declared != nil {
                recommendation = .unsupported
                next = families.count > 1 ? "The publisher lists more than one base model, so GenStudio can’t pick one safely." : "Its declared base model isn’t one GenStudio has an exact match for, so this add-on can’t be used here."
            } else {
                recommendation = .unknown
                next = "The publisher didn’t say which base model it was made for, and GenStudio will not guess. Check the model card."
            }
        case .adapter:
            whatItIs = "An add-on (\(classification.adapterType ?? "adapter")) that guides an existing model, not a model you can generate with on its own."
            needs = baseNeeds(declared: declared, family: families.count == 1 ? families[0] : nil, ambiguous: families.count > 1, baseTitle: baseTitle, installed: baseInstalled)
            if let placementFromRecipes {
                whereToUse = "Used automatically inside \(names), in \(placementFromRecipes)."
                recommendation = .reviewRecipe; next = viaRecipe!
            } else {
                whereToUse = "Can’t be used in GenStudio yet: add-ons are only used inside a verified recipe."
                recommendation = .unsupported; next = "No GenStudio recipe uses this add-on."
            }
        case .components:
            whatItIs = "One part of a model, such as a text encoder or image decoder, that must be combined with other files."
            needs = "It can’t generate on its own; it only works together with the other parts of a complete model."
            if let placementFromRecipes {
                benefits = ["Supplies part of \(names)"]
                whereToUse = "You don’t place it yourself: \(names) uses it automatically in \(placementFromRecipes)."
                recommendation = .reviewRecipe; next = viaRecipe!
            } else {
                whereToUse = "Can’t be used in GenStudio yet."
                recommendation = .unsupported; next = "No GenStudio recipe uses these files, and GenStudio never installs single parts on their own."
            }
        case .diffusersPipeline:
            whatItIs = "A model published in a multi-folder format (Diffusers) that GenStudio’s engines don’t load."
            needs = "A single-file GGUF or safetensors version of the same model, plus a GenStudio recipe for it."
            if let placementFromRecipes {
                whereToUse = "\(names) uses files from it in \(placementFromRecipes)."
                recommendation = .reviewRecipe; next = viaRecipe!
            } else {
                whereToUse = "Can’t be used in GenStudio in this format."
                recommendation = .unsupported; next = "Look for a single-file release of the same model instead. GenStudio never runs a repository’s Python code."
            }
        case .completeModel:
            if completeExact, let recipe = references.first(where: { $0.completeFromRepository && $0.matchesInspectedRevision })?.recipe {
                whatItIs = "A complete \(noun(recipe.kind)) that GenStudio can install from this repository."
                benefits = recipeBenefits(recipe) + benefits
                needs = "Works on its own; no other model files are needed."
                whereToUse = "In \(placement(recipe.kind))."
                recommendation = .reviewRecipe; next = "Review \(ModelRecipePresentation.title(recipe)) below to check memory and storage on this Mac, then install it."
            } else if !detail.experimentalTextFiles.isEmpty {
                whatItIs = "A complete text model. Each file is the same model at a different size and quality."
                if benefits.isEmpty { benefits = ["Write or rewrite text, such as prompts or captions, on this Mac"] }
                needs = "Works on its own. Choose just one of its files."
                whereToUse = "In \(placement(.text))."
                if detail.model.gated {
                    recommendation = .unsupported; next = "The publisher requires sign-in, which GenStudio doesn’t support yet."
                } else {
                    recommendation = .chooseTextFile; next = "Pick one file below. Smaller files use less memory, sometimes with lower quality. GenStudio checks the file before it can be used."
                }
            } else {
                whatItIs = "A standalone model file."
                needs = "Works on its own, according to its metadata."
                whereToUse = placementFromRecipes.map { "In \($0)." } ?? "Can’t be used in GenStudio yet."
                recommendation = references.isEmpty ? .unsupported : .reviewRecipe
                next = viaRecipe ?? "GenStudio has no engine support for this model yet."
            }
        case .modelWeights:
            whatItIs = "Model files whose full requirements aren’t stated: some work alone, others need extra parts."
            if let placementFromRecipes {
                needs = "GenStudio knows exactly what’s needed: \(names) adds any other required parts."
                whereToUse = "In \(placementFromRecipes)."
                benefits = references.flatMap { recipeBenefits($0.recipe) } + benefits
                recommendation = .reviewRecipe; next = viaRecipe!
            } else {
                needs = "Not established. It may need separate parts such as a text encoder or image decoder."
                whereToUse = "Can’t be used in GenStudio yet."
                recommendation = .unsupported; next = "No GenStudio recipe uses these files, so they can’t be installed here."
            }
        case .unknown:
            whatItIs = "GenStudio can’t tell what kind of model this is from its published information."
            needs = "Not established."
            whereToUse = placementFromRecipes.map { "In \($0)." } ?? "Can’t be used in GenStudio."
            recommendation = references.isEmpty ? .unknown : .reviewRecipe
            next = viaRecipe ?? "GenStudio won’t guess. Read the publisher’s model card for details."
        }
        var seen = Set<String>()
        benefits = benefits.filter { seen.insert($0).inserted }
        return .init(classification: classification, references: references, baseFamilies: families, baseRecipe: baseRecipe, baseInstalled: baseInstalled,
                     whatItIs: whatItIs, benefits: benefits, benefitsNote: benefitsNote, needs: needs, whereToUse: whereToUse, recommendation: recommendation, nextAction: next)
    }

    /// Exact publisher tags only. A tag the publisher chose is metadata; the repository name is not.
    static let benefitTags: [(tags: Set<String>, benefit: String)] = [
        (["style", "art-style", "styles"], "Give results a consistent visual style"),
        (["character", "characters"], "Keep a recurring character consistent"),
        (["product", "product-photography"], "Show a recurring product consistently"),
        (["photorealistic", "photorealism", "realism", "realistic"], "Push results toward photographic realism"),
        (["camera-motion", "camera-control"], "Add or control camera motion"),
        (["lcm", "lcm-lora", "turbo", "lightning", "few-step"], "Generate faster with fewer steps (usually with changed settings)"),
        (["image-editing", "instruct-pix2pix"], "Edit an existing picture")
    ]

    private static func tagBenefits(_ model: DiscoveryModel, triggers: [String]) -> [String] {
        let tags = Set(model.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var result = benefitTags.filter { !$0.tags.isDisjoint(with: tags) }.map(\.benefit)
        if tags.contains("dreambooth") && !triggers.isEmpty {
            result.append("Bring back a specific trained subject, such as a person, product or character, using its trigger words")
        }
        if model.pipelineTag == "image-to-image" { result.append("Edit an existing picture") }
        if model.pipelineTag == "image-to-video" { result.append("Animate a still image") }
        return result
    }

    private static func recipeBenefits(_ recipe: ModelRecipe) -> [String] {
        switch recipe.kind {
        case .image:
            var result = ["Create images from a written prompt"]
            if ImageCapabilityRegistry.capability(recipeID: recipe.id, task: .imageToImage) != nil { result.append("Change or edit a connected reference image") }
            return result
        case .video:
            let titles = Set(RecipeTaskStatus.statuses(recipeID: recipe.id).map(\.title))
            var result: [String] = []
            if titles.contains(VideoTask.textToVideo.title) { result.append("Create short video clips from a written prompt") }
            if titles.contains(VideoTask.imageToVideo.title) { result.append("Animate a start image") }
            return result
        case .text: return ["Write or rewrite text, such as prompts or captions, on this Mac"]
        case .vision: return ["Describe images in words"]
        case .upscaler: return ["Enlarge an existing image 2× or 4× locally"]
        case .speech: return ["Speak a script over a video in a voice you describe"]
        }
    }

    private static func baseNeeds(declared: String?, family: LoRABaseFamily?, ambiguous: Bool, baseTitle: String?, installed: Bool) -> String {
        guard let declared else { return "Needs a base model, but the publisher didn’t say which one." }
        let prefix = "Needs its base model, \(declared), as declared by the publisher."
        if ambiguous { return prefix + " More than one base is listed, so GenStudio can’t choose an exact match." }
        if let baseTitle { return prefix + " GenStudio’s exact match is \(baseTitle) — \(installed ? "already installed" : "not installed yet")." }
        if let family { return prefix + " GenStudio has no \(family.title) model." }
        return prefix + " GenStudio has no exact match for it."
    }

    static func placement(_ kind: GenerationModelKind) -> String {
        switch kind {
        case .image: "an Image Generator node"
        case .video: "a Text to Video or Image to Video node (depending on what the recipe supports)"
        case .text: "a Local Text node"
        case .vision: "an Image Describer node"
        case .upscaler: "an Image Upscale node"
        case .speech: "a Voiceover node"
        }
    }

    private static func noun(_ kind: GenerationModelKind) -> String {
        switch kind {
        case .image: "image generator"
        case .video: "video generator"
        case .text: "text model"
        case .vision: "image-description model"
        case .upscaler: "image upscaler"
        case .speech: "voice model"
        }
    }
}
