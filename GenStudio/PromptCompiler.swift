import Foundation

/// The prompt contract understood by a destination adapter. Prompt nodes remain
/// ordinary human-authored text; this dialect is selected only after the
/// destination recipe and task have been resolved.
enum PromptDialect: String, Codable, Hashable, Sendable {
    case plainText
    case template
    case chatMessages
    case structuredJSON
    case specialTokens
    case positiveNegative
}

enum PromptCompilerTask: Codable, Hashable, Sendable {
    case text
    case image(ImageTask)
    case vision
    case video(VideoTask)

    var title: String {
        switch self {
        case .text: "text generation"
        case .image(let task): task.title
        case .vision: "image understanding"
        case .video(let task): task.title
        }
    }

    var storageKey: String {
        switch self {
        case .text: "text"
        case .image(let task): "image:\(task.rawValue)"
        case .vision: "vision"
        case .video(let task): "video:\(task.rawValue)"
        }
    }
}

struct PromptCompilerContract: Codable, Hashable, Sendable {
    let recipeID: String
    let task: PromptCompilerTask
    let dialect: PromptDialect
    let version: String
    let maximumBytes: Int
    let forbiddenTokens: [String]
    let semanticExpansion: Bool
    let templateName: String?
    let structuredRootKey: String?

    init(recipeID: String, task: PromptCompilerTask, dialect: PromptDialect, version: String = PromptCompilerRegistry.version,
         maximumBytes: Int, forbiddenTokens: [String] = ["<lora:"], semanticExpansion: Bool = false,
         templateName: String? = nil, structuredRootKey: String? = nil) {
        self.recipeID = recipeID; self.task = task; self.dialect = dialect; self.version = version
        self.maximumBytes = maximumBytes; self.forbiddenTokens = forbiddenTokens
        self.semanticExpansion = semanticExpansion; self.templateName = templateName; self.structuredRootKey = structuredRootKey
    }
}

/// Provenance for the prompt that was actually handed to a generation adapter.
struct PromptCompilation: Codable, Hashable, Sendable {
    let authoredPrompt: String
    let compiledPrompt: String
    let recipeID: String
    let task: PromptCompilerTask
    let dialect: PromptDialect
    let compilerVersion: String
    let compilerModelID: String?
    let usedFallback: Bool
}

enum PromptCompilerRegistry {
    static let version = "prompt-compiler-v1"
    static let defaultCompilerModelID = "qwen25-05b-q4km"

    /// Curated contracts are resolved from the exact adapter descriptor. A
    /// recipe with no entry for the requested task never inherits syntax by
    /// model-name or publisher resemblance.
    static func contract(recipeID: String, task: PromptCompilerTask) -> PromptCompilerContract? {
        switch task {
        case .text:
            guard let recipe = ModelCatalog.recipes.first(where: { $0.id == recipeID && $0.kind == .text && $0.runtimeReady }) else { return nil }
            return .init(recipeID: recipe.id, task: task, dialect: .plainText, maximumBytes: 32_768)
        case .image(let imageTask):
            guard let capability = ImageCapabilityRegistry.capability(recipeID: recipeID, task: imageTask) else { return nil }
            return imageContract(capability, task: task)
        case .vision:
            guard VisionModelCatalog.recipes.contains(where: { $0.id == recipeID && $0.runtimeReady }) else { return nil }
            if recipeID == "vision-smolvlm-500m-q8" {
                return .init(recipeID: recipeID, task: task, dialect: .plainText, maximumBytes: 16_384)
            }
            return .init(recipeID: recipeID, task: task, dialect: .chatMessages, maximumBytes: 16_384,
                         templateName: "vision-observation-chat-v1")
        case .video(let videoTask):
            guard VideoCapabilityRegistry.capability(recipeID: recipeID, task: videoTask) != nil else { return nil }
            if recipeID == MediaModelCatalog.lingBotRecipeID {
                return .init(recipeID: recipeID, task: task, dialect: .structuredJSON, maximumBytes: 16_384,
                             structuredRootKey: "caption")
            }
            return .init(recipeID: recipeID, task: task, dialect: .positiveNegative, maximumBytes: 16_384)
        }
    }

    /// Installed user recipes are admitted only after their runtime profile and
    /// workflow capabilities have been validated. Resolve their prompt contract
    /// from that explicit metadata, never from a guessed model family or name.
    static func contract(recipe: ModelRecipe, task: PromptCompilerTask) -> PromptCompilerContract? {
        if let curated = contract(recipeID: recipe.id, task: task) { return curated }
        switch task {
        case .text:
            let admittedGGUF = recipe.kind == .text && recipe.engineID == "llama.cpp"
                && (recipe.id.hasPrefix("text-gguf-") || recipe.baseRecipeID == "qwen25-05b-q4km")
            let mlxText = isMLXVLM(recipe) && recipe.workflowCapabilities?.contains(.textGeneration) == true
            guard admittedGGUF || mlxText else { return nil }
            return .init(recipeID: recipe.id, task: task, dialect: .plainText, maximumBytes: 32_768)
        case .image(let imageTask):
            guard let capability = ImageCapabilityRegistry.userCapability(recipe: recipe, task: imageTask) else { return nil }
            return imageContract(capability, task: task)
        case .vision:
            guard isMLXVLM(recipe), recipe.workflowCapabilities?.contains(.imageUnderstanding) == true else { return nil }
            return .init(recipeID: recipe.id, task: task, dialect: .plainText, maximumBytes: 16_384)
        case .video:
            return nil
        }
    }

    private static func imageContract(_ capability: ImageCapability, task: PromptCompilerTask) -> PromptCompilerContract {
        switch capability.command {
        case .sd15Checkpoint, .genericStableDiffusionCheckpoint:
            return .init(recipeID: capability.recipeID, task: task, dialect: .plainText, maximumBytes: 32_768)
        case .flux2Klein:
            return .init(recipeID: capability.recipeID, task: task, dialect: .template, maximumBytes: 32_768,
                         semanticExpansion: true, templateName: "flux2-klein-natural-language-v1")
        case .zImage, .chatGPTSubscriptionCloud:
            return .init(recipeID: capability.recipeID, task: task, dialect: .plainText, maximumBytes: 32_768)
        }
    }

    private static func isMLXVLM(_ recipe: ModelRecipe) -> Bool {
        recipe.kind == .vision && recipe.engineID == "mlx-vlm" && recipe.runtimeProfile == "mlx-vlm"
    }

    static func unsupportedMessage(recipeID: String, task: PromptCompilerTask) -> String {
        "No prompt compiler contract exists for recipe \(recipeID) and task \(task.title). GenStudio will not apply another recipe's prompt syntax."
    }
}

enum PromptCompiler {
    /// Compiles at the execution boundary. The optional text engine is always
    /// the installed local engine supplied by GenStudio; this layer has no
    /// network path and never calls a cloud service.
    static func compile(authoredPrompt: String, recipeID: String, task: PromptCompilerTask,
                        contract suppliedContract: PromptCompilerContract? = nil,
                        preserveAuthoredText: Bool = false,
                        installedCompilerModelIDs: Set<String> = [],
                        textEngine: (any TextGenerationEngine)? = nil) async throws -> PromptCompilation {
        guard let contract = suppliedContract ?? PromptCompilerRegistry.contract(recipeID: recipeID, task: task),
              contract.recipeID == recipeID, contract.task == task else {
            throw StudioError.validation(PromptCompilerRegistry.unsupportedMessage(recipeID: recipeID, task: task))
        }
        let authored = authoredPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authored.isEmpty else { throw StudioError.validation("The destination node needs a nonempty authored prompt.") }

        // A deterministic sheet is already model-ready prose. Keep validation
        // and provenance, but never expand it or append creative treatment.
        if preserveAuthoredText, [.plainText, .template, .positiveNegative].contains(contract.dialect) {
            let validated = try validate(authoredPrompt, contract: contract)
            return .init(authoredPrompt: authoredPrompt, compiledPrompt: validated, recipeID: recipeID, task: task,
                         dialect: contract.dialect, compilerVersion: contract.version, compilerModelID: nil, usedFallback: false)
        }

        // Valid structured input is already in the adapter's dialect. Preserve
        // bytes and whitespace exactly; this is intentionally not normalized.
        if isValidStructuredInput(authored, contract: contract) {
            try validate(authoredPrompt, contract: contract)
            return .init(authoredPrompt: authoredPrompt, compiledPrompt: authoredPrompt, recipeID: recipeID, task: task,
                         dialect: contract.dialect, compilerVersion: contract.version, compilerModelID: nil, usedFallback: false)
        }

        var compiled: String?
        var compilerModelID: String?
        var usedFallback = contract.semanticExpansion
        if contract.semanticExpansion, let textEngine, installedCompilerModelIDs.contains(PromptCompilerRegistry.defaultCompilerModelID) {
            let instruction = semanticInstruction(authoredPrompt: authored, contract: contract)
            do {
                let candidate = try await textEngine.generate(prompt: instruction, model: PromptCompilerRegistry.defaultCompilerModelID,
                                                              temperature: 0.2, maxTokens: 768, timeout: .seconds(180))
                if let normalized = normalize(candidate, contract: contract), (try? validate(normalized, contract: contract)) != nil {
                    compiled = normalized; compilerModelID = PromptCompilerRegistry.defaultCompilerModelID; usedFallback = false
                }
            } catch {
                // The deterministic formatter below is the supported offline
                // behavior for compiler model failure.
            }
        }
        if compiled == nil {
            compiled = try deterministicFormat(authored, contract: contract)
        }
        let result = try validate(compiled!, contract: contract)
        return .init(authoredPrompt: authoredPrompt, compiledPrompt: result, recipeID: recipeID, task: task,
                     dialect: contract.dialect, compilerVersion: contract.version, compilerModelID: compilerModelID, usedFallback: usedFallback)
    }

    private static func semanticInstruction(authoredPrompt: String, contract: PromptCompilerContract) -> String {
        """
        You are GenStudio's offline prompt compiler. Expand the human-authored request into the exact \(contract.templateName ?? contract.dialect.rawValue) dialect for recipe \(contract.recipeID). Preserve the user's subjects, actions, constraints and uncertainty. Return only the compiled prompt, with no markdown, labels, or explanation. Do not add LoRA tags or engine-specific syntax.
        User prompt:
        \(authoredPrompt)
        """
    }

    private static func deterministicFormat(_ authored: String, contract: PromptCompilerContract) throws -> String {
        switch contract.dialect {
        case .plainText, .positiveNegative:
            return authored
        case .template:
            return "Subject and intent: \(authored)\nVisual treatment: preserve the requested composition, lighting, color and style; add detail only where it is implied by the authored request."
        case .chatMessages:
            return "Observe the supplied image carefully. Separate visible observations from estimates and proposed changes.\n\nUser request:\n\(authored)"
        case .specialTokens:
            return "<|user|>\n\(authored)\n<|assistant|>"
        case .structuredJSON:
            guard let root = contract.structuredRootKey else { throw StudioError.validation("Structured prompt contract for \(contract.recipeID) has no schema root.") }
            let value: [String: Any] = [root: ["comprehensive_description": authored, "camera_info": [:], "world_knowledge": [], "prominent_elements": []]]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            guard let json = String(data: data, encoding: .utf8) else { throw StudioError.validation("The compiled structured prompt is not valid UTF-8.") }
            return json
        }
    }

    private static func normalize(_ candidate: String, contract: PromptCompilerContract) -> String? {
        var text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 { text = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return text.isEmpty ? nil : text
    }

    private static func isValidStructuredInput(_ text: String, contract: PromptCompilerContract) -> Bool {
        guard contract.dialect == .structuredJSON,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = contract.structuredRootKey else { return false }
        return object[key] != nil
    }

    @discardableResult
    private static func validate(_ text: String, contract: PromptCompilerContract) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.validation("The compiled prompt is empty for recipe \(contract.recipeID).") }
        guard text.utf8.count <= contract.maximumBytes else { throw StudioError.validation("The compiled prompt for recipe \(contract.recipeID) exceeds the \(contract.maximumBytes)-byte safety limit.") }
        let lower = text.lowercased()
        if let forbidden = contract.forbiddenTokens.first(where: { lower.contains($0.lowercased()) }) {
            throw StudioError.validation("The compiled prompt for recipe \(contract.recipeID) contains forbidden token \(forbidden).")
        }
        if contract.dialect == .structuredJSON {
            guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let root = contract.structuredRootKey, object[root] != nil else {
                throw StudioError.validation("The compiled prompt for recipe \(contract.recipeID) is not valid structured JSON for its task.")
            }
        }
        return text
    }
}
