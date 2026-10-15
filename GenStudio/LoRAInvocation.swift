import Foundation

/// stable-diffusion.cpp treats `<lora:NAME:WEIGHT>` in a prompt as an instruction to load a file. Until GenStudio
/// applies add-ons through node settings, such text is refused everywhere a prompt reaches the engine.
enum EnginePromptSyntax {
    static let loRAMessage = "This prompt contains “<lora:…>” text, which image engines read as an instruction to load an add-on file. GenStudio doesn’t apply LoRA add-ons yet; when it does, you’ll choose them in the node’s settings instead of typing codes. Remove that text to run."

    static func containsLoRATag(_ text: String) -> Bool { text.range(of: "<lora:", options: .caseInsensitive) != nil }

    static func validate(_ prompts: String?...) throws {
        if prompts.contains(where: { $0.map(containsLoRATag) == true }) { throw StudioError.validation(loRAMessage) }
    }
}

/// What provenance records for each applied add-on: exact identity plus the strength used.
struct LoRAProvenance: Codable, Hashable, Sendable {
    let repository: String
    let revision: String
    let filename: String
    let sha256: String
    let strength: Double
}

/// A LoRA chosen for one node. Its base family comes from the publisher's declared base repository.
struct LoRASelection: Hashable, Sendable {
    /// Installed, checksum-verified LoRA weights owned by the model library.
    let file: URL
    let baseFamily: LoRABaseFamily
    let weight: Double
    let repository: String
    let revision: String
    /// Path of the weights inside the repository, as pinned at install.
    let filename: String
    let sha256: String
    /// Explicit off state: a switched-off add-on stays listed on the node but is not applied or recorded.
    var isEnabled = true

    var provenance: LoRAProvenance {
        .init(repository: repository, revision: revision, filename: filename, sha256: sha256, strength: weight)
    }
}

/// Rules for the future LoRA control, kept pure so the behaviour is fixed before any UI exists.
enum LoRAControlPolicy {
    /// Applies the add-on as trained. Conservative, and the value publishers' examples assume.
    static let defaultStrength = 1.0
    static let strengthRange = DoubleBounds(minimum: 0, maximum: 2)
    static let strengthHelp = "1.0 applies the add-on as its publisher trained it. Lower is subtler; higher is stronger and can distort results."
    /// Strength and more than one add-on live under Advanced at first; the basic control is on/off.
    static let strengthIsAdvanced = true
    static let multipleAddOnsAreAdvanced = true

    static func strengthDescription(_ strength: Double) -> String {
        guard strengthRange.contains(strength) else { return "Out of range" }
        if strength == 0 { return "No effect" }
        if abs(strength - defaultStrength) < 0.001 { return "As trained" }
        return strength < defaultStrength ? "Subtler" : "Stronger"
    }

    enum BaseChoice: Equatable, Sendable {
        /// Exactly one compatible base is installed: select it without asking.
        case preselect(recipeID: String)
        case choose(recipeIDs: [String])
        /// A compatible base exists in GenStudio but is not installed.
        case installBase(recipeID: String)
        /// No exact base in GenStudio, or the publisher declared none.
        case unavailable(reason: String)
    }

    /// Matches only the exact declared family; names and similar families are never considered.
    static func baseChoice(for family: LoRABaseFamily?, installedRecipeIDs: Set<String>) -> BaseChoice {
        guard let family else { return .unavailable(reason: "The publisher didn’t say which base model this add-on was made for, so GenStudio won’t guess.") }
        let compatible = [family.recipeID].compactMap { $0 }
        guard !compatible.isEmpty else { return .unavailable(reason: "GenStudio has no \(family.title) model to use this add-on with.") }
        let installed = compatible.filter(installedRecipeIDs.contains)
        switch installed.count {
        case 1: return .preselect(recipeID: installed[0])
        case 0: return .installBase(recipeID: compatible[0])
        default: return .choose(recipeIDs: installed)
        }
    }

    /// Plain refusal when a node's model is not the add-on's exact base; nil when compatible.
    static func incompatibility(of family: LoRABaseFamily, withRecipeID recipeID: String) -> String? {
        guard family.recipeID != recipeID else { return nil }
        let current = ModelCatalog.recipes.first { $0.id == recipeID }.map(ModelRecipePresentation.title) ?? "this model"
        return "This add-on was made for \(family.title), so it can’t be used with \(current). Choose a \(family.title) model or switch the add-on off."
    }
}

/// Execution seam for stable-diffusion.cpp LoRA support. Pure and tested, but deliberately not connected to any
/// node: LoRA packages cannot be installed yet and no LoRA/base combination has a decoded local proof.
///
/// sd-cli resolves `<lora:NAME:WEIGHT>` prompt tags to `NAME.safetensors` inside `--lora-model-dir`. GenStudio
/// hides that syntax: it links only the selected files into a private per-run directory under generated names,
/// so a prompt can never reach other files, and it rejects user-typed LoRA tags instead of passing them through.
enum LoRAInvocation {
    static let weightBounds = LoRAControlPolicy.strengthRange
    static let maximumSelections = 4

    struct Plan: Equatable, Sendable {
        /// Prompt passed to the engine, with generated tags appended.
        let prompt: String
        let arguments: [String]
        /// Files to place in `directory` before launch: selected source → generated file name.
        let links: [Link]
        /// Enabled add-ons in application order, for run provenance.
        let applied: [LoRAProvenance]
        struct Link: Equatable, Sendable { let source: URL; let name: String }
    }

    static func plan(prompt: String, baseRecipeID: String, selections: [LoRASelection], directory: URL) throws -> Plan {
        try EnginePromptSyntax.validate(prompt)
        let selections = selections.filter(\.isEnabled)
        guard !selections.isEmpty else { return .init(prompt: prompt, arguments: [], links: [], applied: []) }
        guard selections.count <= maximumSelections else { throw StudioError.validation("Use at most \(maximumSelections) add-ons in one run.") }
        guard Set(selections.map { $0.file.standardizedFileURL }).count == selections.count else { throw StudioError.validation("Each add-on can be selected once.") }
        var tags = ""
        var links: [Plan.Link] = []
        for (index, selection) in selections.enumerated() {
            if let reason = LoRAControlPolicy.incompatibility(of: selection.baseFamily, withRecipeID: baseRecipeID) {
                throw StudioError.validation(reason)
            }
            guard weightBounds.contains(selection.weight) else { throw StudioError.validation("Add-on strength must be \(weightBounds.summary). \(LoRAControlPolicy.strengthHelp)") }
            guard selection.file.isFileURL, selection.file.pathExtension.lowercased() == "safetensors" else {
                throw StudioError.validation("This add-on must be installed in the model library before it can be used.")
            }
            let name = "genstudio_lora_\(index)"
            links.append(.init(source: selection.file, name: name + ".safetensors"))
            tags += "<lora:\(name):\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), selection.weight))>"
        }
        return .init(prompt: prompt + tags, arguments: ["--lora-model-dir", directory.path], links: links, applied: selections.map(\.provenance))
    }
}
