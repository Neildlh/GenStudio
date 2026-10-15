import Foundation

/// Node-level checks run for the whole graph before any node executes, so no model loads for an invalid plan.
enum VideoPreflight {
    static func role(forPort portID: String) -> VideoInputRole? {
        switch portID {
        case "prompt": .prompt
        case "negativePrompt": .negativePrompt
        case "startImage": .startImage
        case "endImage": .endImage
        case "sequence": .timedAnchors
        case "sourceVideo": .sourceVideo
        case "referenceImage": .referenceImage
        case "mask": .mask
        default: nil
        }
    }

    static func connectedRoles(_ node: StudioNode, connectedPorts: Set<String>) -> Set<VideoInputRole> {
        Set(node.inputPorts.filter { connectedPorts.contains($0.id) }.compactMap { role(forPort: $0.id) })
    }

    /// Explains why a generation node cannot run. Unsupported modes always fail here, even with every input connected.
    static func generationIssue(_ node: StudioNode, connectedPorts: Set<String>, installed: [InstalledGenerationModel]?, registry: [VideoCapability]) -> String? {
        guard let task = node.kind.videoTask else { return nil }
        let supplied = connectedRoles(node, connectedPorts: connectedPorts)
        let candidates = VideoCapabilityRegistry.capabilities(for: task, in: registry)
        guard !candidates.isEmpty else {
            let kept = supplied.isEmpty ? "" : " Connected inputs stay on the canvas but are not run or substituted."
            return "\(node.label): \(task.title) is unavailable. \(VideoCapabilityRegistry.unavailableReason(for: task))\(kept)"
        }
        guard !node.model.isEmpty else { return "\(node.label) needs a \(task.title.lowercased()) recipe. Choose one in the inspector." }
        guard let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: task, in: registry) else {
            return "\(node.label): recipe \(node.model) has no \(task.title.lowercased()) adapter. GenStudio never repurposes a recipe for another task."
        }
        if let rejected = VideoCapabilityRegistry.rejectionReason(for: capability.recipeID) {
            return "\(node.label): \(rejected)"
        }
        // When the app supplied its installed-model snapshot, report concrete installation
        // problems before validating the adapter contract and node settings.
        let registeredInstall = installed?.first { $0.id == capability.recipeID }
        if installed != nil {
            guard let registeredInstall else {
                return "Model \(node.model) is not installed. Install the exact recipe in Model Library before running this node."
            }
            guard registeredInstall.available else {
                return "Model \(node.model) is installed but its files are unavailable. Repair it in Model Library before running this node."
            }
            guard registeredInstall.kind == .video, registeredInstall.engineID == capability.engineID else {
                return "The installed model does not match this video adapter."
            }
        }
        do { _ = try VideoRequestPlanner.validate(settings: node.video, task: task, capability: capability, supplied: supplied) }
        catch { return "\(node.label): \(error.localizedDescription)" }
        if let issue = NodeModelCompatibility.issue(for: node, installed: installed) { return issue }
        return nil
    }

    static func sequenceIssue(_ node: StudioNode, connectedPorts: Set<String>) -> String? {
        let spec = node.sequence
        do { _ = try SequenceTiming.resolve(spec) } catch { return "\(node.label): \(error.localizedDescription)" }
        guard (16...4096).contains(spec.width), (16...4096).contains(spec.height), spec.width.isMultiple(of: 2), spec.height.isMultiple(of: 2) else {
            return "\(node.label): output size must be even and 16–4096 pixels per side."
        }
        for anchor in spec.anchors {
            let connected = connectedPorts.contains(anchor.id)
            if connected && anchor.imagePath != nil { return "\(node.label): \(anchor.label) has both a connected image and a chosen file. Clear one; GenStudio does not pick silently." }
            if !connected {
                guard let path = anchor.imagePath else { return "\(node.label): \(anchor.label) needs an image. Connect one or choose a file." }
                guard FileManager.default.isReadableFile(atPath: path) else { return "\(node.label): \(anchor.label) image file is not readable." }
            }
        }
        return nil
    }

    static func assemblyIssue(_ node: StudioNode, connectedPorts: Set<String>) -> String? {
        let settings = node.assembly
        guard (1...AssemblySettings.maximumClips).contains(node.dynamicInputs.count), node.dynamicInputs.allSatisfy({ $0.type == .video }) else {
            return "\(node.label) needs 1–\(AssemblySettings.maximumClips) clip slots."
        }
        if let empty = node.dynamicInputs.first(where: { !connectedPorts.contains($0.id) }) {
            return "\(node.label): \(empty.label) is empty. Connect a clip or remove the slot."
        }
        guard (1...60).contains(settings.fps) else { return "\(node.label): frame rate must be 1–60 fps." }
        let matchFirst = settings.width == 0 && settings.height == 0
        guard matchFirst || ((16...4096).contains(settings.width) && (16...4096).contains(settings.height) && settings.width.isMultiple(of: 2) && settings.height.isMultiple(of: 2)) else {
            return "\(node.label): size must be 0×0 (match first clip) or even and 16–4096 pixels per side."
        }
        for (index, slot) in node.dynamicInputs.enumerated() {
            let edit = settings.edit(for: slot.id)
            guard edit.trimStart >= 0, edit.trimEnd >= 0 else { return "\(node.label): clip \(index + 1) has a negative trim." }
            guard (0...1).contains(edit.volume) else { return "\(node.label): clip \(index + 1) level must be 0–100%." }
        }
        return nil
    }

    /// Chooser status. Authoring is always allowed; this never makes an unavailable mode runnable.
    enum Availability: Equatable { case runnable, needsModel, unavailable }
    static func availability(_ kind: NodeKind, installed: [InstalledGenerationModel], registry: [VideoCapability] = VideoCapabilityRegistry.shipped) -> Availability {
        guard let task = kind.videoTask else { return .runnable }
        let capabilities = VideoCapabilityRegistry.capabilities(for: task, in: registry)
        guard !capabilities.isEmpty else { return .unavailable }
        return capabilities.contains { capability in installed.contains { $0.id == capability.recipeID && $0.available } }
            ? .runnable : .needsModel
    }

    /// Card status must describe the exact selected recipe. A different installed checkpoint in
    /// the same family (for example MiniMax Ref2VA versus FL2VA) cannot satisfy this node.
    static func availability(_ node: StudioNode, installed: [InstalledGenerationModel], registry: [VideoCapability] = VideoCapabilityRegistry.shipped) -> Availability {
        guard let task = node.kind.videoTask else { return .runnable }
        guard let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: task, in: registry) else { return .unavailable }
        guard installed.contains(where: { $0.id == capability.recipeID && $0.available }) else { return .needsModel }
        return .runnable
    }
}
