import Foundation

/// Uses verified library/runtime metadata rather than a model's marketing name or hub tags.
enum NodeModelCompatibility {
    static func requiredKind(for nodeKind: NodeKind) -> GenerationModelKind? {
        switch nodeKind {
        case .textModel, .promptEnhancer: .text
        case .imageGenerator: .image
        case .imageUpscale, .videoUpscale: .upscaler
        case .imageDescriber: .vision
        case .textToVideo, .imageToVideo: .video
        case .voiceover: .speech
        default: nil
        }
    }

    static func purpose(_ kind: GenerationModelKind) -> String {
        switch kind {
        case .text: "text generation"
        case .image: "image generation"
        case .video: "video generation"
        case .vision: "image understanding"
        case .upscaler: "image upscaling"
        case .speech: "voiceover"
        }
    }

    static func supports(_ model: InstalledGenerationModel, kind: GenerationModelKind) -> Bool {
        guard model.available && model.canAttemptGeneration else { return false }
        guard let capabilities = model.recipeSnapshot?.workflowCapabilities else { return model.kind == kind }
        switch kind {
        case .text: return capabilities.contains(.textGeneration)
        case .vision: return capabilities.contains(.imageUnderstanding)
        default: return model.kind == kind
        }
    }

    static func issue(for node: StudioNode, installed: [InstalledGenerationModel]?, externalTextModels: Set<String> = [], allowUnverifiedImage: Bool = false, cloudSignedIn: Bool = false) -> String? {
        guard let required = requiredKind(for: node.kind) else { return nil }
        guard !node.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(node.label) needs an installed \(purpose(required)) model. Choose one in the node settings."
        }
        // The ChatGPT subscription route is cloud, not a local install: it has no
        // InstalledGenerationModel entry by design. Gate it on sign-in state instead.
        if required == .image, node.model == ChatGPTSubscriptionImageEngine.recipeID {
            return cloudSignedIn ? nil : "\(node.label): Not signed in to your ChatGPT subscription. Open GenStudio → Settings to connect it, or choose an installed model."
        }
        let match = installed?.first(where: { $0.id == node.model })
        let catalogRecipe = ModelCatalog.recipes.first(where: { $0.id == node.model })
        let actualKind = match?.kind ?? catalogRecipe?.kind
        let declaredCapabilities = match?.recipeSnapshot?.workflowCapabilities
        // Without an installed record, a catalog recipe's declared workflows still count: Qwen3.8 MLX is
        // a vision recipe that also generates text.
        let catalogMatches = catalogRecipe?.workflowCapabilities.map { required == .text ? $0.contains(.textGeneration) : required == .vision ? $0.contains(.imageUnderstanding) : false } ?? false
        let capabilityMatches = match.map { supports($0, kind: required) } ?? catalogMatches
        if declaredCapabilities != nil, !capabilityMatches {
            return "\(node.label) needs \(purpose(required)); the selected model is not enabled for that workflow. Choose a compatible model in the node settings."
        }
        if let actualKind, actualKind != required, !capabilityMatches {
            return "\(node.label) needs \(purpose(required)); the selected model is for \(purpose(actualKind)). Choose a compatible model in the node settings."
        }
        if let match {
            guard match.available else { return "Model \(match.name) is not installed or its files are unavailable. Repair it in the Model Library or choose another model." }
            // An image adapter that has not yet produced a decoded proof can
            // still be tried through the node's exact-recipe opt-in; the task
            // planner performs the readiness check next.
            // Installed curated adapters are allowed to reach their task-specific planner;
            // the planner validates the exact recipe, inputs and settings before execution.
            let hasAwaitingAdapter = (required == .image && (ImageCapabilityRegistry.hasAdapter(node.model) || match.recipeSnapshot.map(UserModelCatalog.isSupported) == true))
                || (required == .video && VideoCapabilityRegistry.hasAdapter(node.model))
                || (required == .upscaler && UpscaleCapabilityRegistry.hasAdapter(node.model))
            if !match.canAttemptGeneration && !hasAwaitingAdapter {
                return "Model \(match.name) has no compatible local runtime for \(node.kind.title). Choose a supported \(purpose(required)) model in the node settings."
            }
            return nil
        }
        // A supplied library snapshot is authoritative. External engines may supply text models separately.
        if installed != nil && !(required == .text && externalTextModels.contains(node.model)) {
            return "\(node.label): Model \(node.model) is not installed or its files are unavailable. Install a compatible \(purpose(required)) model in the Model Library."
        }
        return nil
    }
}

struct GraphValidator: Sendable {
    var videoCapabilities: [VideoCapability] = VideoCapabilityRegistry.shipped
    var imageCapabilities: [ImageCapability] = ImageCapabilityRegistry.shipped
    var upscaleCapabilities: [UpscaleCapability] = UpscaleCapabilityRegistry.shipped
    private func validateIdentities(_ project: WorkflowProject) throws {
        guard Set(project.nodes.map(\.id)).count == project.nodes.count else { throw StudioError.validation("Node identifiers must be unique.") }
        guard Set(project.edges.map(\.id)).count == project.edges.count else { throw StudioError.validation("Connection identifiers must be unique.") }
        for node in project.nodes {
            if node.kind == .imageGenerator, !node.dynamicInputs.allSatisfy({ $0.type == .image }) {
                throw StudioError.validation("\(node.label)'s additional reference sockets must be images.")
            }
            if node.kind.supportsDynamicImageInputs && node.kind != .imageGenerator {
                guard !node.dynamicInputs.isEmpty, node.dynamicInputs.allSatisfy({ $0.type == .image }) else { throw StudioError.validation("\(node.kind.title) requires at least one image socket.") }
            }
            if node.kind == .shotSequence, node.sequence.anchors.count > ShotSequenceSpec.maximumAnchors || Set(node.sequence.anchors.map(\.id)).count != node.sequence.anchors.count {
                throw StudioError.validation("\(node.label) needs at most \(ShotSequenceSpec.maximumAnchors) frames with unique identifiers.")
            }
            if node.kind.supportsDynamicVideoInputs, node.dynamicInputs.count > AssemblySettings.maximumClips || !node.dynamicInputs.allSatisfy({ $0.type == .video }) {
                throw StudioError.validation("\(node.label) accepts at most \(AssemblySettings.maximumClips) video clip sockets.")
            }
            let inputs = node.inputPorts.map(\.id), outputs = node.outputPorts.map(\.id)
            guard Set(inputs).count == inputs.count, Set(outputs).count == outputs.count else { throw StudioError.validation("Port identifiers on \(node.label) must be unique within each direction.") }
            guard (inputs + outputs).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.hasPrefix("__legacy") }) else { throw StudioError.validation("Port identifiers on \(node.label) must be nonblank and non-reserved.") }
        }
    }

    func resolved(_ edge: StudioEdge, nodes: [UUID: StudioNode]) throws -> StudioEdge {
        guard let source = nodes[edge.sourceID], let target = nodes[edge.targetID] else { throw StudioError.validation("A connection references a node that no longer exists.") }
        var result = edge
        if result.sourcePortID == "__legacy_output" {
            guard let port = source.outputPorts.first(where: { $0.type == edge.type }) else { throw StudioError.validation("Incompatible \(edge.type.rawValue) connection from \(source.label) to \(target.label).") }
            result.sourcePortID = port.id
        }
        if result.targetPortID == "__legacy_input" {
            guard let port = target.inputPorts.first(where: { $0.type == edge.type }) else { throw StudioError.validation("Incompatible \(edge.type.rawValue) connection from \(source.label) to \(target.label).") }
            result.targetPortID = port.id
        }
        guard let output = source.outputPorts.first(where: { $0.id == result.sourcePortID }) else { throw StudioError.validation("\(source.label) has no output port named \(result.sourcePortID).") }
        guard let input = target.inputPorts.first(where: { $0.id == result.targetPortID }) else { throw StudioError.validation("\(target.label) has no input port named \(result.targetPortID).") }
        guard output.direction == .output, input.direction == .input, output.type == input.type, output.type == edge.type else { throw StudioError.validation("Incompatible \(edge.type.rawValue) connection from \(source.label) to \(target.label).") }
        return result
    }

    func validateEdgesAttached(to nodeIDs: Set<UUID>, in project: WorkflowProject) throws {
        try validateIdentities(project)
        let nodes = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
        for edge in project.edges where nodeIDs.contains(edge.sourceID) || nodeIDs.contains(edge.targetID) { _ = try resolved(edge, nodes: nodes) }
    }

    func validate(_ project: WorkflowProject, installedModels: Set<String>? = nil, installedGenerationModels: [InstalledGenerationModel]? = nil, requireRunnableInputs: Bool = true, reusableNodeIDs: Set<UUID> = [], cloudSignedIn: Bool = false, orderingDependencies: [(before: UUID, after: UUID)] = []) throws -> [UUID] {
        let runtimeImageCapabilities = ImageCapabilityRegistry.runtimeRegistry(base: imageCapabilities, installed: installedGenerationModels)
        try validateIdentities(project)
        let nodes = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
        var incoming: [UUID: [StudioEdge]] = [:], seenInputs: Set<PortAddress> = [], seenEdges: Set<String> = []
        var indegree = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, 0) }); var adjacency = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, [UUID]()) })
        for rawEdge in project.edges {
            let edge = try resolved(rawEdge, nodes: nodes)
            let key = "\(edge.sourceID):\(edge.sourcePortID):\(edge.targetID):\(edge.targetPortID)"
            guard seenEdges.insert(key).inserted else { throw StudioError.validation("The same connection already exists.") }
            guard seenInputs.insert(.init(nodeID: edge.targetID, portID: edge.targetPortID)).inserted else { throw StudioError.validation("Input \(edge.targetPortID) already has a connection.") }
            incoming[edge.targetID, default: []].append(edge); adjacency[edge.sourceID, default: []].append(edge.targetID); indegree[edge.targetID, default: 0] += 1
        }
        if requireRunnableInputs {
            for node in project.nodes {
                // A displayed upstream output is an input to this node-level run. Its
                // originating model and settings do not need to remain runnable merely
                // to consume that already-produced value.
                if reusableNodeIDs.contains(node.id) { continue }
                if node.kind == .prompt && node.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StudioError.validation("\(node.label) needs a prompt.") }
                if node.kind == .imagePrompt && (node.imagePromptSettings?.compiledPrompt.isEmpty ?? true) { throw StudioError.validation("\(node.label) needs a subject before it can create an image prompt.") }
                if node.kind == .videoPrompt && (node.videoPromptSettings?.compiledPrompt.isEmpty ?? true) { throw StudioError.validation("\(node.label) needs an action before it can create a video prompt.") }
                if node.kind == .voiceover, (node.voiceoverSettings?.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !incoming[node.id, default: []].contains(where: { $0.targetPortID == "script" }) {
                    throw StudioError.validation("\(node.label) needs a script: type one in the node, or connect a Prompt to its Script input.")
                }
                if node.kind == .textOverlay {
                    do { try (node.textOverlaySettings ?? .init()).validate() }
                    catch { throw StudioError.validation("\(node.label): \(error.localizedDescription)") }
                }
                if node.kind == .endCard {
                    do { try (node.endCardSettings ?? .init()).validate() }
                    catch { throw StudioError.validation("\(node.label): \(error.localizedDescription)") }
                }
                let connected = Set(incoming[node.id, default: []].map(\.targetPortID))
                // Capability gating comes first so an unavailable mode reports its real blocker, not a missing wire.
                if let issue = VideoPreflight.generationIssue(node, connectedPorts: connected, installed: installedGenerationModels, registry: videoCapabilities) { throw StudioError.validation(issue) }
                if node.kind.videoTask != nil, let installedModels, !installedModels.contains(node.model) { throw StudioError.validation("Model \(node.model) is not installed or its files are unavailable. Install or import its components in the Model Library.") }
                if node.kind == .shotSequence, let issue = VideoPreflight.sequenceIssue(node, connectedPorts: connected) { throw StudioError.validation(issue) }
                if node.kind == .assembleVideo, let issue = VideoPreflight.assemblyIssue(node, connectedPorts: connected) { throw StudioError.validation(issue) }
                if node.kind == .combineText, connected.isEmpty { throw StudioError.validation("\(node.label) needs at least one text input connected.") }
                if node.kind == .promptTemplate, let issue = PromptTemplateSyntax.issue(for: node, connectedPorts: connected) { throw StudioError.validation(issue) }
                for port in node.inputPorts where port.required {
                    guard incoming[node.id, default: []].contains(where: { $0.targetPortID == port.id }) else { throw StudioError.validation("\(node.label) needs its \(port.label) input connected.") }
                }
                if node.kind == .textModel || node.kind == .promptEnhancer || node.kind == .imageGenerator || node.kind == .imageDescriber || node.kind == .imageUpscale || node.kind == .videoUpscale {
                    let allowUnverifiedImage = node.kind == .imageGenerator && node.experimentalImageRecipeID == node.model
                    let isCloudImageRecipe = node.kind == .imageGenerator && node.model == ChatGPTSubscriptionImageEngine.recipeID
                    if let issue = NodeModelCompatibility.issue(for: node, installed: installedGenerationModels, externalTextModels: installedModels ?? [], allowUnverifiedImage: allowUnverifiedImage, cloudSignedIn: cloudSignedIn) { throw StudioError.validation(issue) }
                    if let installedModels, !installedModels.contains(node.model), !isCloudImageRecipe { throw StudioError.validation("Model \(node.model) is not installed or its files are unavailable.") }
                }
                if node.kind == .imageUpscale || node.kind == .videoUpscale {
                    do { _ = try UpscaleRequestPlanner.validateSettings(recipeID: node.model, scale: node.upscaleScale, tileSize: node.upscaleTileSize, registry: upscaleCapabilities) }
                    catch { throw StudioError.validation("\(node.label): \(error.localizedDescription)") }
                }
                if node.kind == .imageGenerator {
                    let referenceCount = incoming[node.id, default: []].filter { node.imageGeneratorReferencePortIDs.contains($0.targetPortID) }.count
                    let task = ImageCapabilityRegistry.task(referenceCount: referenceCount)
                    do { _ = try ImageRequestPlanner.validate(recipeID: node.model, task: task, width: node.width, height: node.height, seed: node.imageSeed, strength: node.imageStrength, registry: runtimeImageCapabilities, referenceCount: referenceCount) }
                    catch { throw StudioError.validation("\(node.label): \(error.localizedDescription)") }
                }
                if node.kind == .imageInput { try validateFile(node.imagePath, label: node.label) }
                if node.kind == .videoInput { try validateFile(node.videoPath, label: node.label) }
                if node.kind == .maskInput { try validateFile(node.imagePath, label: node.label) }
            }
        }
        // Run-order constraints that are not wires, such as a Prompt Enhancer looking at the picture its
        // destination receives. Only pairs inside this run apply.
        for dependency in orderingDependencies where nodes[dependency.before] != nil && nodes[dependency.after] != nil {
            adjacency[dependency.before, default: []].append(dependency.after); indegree[dependency.after, default: 0] += 1
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key), order: [UUID] = []
        while let id = queue.first { queue.removeFirst(); order.append(id); for next in adjacency[id, default: []] { indegree[next, default: 0] -= 1; if indegree[next] == 0 { queue.append(next) } } }
        guard order.count == project.nodes.count else { throw StudioError.validation("The workflow contains a cycle. Remove a connection before running.") }
        return order
    }

    private func validateFile(_ path: String?, label: String) throws {
        guard let path, FileManager.default.isReadableFile(atPath: path) else { throw StudioError.validation("\(label) needs a readable local file.") }
    }
}
