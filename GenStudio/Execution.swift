import Foundation

struct ExecutionResult: Sendable {
    let values: [PortAddress: RuntimeValue]
    let run: RunRecord?
    let textOutput: TextOutput?
}

actor ExecutionQueue {
    /// Mutable outputs for one workflow run. Keeping lookup and mutation in a
    /// concrete value removes the nested-function capture that Swift 6.4 treats
    /// as a potentially transferred actor-isolated region.
    private struct ExecutionValueStore {
        let edges: [StudioEdge]
        private(set) var values: [PortAddress: RuntimeValue] = [:]

        func input(_ node: StudioNode, _ portID: String) throws -> RuntimeValue? {
            guard let edge = edges.first(where: { $0.targetID == node.id && $0.targetPortID == portID }) else { return nil }
            guard let value = values[.init(nodeID: edge.sourceID, portID: edge.sourcePortID)] else {
                throw StudioError.validation("Upstream output \(edge.sourcePortID) is unavailable for \(node.label).")
            }
            return value
        }

        func required(_ node: StudioNode, _ portID: String) throws -> RuntimeValue {
            guard let value = try input(node, portID) else { throw StudioError.validation("\(node.label) has no value for \(portID).") }
            return value
        }

        /// A value produced earlier in this run that no wire in the run carries, such as the
        /// picture a Prompt Enhancer's destination receives.
        func value(at address: PortAddress) -> RuntimeValue? { values[address] }

        mutating func emit(_ node: StudioNode, _ port: String, _ value: RuntimeValue) {
            values[.init(nodeID: node.id, portID: port)] = value
        }
    }

    private struct CachedExecutionOutputs: Sendable {
        var values: [PortAddress: RuntimeValue] = [:]
        var provenance: [UUID: RenderedMediaProvenance] = [:]
    }

    private let engine: any TextGenerationEngine
    private let imageEngine: (any ImageGenerationEngine)?
    private let visionEngine: (any VisionGenerationEngine)?
    private let upscaleEngine: (any ImageUpscaleEngine)?
    private let speechEngine: (any SpeechGenerationEngine)?
    private let videoRunner: VideoNodeRunner
    private let persistence: StudioPersistence
    private let validator: GraphValidator
    private let media: MediaProcessor
    private var busy = false

    private let imageCapabilities: [ImageCapability]
    private let upscaleCapabilities: [UpscaleCapability]

    init(engine: any TextGenerationEngine, persistence: StudioPersistence, imageEngine: (any ImageGenerationEngine)? = nil, visionEngine: (any VisionGenerationEngine)? = nil, videoEngine: (any VideoGenerationEngine)? = nil, upscaleEngine: (any ImageUpscaleEngine)? = nil, speechEngine: (any SpeechGenerationEngine)? = nil, videoCapabilities: [VideoCapability] = VideoCapabilityRegistry.shipped, imageCapabilities: [ImageCapability] = ImageCapabilityRegistry.shipped, upscaleCapabilities: [UpscaleCapability] = UpscaleCapabilityRegistry.shipped) {
        self.speechEngine = speechEngine
        self.engine = engine; self.imageEngine = imageEngine; self.visionEngine = visionEngine; self.upscaleEngine = upscaleEngine; self.persistence = persistence; media = MediaProcessor(root: persistence.root)
        self.imageCapabilities = imageCapabilities; self.upscaleCapabilities = upscaleCapabilities
        validator = GraphValidator(videoCapabilities: videoCapabilities, imageCapabilities: imageCapabilities, upscaleCapabilities: upscaleCapabilities)
        videoRunner = VideoNodeRunner(media: media, persistence: persistence, engine: videoEngine, capabilities: videoCapabilities)
    }

    /// Use only GenStudio's installed local baseline text model. A compiler failure never blocks
    /// video generation: the adapter's deterministic schema formatter remains the offline fallback.
    private func compileVideoPrompt(_ prompt: String, node: StudioNode, task: VideoTask, installedModels: Set<String>) async -> (text: String?, modelID: String?) {
        guard node.model == MediaModelCatalog.lingBotRecipeID else { return (nil, nil) }
        if let authored = LingBotPromptFormatter.validatedCaption(from: prompt) { return (authored, nil) }
        // The compiler text model cannot see the connected start image. Asking it to expand an
        // image-conditioned instruction makes it invent appearance, lens and composition details
        // which can contradict the actual first frame. Let LingBotPromptFormatter wrap the user's
        // motion instruction with an explicit preserve-the-source contract instead.
        if task == .imageToVideo { return (nil, nil) }
        let compilerModelID = "qwen25-05b-q4km"
        guard installedModels.contains(compilerModelID) else { return (nil, nil) }
        let sourceRule = task == .imageToVideo
            ? "The video has a supplied first frame. Preserve its subject identity, composition, lighting, colors and style; describe only plausible motion and camera behavior."
            : "Describe the subject, setting, action, camera, composition and lighting without changing the user's intent."
        let instruction = """
        Convert the user's simple video instruction into the LingBot-Video caption JSON contract. Return JSON only—no markdown and no commentary.
        Required shape: {"caption":{"comprehensive_description":"...","camera_info":{"color":"...","frame_size":"...","shot_type_angle":"...","lens_size":"...","composition":"...","lighting":"...","lighting_type":"..."},"world_knowledge":[],"prominent_elements":[]}}
        \(sourceRule)
        User instruction: \(prompt)
        """
        do {
            let response = try await engine.generate(prompt: instruction, model: compilerModelID, temperature: 0.2, maxTokens: 1024, timeout: .seconds(180))
            guard let validated = LingBotPromptFormatter.validatedCaption(from: response) else { return (nil, nil) }
            return (validated, compilerModelID)
        } catch {
            return (nil, nil)
        }
    }

    /// Installed local recipes use the shared compiler registry. A nil result
    /// is retained only for legacy test/external engines that provide no recipe
    /// metadata; a real library snapshot fails clearly for an unsupported
    /// recipe instead of borrowing another recipe's dialect.
    private func compilePromptIfRegistered(_ authoredPrompt: String, recipeID: String, task: PromptCompilerTask,
                                           installedModels: Set<String>, installedGenerationModels: [InstalledGenerationModel]?, preserveAuthoredText: Bool = false) async throws -> PromptCompilation? {
        let installedRecipe = installedGenerationModels?.first(where: { $0.id == recipeID && $0.available })?.recipeSnapshot
        guard let contract = PromptCompilerRegistry.contract(recipeID: recipeID, task: task)
                ?? installedRecipe.flatMap({ PromptCompilerRegistry.contract(recipe: $0, task: task) }) else {
            // External text engines are intentionally outside the generation
            // recipe catalog. They already receive plain text and must not be
            // forced through a local recipe contract.
            if case .text = task, installedModels.contains(recipeID) { return nil }
            if installedGenerationModels != nil {
                throw StudioError.validation(PromptCompilerRegistry.unsupportedMessage(recipeID: recipeID, task: task))
            }
            return nil
        }
        return try await PromptCompiler.compile(authoredPrompt: authoredPrompt, recipeID: recipeID, task: task,
                                                contract: contract, preserveAuthoredText: preserveAuthoredText,
                                                installedCompilerModelIDs: installedModels, textEngine: engine)
    }

    private func apply(_ compilation: PromptCompilation, to snapshot: inout RunInputSnapshot) {
        snapshot.authoredPrompt = compilation.authoredPrompt
        snapshot.compiledPrompt = compilation.compiledPrompt
        snapshot.promptCompilerRecipeID = compilation.recipeID
        snapshot.promptCompilerTask = compilation.task.storageKey
        snapshot.promptCompilerDialect = compilation.dialect
        snapshot.promptCompilerVersion = compilation.compilerVersion
        snapshot.promptCompilerModelID = compilation.compilerModelID
        snapshot.promptCompilerUsedFallback = compilation.usedFallback
    }

    /// Everything a Prompt Enhancer run needs, worked out before deciding whether to reuse an earlier one.
    private struct PreparedEnhancement {
        let roughPrompt: String
        let instruction: String
        /// The pictures the model will see; empty when the chosen model cannot see pictures.
        let images: [URL]
        let fingerprint: String
    }

    private func prepareEnhancement(_ node: StudioNode, snapshot: WorkflowProject, context: [PromptEnhancerContextSource], valueStore: ExecutionValueStore, installedGenerationModels: [InstalledGenerationModel]?) async throws -> PreparedEnhancement {
        guard case .text(let rough) = try valueStore.required(node, PromptEnhancer.roughPromptPortID) else {
            throw StudioError.validation("\(node.label) needs text on its Rough Prompt input.")
        }
        let roughPrompt = rough.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roughPrompt.isEmpty else { throw StudioError.validation("\(node.label) needs a rough prompt to improve. Write one in the connected Prompt node.") }
        let destination = PromptEnhancer.destinations(of: node.id, in: snapshot).first
        let target = node.promptEnhancerTarget ?? destination?.target ?? .general
        var pictures: [(url: URL, role: String)] = []
        if let value = try valueStore.input(node, PromptEnhancer.imagePortID) {
            guard case .image(let url) = value else { throw StudioError.validation("\(node.label) accepts an image on its Image input.") }
            pictures = [(url, "the picture connected to this prompt for reference")]
        } else if destination?.target == target {
            for source in context {
                if case .image(let url)? = valueStore.value(at: .init(nodeID: source.sourceID, portID: source.sourcePortID)) { pictures.append((url, source.role)) }
            }
        }
        if visionEngine == nil || !Self.canSeePictures(node.model, installedGenerationModels: installedGenerationModels) { pictures = [] }
        let modelName = destination.flatMap { destination in installedGenerationModels?.first(where: { $0.id == destination.modelID })?.name }
        let instruction = PromptEnhancer.instruction(roughPrompt: roughPrompt, target: target, destination: destination?.target == target ? destination : nil,
                                                     modelName: destination?.target == target ? modelName : nil, imageRoles: pictures.map(\.role))
        let fingerprint = try PromptEnhancer.fingerprint(roughPrompt: roughPrompt, node: node, target: target, destination: destination, images: pictures.map(\.url))
        return .init(roughPrompt: roughPrompt, instruction: instruction, images: pictures.map(\.url), fingerprint: fingerprint)
    }

    /// True when the chosen model reads pictures as well as text (Qwen3.8 MLX does; a GGUF text model does not).
    static func canSeePictures(_ modelID: String, installedGenerationModels: [InstalledGenerationModel]?) -> Bool {
        if let match = installedGenerationModels?.first(where: { $0.id == modelID }) { return NodeModelCompatibility.supports(match, kind: .vision) }
        return MLXVLMModelCatalog.supportsRecipe(modelID) || VisionModelCatalog.recipes.contains { $0.id == modelID }
    }

    /// The text of the latest successful enhancement made from exactly these inputs, if any.
    private func previousEnhancement(nodeID: UUID, projectID: UUID, fingerprint: String) async -> String? {
        guard let runs = try? await persistence.loadRuns(recoverInterrupted: false) else { return nil }
        let matches = runs.filter { $0.status == .succeeded && $0.snapshot.nodeID == nodeID && $0.snapshot.projectID == projectID && $0.snapshot.promptEnhancerFingerprint == fingerprint && $0.outputID != nil }
        guard let latest = matches.max(by: { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }),
              let outputs = try? await persistence.loadOutputs(),
              let text = outputs.first(where: { $0.id == latest.outputID })?.text, !text.isEmpty else { return nil }
        return text
    }

    private static func isGenerative(_ kind: NodeKind) -> Bool {
        switch kind {
        case .textModel, .imageGenerator, .imageUpscale, .imageDescriber, .frameInterpolate, .videoUpscale, .instagramExport:
            return true
        default:
            return kind.videoTask != nil
        }
    }

    private static func canReuse(_ value: RuntimeValue) -> Bool {
        switch value {
        case .image(let url), .video(let url):
            return FileManager.default.fileExists(atPath: url.path)
        case .text, .textArray, .number, .shotSequence:
            return true
        }
    }

    private func cachedOutputs(for graph: WorkflowProject, targetID: UUID) async -> CachedExecutionOutputs {
        guard let artifacts = try? await persistence.loadExecutionArtifacts() else { return .init() }
        let generated = graph.nodes.filter { $0.id != targetID && Self.isGenerative($0.kind) }
        guard !generated.isEmpty else { return .init() }

        var result = CachedExecutionOutputs()
        let candidates = artifacts.filter { $0.projectID == graph.id }.sorted { $0.createdAt > $1.createdAt }
        for artifact in candidates {
            for node in generated {
                guard let port = node.outputPorts.first,
                      result.values[.init(nodeID: node.id, portID: port.id)] == nil,
                      let value = artifact.values[.init(nodeID: node.id, portID: port.id)],
                      Self.canReuse(value) else { continue }
                result.values[.init(nodeID: node.id, portID: port.id)] = value
                if let media = artifact.mediaProvenance?[node.id] { result.provenance[node.id] = media }
            }
        }
        return result
    }

    func run(project: WorkflowProject, targetID: UUID, installedModels: Set<String>) async throws -> (RunRecord, TextOutput) {
        let result = try await execute(project: project, targetID: targetID, installedModels: installedModels)
        guard let run = result.run, let output = result.textOutput else { throw StudioError.validation("Select a Local Text node to use text-run history.") }
        return (run, output)
    }

    func execute(project snapshot: WorkflowProject, targetID: UUID, installedModels: Set<String> = [], installedGenerationModels: [InstalledGenerationModel]? = nil, selectedTakes: [UUID: ExecutionArtifact] = [:], upstreamValues: [PortAddress: RuntimeValue] = [:], cloudSignedIn: Bool = false, onEvent: @escaping @Sendable (NodeExecutionEvent) async -> Void = { _ in }) async throws -> ExecutionResult {
        guard !busy else { throw StudioError.validation("Another inference is already running. Cancel it or wait for it to finish.") }
        busy = true; defer { busy = false }
        guard snapshot.nodes.contains(where: { $0.id == targetID }) else { throw StudioError.validation("The selected node no longer exists.") }
        // A successful generated take is an explicit workflow input. Running a
        // downstream node must not replace that chosen image/video with a new draw.
        let reusable = selectedTakes.filter { id, artifact in
            guard id != targetID, artifact.projectID == snapshot.id,
                  let node = snapshot.nodes.first(where: { $0.id == id }), node.supportsTakes,
                  let port = node.outputPorts.first,
                  let value = artifact.values[.init(nodeID: id, portID: port.id)] else { return false }
            switch value {
            case .image(let url), .video(let url): return FileManager.default.fileExists(atPath: url.path)
            default: return false
            }
        }
        // A displayed generative result is an explicit boundary in a node-level run. Its own
        // dependencies are irrelevant until that generative node itself is run again. Without
        // this cut, running an upscaler could fail on a stale model selected several nodes behind
        // an already-rendered image even though that image is the input actually being upscaled.
        // A Prompt Enhancer also looks at the pictures its destination receives. Those sources run
        // before it and join its dependencies, although no wire connects them to it.
        let enhancerContext = Dictionary(snapshot.nodes.filter { $0.kind == .promptEnhancer }.map { ($0.id, PromptEnhancer.contextSources(of: $0.id, in: snapshot)) }, uniquingKeysWith: { first, _ in first })
        let enhancerContextPorts = enhancerContext.values.flatMap { $0 }.reduce(into: [UUID: Set<String>]()) { $0[$1.sourceID, default: []].insert($1.sourcePortID) }
        let reusableValueNodes = Set(snapshot.nodes.compactMap { node -> UUID? in
            guard node.id != targetID, Self.isGenerative(node.kind) else { return nil }
            let requiredOutputs = Set(snapshot.edges.filter { $0.sourceID == node.id }.map(\.sourcePortID))
                .union(enhancerContextPorts[node.id, default: []])
            guard !requiredOutputs.isEmpty,
                  requiredOutputs.allSatisfy({ upstreamValues[.init(nodeID: node.id, portID: $0)] != nil }) else { return nil }
            return node.id
        })
        let dependencyBoundaries = reusableValueNodes.union(reusable.keys)
        var ancestors: Set<UUID> = [targetID], frontier = [targetID]
        while let id = frontier.popLast() {
            guard !dependencyBoundaries.contains(id) else { continue }
            let contextSources = enhancerContext[id, default: []].map(\.sourceID)
            for source in snapshot.edges.filter({ $0.targetID == id }).map(\.sourceID) + contextSources where ancestors.insert(source).inserted { frontier.append(source) }
        }
        try validator.validateEdgesAttached(to: ancestors, in: snapshot)
        let graph = GenerationSeedPolicy.resolved(WorkflowProject(id: snapshot.id, name: snapshot.name, nodes: snapshot.nodes.filter { ancestors.contains($0.id) }, edges: snapshot.edges.filter { ancestors.contains($0.sourceID) && ancestors.contains($0.targetID) }, viewport: snapshot.viewport, createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt))
        let runtimeImageCapabilities = ImageCapabilityRegistry.runtimeRegistry(base: imageCapabilities, installed: installedGenerationModels)
        let cached = await cachedOutputs(for: graph, targetID: targetID)
        let reusableNodeIDs = reusableValueNodes.union(reusable.keys).intersection(ancestors)
        let order = try validator.validate(graph, installedModels: installedModels.isEmpty ? nil : installedModels, installedGenerationModels: installedGenerationModels, reusableNodeIDs: reusableNodeIDs, cloudSignedIn: cloudSignedIn, orderingDependencies: PromptEnhancer.orderingDependencies(in: snapshot))
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let edges = try graph.edges.map { try validator.resolved($0, nodes: nodes) }
        var valueStore = ExecutionValueStore(edges: edges)
        var finalRun: RunRecord?, finalText: TextOutput?
        var provenance: [UUID: RenderedMediaProvenance] = [:]

        for id in order {
            try Task.checkCancellation(); guard let node = nodes[id] else { continue }
            // A node-level run consumes the values already shown on connected upstream
            // nodes. It must never turn into an implicit rerun of those nodes. The target
            // is deliberately excluded by the caller so clicking it still makes a new take.
            let requiredOutputIDs = Set(edges.filter { $0.sourceID == id }.map(\.sourcePortID)).union(enhancerContextPorts[id, default: []])
            let pinned = Dictionary(uniqueKeysWithValues: node.outputPorts.compactMap { port in
                upstreamValues[.init(nodeID: id, portID: port.id)].map { (port.id, $0) }
            })
            if id != targetID, Self.isGenerative(node.kind), !requiredOutputIDs.isEmpty, requiredOutputIDs.isSubset(of: Set(pinned.keys)) {
                for (portID, value) in pinned { valueStore.emit(node, portID, value) }
                await onEvent(.skipped(id))
                continue
            }
            if let take = reusable[id], let port = node.outputPorts.first,
               let value = take.values[.init(nodeID: id, portID: port.id)] {
                valueStore.emit(node, port.id, value)
                provenance[id] = take.mediaProvenance?[id]
                await onEvent(.skipped(id))
                continue
            }
            if let port = node.outputPorts.first,
               let value = cached.values[.init(nodeID: id, portID: port.id)] {
                valueStore.emit(node, port.id, value)
                provenance[id] = cached.provenance[id]
                await onEvent(.skipped(id))
                continue
            }
            var enhancement: PreparedEnhancement?
            if node.kind == .promptEnhancer {
                let prepared = try await prepareEnhancement(node, snapshot: snapshot, context: enhancerContext[id, default: []], valueStore: valueStore, installedGenerationModels: installedGenerationModels)
                // Running the enhancer itself always writes a new version; anything downstream reuses
                // the latest one made from exactly these inputs.
                if id != targetID, let earlier = await previousEnhancement(nodeID: id, projectID: graph.id, fingerprint: prepared.fingerprint) {
                    valueStore.emit(node, PromptEnhancer.outputPortID, .text(earlier))
                    await onEvent(.skipped(id))
                    continue
                }
                enhancement = prepared
            }
            await onEvent(.started(id))
            switch node.kind {
            case .prompt: valueStore.emit(node, "text", .text(node.prompt))
            case .characterSheet: valueStore.emit(node, "text", .text(node.characterSheetBrief))
            case .imagePrompt:
                let prompt = node.imagePromptSettings?.compiledPrompt ?? ""
                guard !prompt.isEmpty else { throw StudioError.validation("\(node.label) needs a subject before it can create an image prompt.") }
                valueStore.emit(node, "text", .text(prompt))
            case .videoPrompt:
                let prompt = node.videoPromptSettings?.compiledPrompt ?? ""
                guard !prompt.isEmpty else { throw StudioError.validation("\(node.label) needs an action before it can create a video prompt.") }
                valueStore.emit(node, "prompt", .text(prompt))
                valueStore.emit(node, "avoid", .text(node.videoPromptSettings?.avoid.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""))
            case .textArray:
                guard case .text(let text) = try valueStore.required(node, "text") else { throw StudioError.validation("Text Array requires text.") }
                valueStore.emit(node, "items", .textArray(try TextArrayOperations.split(text, delimiter: node.arrayDelimiter, trim: node.arrayTrim)))
            case .listSelect:
                guard case .textArray(let items) = try valueStore.required(node, "items") else { throw StudioError.validation("List Select requires a text array.") }
                guard node.listIndex >= 1, node.listIndex <= items.count else { throw StudioError.validation("List Select item \(node.listIndex) is out of range for \(items.count) items. Indexes start at 1.") }
                valueStore.emit(node, "text", .text(items[node.listIndex - 1]))
            case .imageRotateFlip, .imageBlur, .imageInvert:
                guard case .image(let url) = try valueStore.required(node, "image") else { throw StudioError.validation("Image editing requires an image.") }
                let output: URL
                switch node.kind {
                case .imageRotateFlip: output = try await media.rotateFlip(url, quarterTurns: node.quarterTurns, horizontal: node.flipHorizontal, vertical: node.flipVertical)
                case .imageBlur: output = try await media.blur(url, radius: node.blurRadius)
                default: output = try await media.invert(url)
                }
                valueStore.emit(node, "image", .image(output))
            case .number: valueStore.emit(node, "number", .number(node.numberValue))
            case .numberToText:
                guard case .number(let value) = try valueStore.required(node, "text") else { throw StudioError.validation("Number to Text received the wrong value type.") }
                valueStore.emit(node, "text", .text(NumberText.string(value)))
            case .combineText:
                var parts: [String] = []
                for port in node.inputPorts {
                    guard let value = try valueStore.input(node, port.id) else { continue }
                    guard case .text(let text) = value else { throw StudioError.validation("Combine Text accepts text only.") }
                    // An optional upstream (for example Video Prompt's Avoid) can legitimately be empty; a blank part would only leave a stray separator.
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(text) }
                }
                valueStore.emit(node, "text", .text(parts.joined(separator: TextEscapes.unescape(node.separator))))
            case .promptTemplate:
                if let issue = PromptTemplateSyntax.issue(for: node, connectedPorts: Set(edges.filter { $0.targetID == node.id }.map(\.targetPortID))) { throw StudioError.validation(issue) }
                var substitutions: [String: String] = [:]
                for port in node.inputPorts { if let value = try valueStore.input(node, port.id), case .text(let text) = value { substitutions[port.label] = text } }
                valueStore.emit(node, "text", .text(try PromptTemplateSyntax.render(node.prompt, values: substitutions, label: node.label)))
            case .textModel:
                guard case .text(let prompt) = try valueStore.required(node, "prompt") else { throw StudioError.validation("Local Text requires text.") }
                let modelRecipe = installedGenerationModels?.first(where: { $0.id == node.model })?.recipeSnapshot
                    ?? ModelCatalog.recipes.first(where: { $0.id == node.model })
                let compilation = try await compilePromptIfRegistered(prompt, recipeID: node.model, task: .text,
                                                                      installedModels: installedModels, installedGenerationModels: installedGenerationModels)
                let adapterPrompt = compilation?.compiledPrompt ?? prompt
                var textSnapshot = RunInputSnapshot(projectID: graph.id, nodeID: node.id, prompt: prompt, model: node.model,
                                                    temperature: node.temperature, maxTokens: node.maxTokens,
                                                    engineID: modelRecipe?.engineID, modelRecipe: modelRecipe)
                if let compilation { apply(compilation, to: &textSnapshot) }
                var run = RunRecord(id: UUID(), snapshot: textSnapshot, status: .queued, queuedAt: Date())
                try await persistence.saveRun(run)
                do {
                    run.status = .running; run.startedAt = Date(); try await persistence.saveRun(run)
                    let text = try await GenerationProgressContext.$report.withValue({ update in Task { await onEvent(.progress(id, update)) } }) {
                        try await engine.generate(prompt: adapterPrompt, model: node.model, temperature: node.temperature, maxTokens: node.maxTokens, timeout: .seconds(3600))
                    }; try Task.checkCancellation()
                    let output = TextOutput(id: UUID(), runID: run.id, projectID: graph.id, nodeID: node.id, prompt: prompt, model: node.model, text: text, createdAt: Date())
                    try await persistence.saveOutput(output); run.status = .succeeded; run.finishedAt = Date(); run.outputID = output.id; try await persistence.saveRun(run)
                    valueStore.emit(node, "text", .text(text)); if node.id == targetID { finalRun = run; finalText = output }
                } catch {
                    run.status = error is CancellationError ? .cancelled : .failed; run.finishedAt = Date(); run.error = error is CancellationError ? "Cancelled by user." : error.localizedDescription; try? await persistence.saveRun(run); throw error
                }
            case .promptEnhancer:
                guard let enhancement else { throw StudioError.validation("\(node.label) could not prepare its prompt.") }
                let modelRecipe = installedGenerationModels?.first(where: { $0.id == node.model })?.recipeSnapshot
                    ?? ModelCatalog.recipes.first(where: { $0.id == node.model })
                var enhancerSnapshot = RunInputSnapshot(projectID: graph.id, nodeID: node.id, prompt: enhancement.roughPrompt, model: node.model,
                                                        temperature: node.temperature, maxTokens: node.maxTokens,
                                                        engineID: modelRecipe?.engineID, modelRecipe: modelRecipe)
                enhancerSnapshot.authoredPrompt = enhancement.roughPrompt
                enhancerSnapshot.compiledPrompt = enhancement.instruction
                enhancerSnapshot.promptEnhancerFingerprint = enhancement.fingerprint
                var run = RunRecord(id: UUID(), snapshot: enhancerSnapshot, status: .queued, queuedAt: Date())
                try await persistence.saveRun(run)
                do {
                    run.status = .running; run.startedAt = Date(); try await persistence.saveRun(run)
                    for url in enhancement.images { _ = try await media.validateImage(url) }
                    let raw = try await GenerationProgressContext.$report.withValue({ update in Task { await onEvent(.progress(id, update)) } }) {
                        if let visionEngine, !enhancement.images.isEmpty {
                            try await visionEngine.describe(images: enhancement.images, prompt: enhancement.instruction, model: node.model, temperature: node.temperature, maxTokens: node.maxTokens, timeout: .seconds(1800))
                        } else {
                            try await engine.generate(prompt: enhancement.instruction, model: node.model, temperature: node.temperature, maxTokens: node.maxTokens, timeout: .seconds(1800))
                        }
                    }
                    try Task.checkCancellation()
                    let text = PromptEnhancer.clean(raw)
                    guard !text.isEmpty else { throw StudioError.emptyResponse }
                    let output = TextOutput(id: UUID(), runID: run.id, projectID: graph.id, nodeID: node.id, prompt: enhancement.roughPrompt, model: node.model, text: text, createdAt: Date())
                    try await persistence.saveOutput(output)
                    run.status = .succeeded; run.finishedAt = Date(); run.outputID = output.id; try await persistence.saveRun(run)
                    valueStore.emit(node, PromptEnhancer.outputPortID, .text(text)); if node.id == targetID { finalRun = run; finalText = output }
                } catch {
                    run.status = error is CancellationError ? .cancelled : .failed; run.finishedAt = Date(); run.error = error is CancellationError ? "Cancelled by user." : error.localizedDescription; try? await persistence.saveRun(run); throw error
                }
            case .imageDescriber:
                guard let visionEngine else { throw StudioError.validation("No bundled vision engine is available for \(node.kind.title).") }
                var images: [URL] = []
                for port in node.inputPorts where port.type == .image {
                    guard case .image(let url) = try valueStore.required(node, port.id) else { throw StudioError.validation("\(node.kind.title) requires image values.") }
                    images.append(url)
                }
                guard !images.isEmpty else { throw StudioError.validation("\(node.kind.title) needs at least one image.") }
                for url in images { _ = try await media.validateImage(url) }
                let instructions = node.prompt
                let modelRecipe = installedGenerationModels?.first(where: { $0.id == node.model })?.recipeSnapshot
                    ?? ModelCatalog.recipes.first(where: { $0.id == node.model })
                guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.validation("\(node.kind.title) needs instructions.") }
                let compilation = try await compilePromptIfRegistered(instructions, recipeID: node.model, task: .vision,
                                                                      installedModels: installedModels, installedGenerationModels: installedGenerationModels)
                let adapterPrompt = compilation?.compiledPrompt ?? instructions
                var visionSnapshot = RunInputSnapshot(projectID: graph.id, nodeID: node.id, prompt: instructions, model: node.model,
                                                       temperature: node.temperature, maxTokens: node.maxTokens,
                                                       engineID: modelRecipe?.engineID, modelRecipe: modelRecipe)
                if let compilation { apply(compilation, to: &visionSnapshot) }
                var run = RunRecord(id: UUID(), snapshot: visionSnapshot, status: .queued, queuedAt: Date())
                try await persistence.saveRun(run)
                do {
                    run.status = .running; run.startedAt = Date(); try await persistence.saveRun(run)
                    let observedText = try await GenerationProgressContext.$report.withValue({ update in Task { await onEvent(.progress(id, update)) } }) {
                        try await visionEngine.describe(images: images, prompt: adapterPrompt, model: node.model, temperature: node.temperature, maxTokens: node.maxTokens, timeout: .seconds(3600))
                    }
                    try Task.checkCancellation()
                    guard !observedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.emptyResponse }
                    let output = TextOutput(id: UUID(), runID: run.id, projectID: graph.id, nodeID: node.id, prompt: instructions, model: node.model, text: observedText, createdAt: Date())
                    try await persistence.saveOutput(output)
                    run.status = .succeeded; run.finishedAt = Date(); run.outputID = output.id; try await persistence.saveRun(run)
                    valueStore.emit(node, "text", .text(observedText)); if node.id == targetID { finalRun = run; finalText = output }
                } catch {
                    run.status = error is CancellationError ? .cancelled : .failed; run.finishedAt = Date(); run.error = error.localizedDescription
                    try? await persistence.saveRun(run); throw error
                }
            case .imageUpscale:
                guard let upscaleEngine else { throw StudioError.validation("No bundled upscale engine is available.") }
                guard case .image(let sourceURL) = try valueStore.required(node, "image") else { throw StudioError.validation("Image Upscale requires an image.") }
                let sourceImage = try await media.validateImage(sourceURL)
                let explicitlyAllowed = node.experimentalUpscaleRecipeID == node.model
                let installedTaskVerified = installedGenerationModels?.first { $0.id == node.model && $0.available }?.hasVerifiedUpscale == true
                let allowsUnverifiedLocalRun = installedTaskVerified || explicitlyAllowed
                let sourceIdentity = try MediaIdentity.of(sourceURL)
                let (request, _) = try UpscaleRequestPlanner.makeRequest(recipeID: node.model, scale: node.upscaleScale, tileSize: node.upscaleTileSize, sourceWidth: sourceImage.width, sourceHeight: sourceImage.height, registry: upscaleCapabilities, allowsUnverifiedLocalRun: allowsUnverifiedLocalRun, sourceImage: sourceURL, sourceIdentity: sourceIdentity)
                var run = RunRecord(id: UUID(), snapshot: .init(projectID: graph.id, nodeID: node.id, prompt: "", model: node.model, temperature: 0, maxTokens: 0, engineID: request.engineBuild, modelRecipe: ModelCatalog.recipes.first(where: { $0.id == node.model }), imageWidth: sourceImage.width, imageHeight: sourceImage.height, upscaleRequest: request), status: .queued, queuedAt: Date())
                try await persistence.saveRun(run)
                do {
                    run.status = .running; run.startedAt = Date(); try await persistence.saveRun(run)
                    let url = try await GenerationProgressContext.$report.withValue({ update in Task { await onEvent(.progress(id, update)) } }) {
                        try await upscaleEngine.upscale(request)
                    }
                    try Task.checkCancellation()
                    _ = try await media.validateImage(url)
                    let retained = try await media.retain(url)
                    let scratch = persistence.root.appending(path: "GenerationScratch").standardizedFileURL.resolvingSymlinksInPath()
                    if url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == scratch.path, UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                        try? FileManager.default.removeItem(at: url)
                    }
                    valueStore.emit(node, "image", .image(retained))
                    run.status = .succeeded; run.finishedAt = Date(); try await persistence.saveRun(run)
                    if node.id == targetID { finalRun = run }
                } catch {
                    run.status = error is CancellationError ? .cancelled : .failed; run.finishedAt = Date(); run.error = error is CancellationError ? "Cancelled by user." : error.localizedDescription
                    try? await persistence.saveRun(run); throw error
                }
            case .videoUpscale:
                guard let upscaleEngine else { throw StudioError.validation("No bundled upscale engine is available.") }
                guard case .video(let sourceVideo) = try valueStore.required(node, "video") else { throw StudioError.validation("Video Upscale requires a video.") }
                try await media.validateVideo(sourceVideo)
                let explicitlyAllowed = node.experimentalUpscaleRecipeID == node.model
                let installedTaskVerified = installedGenerationModels?.first { $0.id == node.model && $0.available }?.hasVerifiedUpscale == true
                let allowsUnverifiedLocalRun = installedTaskVerified || explicitlyAllowed
                let runner = VideoUpscaleRunner(engine: upscaleEngine, capabilities: upscaleCapabilities, scratchRoot: persistence.root.appending(path: "GenerationScratch"))
                var run = RunRecord(id: UUID(), snapshot: .init(projectID: graph.id, nodeID: node.id, prompt: "", model: node.model, temperature: 0, maxTokens: 0, engineID: VideoCapabilityRegistry.sdCppBuild, modelRecipe: ModelCatalog.recipes.first(where: { $0.id == node.model }), upscaleVideoScale: node.upscaleScale, upscaleVideoTileSize: node.upscaleTileSize), status: .queued, queuedAt: Date())
                try await persistence.saveRun(run)
                do {
                    run.status = .running; run.startedAt = Date(); try await persistence.saveRun(run)
                    let result = try await GenerationProgressContext.$report.withValue({ update in Task { await onEvent(.progress(id, update)) } }) {
                        try await runner.run(recipeID: node.model, scale: node.upscaleScale, tileSize: node.upscaleTileSize, allowsUnverifiedLocalRun: allowsUnverifiedLocalRun, sourceVideo: sourceVideo)
                    }
                    try Task.checkCancellation()
                    let retained = try await media.retain(result.url)
                    try? FileManager.default.removeItem(at: result.url)
                    valueStore.emit(node, "video", .video(retained))
                    run.status = .succeeded; run.finishedAt = Date(); try await persistence.saveRun(run)
                    if node.id == targetID { finalRun = run }
                } catch {
                    run.status = error is CancellationError ? .cancelled : .failed; run.finishedAt = Date(); run.error = error is CancellationError ? "Cancelled by user." : error.localizedDescription
                    try? await persistence.saveRun(run); throw error
                }
            case .frameInterpolate:
                guard case .video(let sourceVideo) = try valueStore.required(node, "video") else { throw StudioError.validation("Frame Interpolation requires a video.") }
                try await media.validateVideo(sourceVideo)
                let runner = FrameInterpolationRunner(scratchRoot: persistence.root.appending(path: "GenerationScratch"))
                let result = try await runner.run(sourceVideo: sourceVideo, targetFPS: node.deliveryFPS)
                let retained = try await media.retain(result.url)
                try? FileManager.default.removeItem(at: result.url)
                valueStore.emit(node, "video", .video(retained))
            case .instagramExport:
                guard case .video(let sourceVideo) = try valueStore.required(node, "video") else { throw StudioError.validation("Instagram Export requires a video.") }
                try await media.validateVideo(sourceVideo)
                let source = try await VideoProbe.inspect(sourceVideo)
                guard let deliveryFPS = InstagramReelExporter.deliveryFPS(sourceFPS: source.nominalFPS) else {
                    throw StudioError.validation("Instagram Export needs a 24, 25 or 30 fps source; this clip is about \(Int(source.nominalFPS.rounded())) fps. Add Frame Interpolation before this node so GenStudio creates real intermediate frames instead of duplicating low-rate frames.")
                }
                let url = try await InstagramReelExporter.run(sourceVideo: sourceVideo, scratchRoot: persistence.root.appending(path: "GenerationScratch"), fps: deliveryFPS, format: node.format)
                let retained = try await media.retain(url)
                try? FileManager.default.removeItem(at: url)
                valueStore.emit(node, "video", .video(retained))
            case .imageInput:
                guard let path = node.imagePath else { throw StudioError.validation("\(node.label) needs an image.") }; let url = URL(fileURLWithPath: path); _ = try await media.validateImage(url); valueStore.emit(node, "image", .image(try await media.retain(url)))
            case .maskInput:
                guard let path = node.imagePath else { throw StudioError.validation("\(node.label) needs a mask image.") }; let url = URL(fileURLWithPath: path); _ = try await media.validateImage(url); valueStore.emit(node, "image", .image(try await media.retain(url)))
            case .maskOperations:
                guard case .image(let mask) = try valueStore.required(node, "mask") else { throw StudioError.validation("Mask Operations requires a mask image.") }
                var source: URL?
                if let supplied = try valueStore.input(node, "source") {
                    guard case .image(let url) = supplied else { throw StudioError.validation("Mask Operations Source Image input must be an image.") }
                    source = url
                }
                let output = try await media.maskOperations(mask, invert: node.maskInvert, growOrShrink: node.maskGrowShrink, featherRadius: node.maskFeather, matchingSize: source)
                valueStore.emit(node, "mask", .image(output))
            case .videoInput:
                guard let path = node.videoPath else { throw StudioError.validation("\(node.label) needs a video.") }; let url = URL(fileURLWithPath: path); try await media.validateVideo(url); valueStore.emit(node, "video", .video(try await media.retain(url)))
            case .imageResize:
                guard case .image(let url) = try valueStore.required(node, "image") else { throw StudioError.validation("Image Resize requires an image.") }; valueStore.emit(node, "image", .image(try await media.resize(url, width: node.width, height: node.height)))
            case .imageCrop:
                guard case .image(let url) = try valueStore.required(node, "image") else { throw StudioError.validation("Image Crop requires an image.") }; valueStore.emit(node, "image", .image(try await media.crop(url, x: node.cropX, y: node.cropY, width: node.cropWidth, height: node.cropHeight)))
            case .imageBlend:
                guard case .image(let bg) = try valueStore.required(node, "background"), case .image(let fg) = try valueStore.required(node, "foreground") else { throw StudioError.validation("Image Blend requires two images.") }
                let alpha: Double; if let supplied = try valueStore.input(node, "opacity"), case .number(let value) = supplied { alpha = value } else { alpha = node.opacity }
                valueStore.emit(node, "image", .image(try await media.blend(background: bg, foreground: fg, opacity: alpha)))
            case .colourCorrect:
                guard case .image(let source) = try valueStore.required(node, "source"), case .image(let generated) = try valueStore.required(node, "generated") else { throw StudioError.validation("Colour Correct requires a source image and a generated image.") }
                valueStore.emit(node, "image", .image(try await media.colourCorrect(source: source, generated: generated)))
            case .imageCompare:
                let a = try valueStore.required(node, "a"), b = try valueStore.required(node, "b"); valueStore.emit(node, "a", a); valueStore.emit(node, "b", b); valueStore.emit(node, "selected", node.comparisonSelection == 0 ? a : b)
            case .extractFrame:
                guard case .video(let url) = try valueStore.required(node, "video") else { throw StudioError.validation("Extract Frame requires video.") }
                let seconds: Double; if let supplied = try valueStore.input(node, "time"), case .number(let value) = supplied { seconds = value } else { seconds = node.numberValue }
                valueStore.emit(node, "image", .image(try await media.extractFrame(url, seconds: seconds)))
            case .textRouter, .imageRouter, .videoRouter:
                let port = node.kind == .textRouter ? "text" : node.kind == .imageRouter ? "image" : "video"; let value = try valueStore.required(node, port); valueStore.emit(node, "a", value); valueStore.emit(node, "b", value)
            case .textPreview, .imagePreview, .videoPreview:
                let port = node.kind == .textPreview ? "text" : node.kind == .imagePreview ? "image" : "video"; valueStore.emit(node, port, try valueStore.required(node, port))
            case .stickyNote: break
            case .textToVideo:
                guard case .text(let prompt) = try valueStore.required(node, "prompt") else { throw StudioError.validation("Text to Video requires a text prompt.") }
                var negative: String?
                if let supplied = try valueStore.input(node, "negativePrompt") { guard case .text(let text) = supplied else { throw StudioError.validation("Negative prompt must be text.") }; negative = text }
                let compiled = await compileVideoPrompt(prompt, node: node, task: .textToVideo, installedModels: installedModels)
                let output = try await videoRunner.textToVideo(node: node, projectID: graph.id, prompt: prompt, negativePrompt: negative, compiledPrompt: compiled.text, promptCompilerModelID: compiled.modelID, onProgress: { update in Task { await onEvent(.progress(id, update)) } })
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
                if node.id == targetID { finalRun = output.run }
            case .imageToVideo:
                guard case .image(let start) = try valueStore.required(node, "startImage") else { throw StudioError.validation("Image to Video requires a start image.") }
                guard case .text(let prompt) = try valueStore.required(node, "prompt") else { throw StudioError.validation("Image to Video requires a text motion prompt.") }
                let compiled = await compileVideoPrompt(prompt, node: node, task: .imageToVideo, installedModels: installedModels)
                let output = try await videoRunner.imageToVideo(node: node, projectID: graph.id, prompt: prompt, startImage: start, compiledPrompt: compiled.text, promptCompilerModelID: compiled.modelID, onProgress: { update in Task { await onEvent(.progress(id, update)) } })
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
                if node.id == targetID { finalRun = output.run }
            case .startEndVideo:
                guard case .image(let start) = try valueStore.required(node, "startImage") else { throw StudioError.validation("Start/End Video requires a start image.") }
                guard case .image(let end) = try valueStore.required(node, "endImage") else { throw StudioError.validation("Start/End Video requires an end image.") }
                guard case .text(let prompt) = try valueStore.required(node, "prompt") else { throw StudioError.validation("Start/End Video requires a transition prompt.") }
                let compiled = await compileVideoPrompt(prompt, node: node, task: .firstLastFrame, installedModels: installedModels)
                let output = try await videoRunner.firstLastFrame(node: node, projectID: graph.id, prompt: prompt, startImage: start, endImage: end, compiledPrompt: compiled.text, promptCompilerModelID: compiled.modelID, onProgress: { update in Task { await onEvent(.progress(id, update)) } })
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
                if node.id == targetID { finalRun = output.run }
            case .guidedShot:
                // Timed multi-anchor generation still has no native adapter. The
                // deterministic Shot Sequence → Animatic path remains available.
                throw StudioError.validation(VideoCapabilityRegistry.unavailableReason(for: .timedKeyframes))
            case .videoToVideo:
                guard case .video(let sourceVideo) = try valueStore.required(node, "sourceVideo") else { throw StudioError.validation("Video to Video requires a source video clip.") }
                guard case .text(let prompt) = try valueStore.required(node, "prompt") else { throw StudioError.validation("Video to Video requires an edit prompt.") }
                let compiled = await compileVideoPrompt(prompt, node: node, task: .videoToVideo, installedModels: installedModels)
                let output = try await videoRunner.videoToVideo(node: node, projectID: graph.id, prompt: prompt, sourceVideo: sourceVideo, compiledPrompt: compiled.text, promptCompilerModelID: compiled.modelID, onProgress: { update in Task { await onEvent(.progress(id, update)) } })
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
                if node.id == targetID { finalRun = output.run }
            case .shotSequence:
                var connected: [String: RuntimeValue] = [:]
                for port in node.inputPorts { if let value = try valueStore.input(node, port.id) { connected[port.id] = value } }
                let output = try await videoRunner.shotSequence(node: node, connected: connected)
                valueStore.emit(node, "sequence", output.value)
            case .animatic:
                guard case .shotSequence(let sequence) = try valueStore.required(node, "sequence") else { throw StudioError.validation("Animatic requires a Shot Sequence.") }
                let output = try await videoRunner.animatic(sequence)
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
            case .assembleVideo:
                var clips: [URL] = []
                for port in node.inputPorts {
                    guard case .video(let url) = try valueStore.required(node, port.id) else { throw StudioError.validation("\(node.label) \(port.label) requires a video clip.") }
                    clips.append(url)
                }
                let output = try await videoRunner.assemble(node: node, clips: clips)
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
            case .voiceover:
                guard let speechEngine else { throw StudioError.validation("No local voice engine is available.") }
                guard case .video(let clip) = try valueStore.required(node, "video") else { throw StudioError.validation("Voiceover requires a video.") }
                var script = node.voiceoverSettings?.script ?? ""
                if let supplied = try valueStore.input(node, "script") {
                    guard case .text(let text) = supplied else { throw StudioError.validation("Voiceover script must be text.") }
                    script = text
                }
                let output = try await videoRunner.voiceover(node: node, video: clip, script: script, engine: speechEngine, onProgress: { update in Task { await onEvent(.progress(id, update)) } })
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
            case .textOverlay:
                guard case .video(let clip) = try valueStore.required(node, "video") else { throw StudioError.validation("Text Overlay requires a video.") }
                let output = try await videoRunner.textOverlay(node: node, video: clip)
                valueStore.emit(node, "video", output.value); provenance[node.id] = output.provenance
            case .endCard:
                func picture(_ port: String) throws -> URL? {
                    guard let value = try valueStore.input(node, port) else { return nil }
                    guard case .image(let url) = value else { throw StudioError.validation("End Card \(port) must be an image.") }
                    return url
                }
                let output = try await videoRunner.endCard(node: node, logo: try picture("logo"), background: try picture("background"))
                valueStore.emit(node, "video", output.video.value); valueStore.emit(node, "image", .image(output.still))
                provenance[node.id] = output.video.provenance
            case .imageGenerator:
                guard let imageEngine else { throw StudioError.validation("No bundled image engine is available.") }
                guard case .text(let prompt) = try valueStore.required(node, "prompt") else { throw StudioError.validation("Image generation requires a connected text prompt.") }
                var references: [URL] = []
                // Empty sockets are skipped, so this is the engine's actual `-r`
                // order — and therefore the order the role preamble must number.
                var connectedReferencePortIDs: [String] = []
                for portID in node.imageGeneratorReferencePortIDs {
                    guard let supplied = try valueStore.input(node, portID) else { continue }
                    guard case .image(let url) = supplied else { throw StudioError.validation("\(node.label) Reference inputs must be images.") }
                    references.append(url)
                    connectedReferencePortIDs.append(portID)
                }
                // @reference N names a canvas socket, while the native adapter
                // receives only connected images in compacted order. Resolve it
                // here, after that order is known, before a prompt compiler can
                // paraphrase the positional reference.
                let resolvedPrompt = try ReferenceMentionCatalog.resolve(prompt, for: node, connectedPortIDs: connectedReferencePortIDs)
                let task = ImageCapabilityRegistry.task(referenceCount: references.count)
                let compilation = try await compilePromptIfRegistered(resolvedPrompt, recipeID: node.model, task: .image(task),
                                                                      installedModels: installedModels, installedGenerationModels: installedGenerationModels,
                                                                      preserveAuthoredText: graph.characterSheetSource(feeding: node.id) != nil)
                let adapterPrompt = compilation?.compiledPrompt ?? resolvedPrompt
                let installedTaskVerified = installedGenerationModels?.first { $0.id == node.model && $0.available }?.hasVerifiedImageTask(task) == true
                let explicitlyAllowed = node.experimentalImageRecipeID == node.model
                let allowsUnverifiedLocalRun = installedTaskVerified || explicitlyAllowed
                var (request, capability) = try ImageRequestPlanner.makeRequest(recipeID: node.model, task: task, prompt: adapterPrompt, width: node.width, height: node.height, seed: node.imageSeed, strength: node.imageStrength, registry: runtimeImageCapabilities, allowsUnverifiedLocalRun: allowsUnverifiedLocalRun, referenceCount: references.count, referenceRoles: node.referenceRoles, connectedReferencePortIDs: connectedReferencePortIDs)
                if let compilation {
                    request.authoredPrompt = prompt
                    request.compiledPrompt = compilation.compiledPrompt
                    request.promptCompilerModelID = compilation.compilerModelID
                    request.promptCompilerVersion = compilation.compilerVersion
                    request.promptCompilerUsedFallback = compilation.usedFallback
                }
                if !references.isEmpty {
                    var prepared: [URL] = [], preparedIdentities: [MediaIdentity] = [], sourceIdentities: [MediaIdentity] = []
                    for reference in references {
                        _ = try await media.validateImage(reference)
                        sourceIdentities.append(try MediaIdentity.of(reference))
                        let image = capability.conditioning == .startImageStrength ? try await media.aspectFill(reference, width: node.width, height: node.height) : try await media.retain(reference)
                        prepared.append(image); preparedIdentities.append(try MediaIdentity.of(image))
                    }
                    // Preserve the original single-reference fields in run history.
                    request.referenceImage = prepared[0]; request.referenceIdentity = preparedIdentities[0]; request.sourceReferenceIdentity = sourceIdentities[0]
                    request.additionalReferenceImages = Array(prepared.dropFirst())
                    request.additionalReferenceIdentities = Array(preparedIdentities.dropFirst())
                    request.sourceAdditionalReferenceIdentities = Array(sourceIdentities.dropFirst())
                }
                var imageSnapshot = RunInputSnapshot(projectID: graph.id, nodeID: node.id, prompt: prompt, model: node.model, temperature: 0,
                                                     maxTokens: 0, engineID: capability.engineBuild,
                                                     modelRecipe: installedGenerationModels?.first(where: { $0.id == node.model })?.recipeSnapshot
                                                        ?? ModelCatalog.recipes.first(where: { $0.id == node.model }), imageWidth: node.width,
                                                     imageHeight: node.height, imageSeed: node.imageSeed, imageSteps: request.steps, imageRequest: request)
                if let compilation { apply(compilation, to: &imageSnapshot) }
                var run = RunRecord(id: UUID(), snapshot: imageSnapshot, status: .queued, queuedAt: Date())
                try await persistence.saveRun(run)
                do {
                    run.status = .running; run.startedAt = Date()
                    run.snapshot.thermalStateAtStart = EngineRunLog.label(ProcessInfo.processInfo.thermalState)
                    try await persistence.saveRun(run)
                    let engineLog = EngineRunLogBox()
                    let url = try await EngineRunLog.$record.withValue(engineLog.store) {
                        try await GenerationProgressContext.$report.withValue({ update in Task { await onEvent(.progress(id, update)) } }) {
                            try await imageEngine.generate(request)
                        }
                    }
                    run.snapshot.thermalStateAtEnd = EngineRunLog.label(ProcessInfo.processInfo.thermalState)
                    if let recorded = engineLog.recorded { run.snapshot.engineSeconds = recorded.seconds; run.snapshot.engineLogTail = recorded.tail }
                    try Task.checkCancellation()
                    _ = try await media.validateImage(url)
                    let retained = try await media.retain(url)
                    let scratch = persistence.root.appending(path: "GenerationScratch").standardizedFileURL.resolvingSymlinksInPath()
                    if url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == scratch.path, UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                        try? FileManager.default.removeItem(at: url)
                    }
                    valueStore.emit(node, "image", .image(retained))
                    run.status = .succeeded; run.finishedAt = Date(); try await persistence.saveRun(run)
                    if node.id == targetID { finalRun = run }
                } catch {
                    run.status = error is CancellationError ? .cancelled : .failed; run.finishedAt = Date(); run.error = error is CancellationError ? "Cancelled by user." : error.localizedDescription
                    try? await persistence.saveRun(run); throw error
                }
            }
            if id != targetID { await onEvent(.completed(id)) }
        }
        try await persistence.saveExecutionArtifact(.init(id: UUID(), projectID: graph.id, targetID: targetID, graphSnapshot: graph, values: valueStore.values, createdAt: Date(), mediaProvenance: provenance.isEmpty ? nil : provenance, generatedNodeIDs: Set(graph.nodes.filter { Self.isGenerative($0.kind) && !reusableNodeIDs.contains($0.id) && reusable[$0.id] == nil && cached.values[.init(nodeID: $0.id, portID: $0.outputPorts.first?.id ?? "")] == nil }.map(\.id))))
        await onEvent(.completed(targetID))
        return .init(values: valueStore.values, run: finalRun, textOutput: finalText)
    }
}
