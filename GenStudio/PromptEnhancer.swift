import CryptoKit
import Foundation

/// What kind of prompt a Prompt Enhancer writes. Auto (a nil setting on the node) follows the
/// node its output feeds; these cases are also the manual choices when nothing is connected yet.
enum PromptEnhancerTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case image, textToVideo, imageToVideo, startEndVideo, videoToVideo, guidedShot, voiceover, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Image"
        case .textToVideo: "Video from text"
        case .imageToVideo: "Animate an image"
        case .startEndVideo: "Start/end transition"
        case .videoToVideo: "Video rework"
        case .guidedShot: "Guided shot"
        case .voiceover: "Voiceover script"
        case .general: "General instruction"
        }
    }

    /// The target a consuming node implies, or nil when the node does not take a prompt.
    static func detected(for kind: NodeKind) -> Self? {
        switch kind {
        case .imageGenerator: .image
        case .textToVideo: .textToVideo
        case .imageToVideo: .imageToVideo
        case .startEndVideo: .startEndVideo
        case .videoToVideo: .videoToVideo
        case .guidedShot: .guidedShot
        case .voiceover: .voiceover
        case .textModel, .promptEnhancer: .general
        default: nil
        }
    }

    /// The rules the model follows for this destination. Kept here, in one table, so each
    /// destination's prompt style can be tuned without touching execution.
    func rules(durationSeconds: Double?, referenceCount: Int) -> [String] {
        let pace = durationSeconds.map { "Pace the action to fit \(PromptEnhancer.seconds($0)); one to three clear beats, never more than can happen in that time." }
            ?? "Pace the action to fit a short clip of a few seconds."
        switch self {
        case .image:
            var rules = [
                "Describe one still picture: the main subject and how it looks, its pose or action, the setting, composition and framing, lighting, colour, mood, and the photographic or artistic style. Put the most important things first.",
                "Put any words that must appear in the picture in double quotes.",
                "Do not describe movement, camera moves or sound.",
                "Write 40 to 120 words."
            ]
            if referenceCount > 0 {
                rules.insert("The generator also receives \(referenceCount == 1 ? "a reference image" : "\(referenceCount) reference images"). Say how each is used (for example \"the person from the reference image\") instead of describing its contents in detail.", at: 1)
            }
            return rules
        case .textToVideo:
            return [
                "Describe one continuous shot from its first frame: who or what is in it and how they look, then the setting, then the action in the order it happens.",
                pace,
                "Say where the camera is and how it moves; if the request does not say, keep it steady.",
                "Add natural motion detail such as breathing, hair, fabric or light, and the lighting and look of the shot.",
                "If the request mentions sound or speech, add one short sentence describing it.",
                "Write 80 to 160 words."
            ]
        case .imageToVideo:
            return [
                "The start image already fixes who is in the shot, how they look, the setting, the framing and the lighting. Name the subject briefly as it appears, then spend most of the words on motion.",
                "Describe what moves, in what order, how fast, and how the shot ends. \(pace)",
                "Keep identity, proportions, clothing, colours and background exactly as they are in the image. Never contradict the image.",
                "Say what the camera does; if the request does not say, the camera stays static.",
                "Add subtle natural secondary motion such as breathing, blinking, fur, hair or fabric movement.",
                "Write 60 to 130 words."
            ]
        case .startEndVideo:
            return [
                "The video starts on the first frame and must arrive at the last frame. Describe one continuous, physically believable change that carries the scene from one to the other.",
                pace,
                "Say what stays the same, and what the camera does; if the request does not say, the camera stays steady.",
                "Write 60 to 130 words."
            ]
        case .videoToVideo:
            return [
                "The source clip supplies the motion and timing. Describe the result after the edit: what changes (look, style, subject appearance or setting) and what must stay as it is in the source.",
                "Write 50 to 110 words."
            ]
        case .guidedShot:
            return [
                "Timed key frames already set the main poses. Describe the motion that flows smoothly through them and what the camera does.",
                pace,
                "Write 60 to 130 words."
            ]
        case .voiceover:
            let words = durationSeconds.map { max(8, Int(($0 * 2.5).rounded())) }
            return [
                "Write a natural spoken script for a voice actor: short, clear sentences that sound good read aloud.",
                words.map { "Aim for about \($0) words so it fits \(PromptEnhancer.seconds(durationSeconds ?? 0)) at a relaxed pace." } ?? "Keep it short enough for a brief advert.",
                "Keep names, prices, dates and contact details exactly as given. No stage directions, labels or sound effects."
            ]
        case .general:
            return [
                "Rewrite the request as a clear, specific instruction for an AI model: the goal, the important details and constraints, and the expected result.",
                "Keep it concise."
            ]
        }
    }
}

/// The node a Prompt Enhancer's output reaches, with the facts that shape a good prompt for it.
struct PromptEnhancerDestination: Hashable, Sendable {
    let nodeID: UUID
    let kind: NodeKind
    let label: String
    let target: PromptEnhancerTarget
    let modelID: String
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var fps: Int?
    /// Connected Reference sockets on an Image Generator, in socket order.
    var referenceCount = 0
}

/// A picture the destination already receives, which the enhancer looks at for context.
struct PromptEnhancerContextSource: Hashable, Sendable {
    let sourceID: UUID
    let sourcePortID: String
    /// How the instruction refers to this picture, for example "the start frame".
    let role: String
}

/// Turns a rough, human-written request into a prompt written for the node it feeds.
/// Pure graph reading and text building; execution and the model call live in ExecutionQueue.
enum PromptEnhancer {
    static let version = "prompt-enhancer-v1"
    static let roughPromptPortID = "prompt"
    static let imagePortID = "image"
    static let outputPortID = "text"
    static let defaultTemperature = 0.4
    static let defaultMaxTokens = 512

    /// Text nodes that pass the enhanced prompt on rather than consume it.
    private static let passThroughKinds: Set<NodeKind> = [.textRouter, .textPreview, .combineText, .promptTemplate]
    /// The sockets of a consuming node that take the main prompt (never a negative prompt).
    private static let promptPortIDs: Set<String> = ["prompt", "script"]

    /// The prompt-taking nodes this enhancer's output reaches, nearest first, following
    /// text routers, previews, Combine Text and Prompt Template on the way.
    static func destinations(of enhancerID: UUID, in project: WorkflowProject) -> [PromptEnhancerDestination] {
        let nodes = Dictionary(project.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [PromptEnhancerDestination] = [], seen: Set<UUID> = [enhancerID], queue = [enhancerID]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for edge in project.edges where edge.sourceID == id && edge.type == .text {
                guard let target = nodes[edge.targetID], seen.insert(target.id).inserted else { continue }
                if passThroughKinds.contains(target.kind) { queue.append(target.id); continue }
                guard promptPortIDs.contains(edge.targetPortID), let kind = PromptEnhancerTarget.detected(for: target.kind) else { continue }
                found.append(destination(target, target: kind, project: project))
            }
        }
        return found
    }

    private static func destination(_ node: StudioNode, target: PromptEnhancerTarget, project: WorkflowProject) -> PromptEnhancerDestination {
        var result = PromptEnhancerDestination(nodeID: node.id, kind: node.kind, label: node.label, target: target, modelID: node.model)
        if node.kind == .imageGenerator {
            result.width = node.width; result.height = node.height
            let referencePorts = Set(node.imageGeneratorReferencePortIDs)
            result.referenceCount = project.edges.filter { $0.targetID == node.id && referencePorts.contains($0.targetPortID) }.count
        } else if node.kind.videoTask != nil {
            result.width = node.video.width; result.height = node.video.height
            result.durationSeconds = node.video.requestedDurationSeconds; result.fps = node.video.fps
        }
        return result
    }

    /// The target this node writes for: its manual choice, else its first destination, else general.
    static func target(for node: StudioNode, in project: WorkflowProject) -> PromptEnhancerTarget {
        node.promptEnhancerTarget ?? destinations(of: node.id, in: project).first?.target ?? .general
    }

    /// Pictures the first destination already receives (its start/end frames or references) that
    /// the enhancer may look at without its own Image socket being wired. A source that itself
    /// depends on the enhancer is left out, so the run order stays acyclic.
    static func contextSources(of enhancerID: UUID, in project: WorkflowProject) -> [PromptEnhancerContextSource] {
        guard let destination = destinations(of: enhancerID, in: project).first,
              let node = project.nodes.first(where: { $0.id == destination.nodeID }) else { return [] }
        let roles: [(port: String, role: String)]
        switch node.kind {
        case .imageToVideo: roles = [("startImage", "the start frame the video begins from")]
        case .startEndVideo: roles = [("startImage", "the first frame"), ("endImage", "the last frame")]
        case .imageGenerator:
            roles = node.imageGeneratorReferencePortIDs.enumerated().map { index, port in
                let described = node.referenceRoles?[port]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (port, described.isEmpty ? "reference image \(index + 1)" : "reference image \(index + 1), which supplies \(described)")
            }
        default: roles = []
        }
        let downstream = descendants(of: enhancerID, in: project)
        return roles.compactMap { role in
            guard let edge = project.edges.first(where: { $0.targetID == node.id && $0.targetPortID == role.port }),
                  !downstream.contains(edge.sourceID), edge.sourceID != enhancerID else { return nil }
            return .init(sourceID: edge.sourceID, sourcePortID: edge.sourcePortID, role: role.role)
        }
    }

    /// Extra run-order constraints: each context picture is produced before the enhancer that
    /// looks at it. These are not wires and are never saved in the document.
    static func orderingDependencies(in project: WorkflowProject) -> [(before: UUID, after: UUID)] {
        project.nodes.filter { $0.kind == .promptEnhancer }.flatMap { enhancer in
            contextSources(of: enhancer.id, in: project).map { (before: $0.sourceID, after: enhancer.id) }
        }
    }

    private static func descendants(of id: UUID, in project: WorkflowProject) -> Set<UUID> {
        var found: Set<UUID> = [], pending = [id]
        while let current = pending.popLast() {
            for edge in project.edges where edge.sourceID == current && found.insert(edge.targetID).inserted { pending.append(edge.targetID) }
        }
        return found
    }

    /// The instruction handed to the local model. `imageRoles` names, in order, each picture
    /// the model is shown; it is empty when the model sees no pictures.
    static func instruction(roughPrompt: String, target: PromptEnhancerTarget, destination: PromptEnhancerDestination?, modelName: String?, imageRoles: [String]) -> String {
        var facts = [target.title]
        if let modelName, !modelName.isEmpty { facts.append("model \(modelName)") }
        if let duration = destination?.durationSeconds, duration > 0 { facts.append(seconds(duration)) }
        if let width = destination?.width, let height = destination?.height, target != .voiceover, target != .general {
            facts.append("\(width)×\(height) \(width > height ? "landscape" : width < height ? "portrait" : "square")")
        }
        var lines = [
            "You are a senior prompt writer for AI image and video models. Rewrite the rough request below as one production-ready prompt for its destination.",
            "",
            "Destination: \(facts.joined(separator: ", "))."
        ]
        if !imageRoles.isEmpty {
            lines.append("")
            for (index, role) in imageRoles.enumerated() { lines.append("Image \(index + 1) is \(role). Look at it carefully and write a prompt that fits what it actually shows.") }
        }
        lines += ["", "Rules for this destination:"]
        lines += target.rules(durationSeconds: destination?.durationSeconds, referenceCount: destination?.referenceCount ?? 0).map { "- \($0)" }
        lines += [
            "",
            "Always:",
            "- The request was typed quickly by a person. Correct spelling mistakes and read loose wording for its most natural meaning in context (for example \"the dog walkign slowley\" means the dog walking slowly). When a misspelling could be more than one word, choose the one that fits the other actions most naturally.",
            "- Keep every subject, action, order of events, number, name, brand and quoted text from the request. Add only concrete detail that supports it; never add new events or change what happens.",
            "- Write plain, present-tense English\(target == .voiceover ? "" : " in one flowing paragraph").",
            "- Return only the finished \(target == .voiceover ? "script" : "prompt"): no title, label, quotation marks around it, markdown, list or explanation.",
            "",
            "Rough request:",
            roughPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return lines.joined(separator: "\n")
    }

    /// Removes reasoning blocks, labels, wrapping quotes and markdown a model may add despite instructions.
    static func clean(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let close = text.range(of: "</think>") { text.removeSubrange(text.startIndex..<close.upperBound) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        let labels = ["enhanced prompt:", "improved prompt:", "final prompt:", "rewritten prompt:", "prompt:", "script:"]
        for label in labels where text.lowercased().hasPrefix(label) {
            text = String(text.dropFirst(label.count)); break
        }
        text = text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close) {
            let inner = text.dropFirst().dropLast()
            if !inner.contains(open) && !inner.contains(close) { text = String(inner).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return text
    }

    /// Identifies one enhancement: the same rough prompt, settings, destination and pictures give
    /// the same fingerprint, so an earlier result can be reused instead of running the model again.
    static func fingerprint(roughPrompt: String, node: StudioNode, target: PromptEnhancerTarget, destination: PromptEnhancerDestination?, images: [URL]) throws -> String {
        var parts = [version, roughPrompt, target.rawValue, node.model, String(node.temperature), String(node.maxTokens)]
        if let destination {
            parts += [destination.kind.rawValue, destination.modelID, destination.width.map(String.init) ?? "", destination.height.map(String.init) ?? "",
                      destination.durationSeconds.map { String($0) } ?? "", destination.fps.map(String.init) ?? "", String(destination.referenceCount)]
        }
        // Pictures by content: an imported image reaches each run as a fresh copy at a new path.
        parts += try images.map { try MediaIdentity.of($0).sha256 }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// One line for the card and inspector, for example "Animate an image · LTX-2.3 · 5.0 s · 512×768".
    static func summary(for node: StudioNode, in project: WorkflowProject, modelName: (String) -> String) -> String {
        let destination = destinations(of: node.id, in: project).first
        let target = node.promptEnhancerTarget ?? destination?.target
        guard let target else { return "Connect the output to an image or video node, or choose what to write for." }
        var parts = ["For \(target.title.lowercased())"]
        if let destination, destination.target == target {
            if !destination.modelID.isEmpty { parts.append(modelName(destination.modelID)) }
            if let duration = destination.durationSeconds, duration > 0 { parts.append("\(number(duration)) s") }
            if let width = destination.width, let height = destination.height { parts.append("\(width)×\(height)") }
        }
        return parts.joined(separator: " · ")
    }

    static func seconds(_ value: Double) -> String { "\(number(value)) seconds" }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value.rounded() == value ? 0 : 1)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
