import Foundation

struct RunPlan: Sendable {
    let textGenerations: Int
    let imageGenerations: Int
    let knownImageBaselineSeconds: Double
    let unknownGenerations: Int
    var videoGenerations = 0
    /// Video work whose cost was measured on this Mac and can be scaled to the node's own settings: Wan 2.1 clips,
    /// video upscales, and routes with recorded speed anchors (FastMetal, LTX-2.3).
    var estimatedVideoSeconds = 0.0
    /// Video work with no measured timing. It can run for up to an hour, so it is never started silently.
    var untimedVideoGenerations = 0
    /// Labels of nodes using a final-quality model: slow here by choice, named before the run starts.
    var finalQualityNodes: [String] = []
    /// Ask when the measured work adds up to more than five minutes, or when video work has no measured timing.
    /// A quick measured draft just runs.
    var requiresConfirmation: Bool { knownImageBaselineSeconds + estimatedVideoSeconds > 300 || untimedVideoGenerations > 0 || !finalQualityNodes.isEmpty }
    var summary: String {
        let measured = knownImageBaselineSeconds + estimatedVideoSeconds
        let estimate = measured > 0 ? "Measured work adds up to roughly \(Self.duration(measured))." : "No measured timing applies to this graph."
        let unknown = unknownGenerations > 0 ? " \(unknownGenerations) generation(s) have no timing yet and are not included." : ""
        let finals = finalQualityNodes.isEmpty ? "" : " \(finalQualityNodes.count == 1 ? "1 node uses a final-quality model" : "\(finalQualityNodes.count) nodes use final-quality models") (\(finalQualityNodes.joined(separator: ", "))): slow by design, for the best output."
        return "\(textGenerations) text, \(imageGenerations) image and \(videoGenerations) video generation(s), counting shared ancestors once. \(estimate)\(unknown)\(finals) Load, validation and export overhead are extra. Local generation can run for up to one hour per node; cancel at any time."
    }
    private static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }

    /// Wan 2.1 T2V at 320×192: about 7.0 s per frame at 4 steps, +0.18 s per extra step, scaling with pixels
    /// (docs/evidence/video-benchmark-m1max-2026-09-18.md). An estimate, not a promise.
    static func wanSeconds(_ video: VideoGenerationSettings) -> Double {
        let perFrame = 7.0 + 0.18 * Double(max(0, video.steps - 4))
        return Double(video.frameCount) * perFrame * Double(video.width * video.height) / Double(320 * 192)
    }
    /// Real-ESRGAN 4×: 11.15 s per frame from a 320×192 source, scaling with source pixels.
    static func upscaleSeconds(frames: Int, width: Int, height: Int) -> Double {
        Double(frames) * 11.15 * Double(width * height) / Double(320 * 192)
    }
    /// Every node the target depends on transitively, target included. A node locked as final is not included and
    /// nothing behind it is: its saved file is used as it is, so it costs no work.
    static func reachableNodes(project: WorkflowProject, target: UUID) -> [StudioNode] {
        let byID = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
        var included: Set<UUID> = [target], pending = [target]
        while let id = pending.popLast() {
            for edge in project.edges where edge.targetID == id {
                if byID[edge.sourceID]?.isLockedFinal == true { continue }
                if included.insert(edge.sourceID).inserted { pending.append(edge.sourceID) }
            }
        }
        return project.nodes.filter { included.contains($0.id) }
    }

    /// Every node a "Run All" should target: the graph's own end points (nothing downstream
    /// depends on them), skipping nodes already locked as final and non-runnable annotations.
    /// Sinks can never depend on one another, so the only ordering that matters is visual —
    /// left-to-right, top-to-bottom — which `CanvasInteraction.navigationOrder` already gives.
    static func wholeWorkflowTargets(project: WorkflowProject) -> [UUID] {
        let hasOutgoingEdge = Set(project.edges.map(\.sourceID))
        let eligible = Set(project.nodes.filter { node in
            !hasOutgoingEdge.contains(node.id) && !node.isLockedFinal && node.kind != .stickyNote
                && (!node.inputPorts.isEmpty || !node.outputPorts.isEmpty)
        }.map(\.id))
        guard !eligible.isEmpty else { return [] }
        return CanvasInteraction.navigationOrder(nodes: project.nodes, edges: project.edges).filter { eligible.contains($0) }
    }

    static func make(project: WorkflowProject, target: UUID) -> RunPlan {
        make(project: project, nodes: reachableNodes(project: project, target: target))
    }

    /// Every node reachable from any of `targets`, counting shared ancestors once. Used to show
    /// one confirmation for a whole-workflow run instead of one per target.
    static func make(project: WorkflowProject, targets: [UUID]) -> RunPlan {
        var seen: Set<UUID> = [], nodes: [StudioNode] = []
        for target in targets {
            for node in reachableNodes(project: project, target: target) where seen.insert(node.id).inserted {
                nodes.append(node)
            }
        }
        return make(project: project, nodes: nodes)
    }

    private static func make(project: WorkflowProject, nodes: [StudioNode]) -> RunPlan {
        let authoredTextRuns = nodes.filter { $0.kind == .textModel || $0.kind == .promptEnhancer || $0.kind == .imageDescriber }.count
        // LingBot benefits from a local recipe-specific semantic compile before its deterministic
        // JSON formatter. Count it so the confirmation never hides that extra local model pass.
        let promptCompilerRuns = nodes.filter { $0.kind.videoTask != nil && $0.model == MediaModelCatalog.lingBotRecipeID }.count
        let text = authoredTextRuns + promptCompilerRuns
        let images = nodes.filter { $0.kind == .imageGenerator }
        let measured = images.filter { $0.model == "sd15-q4" && $0.width == 512 && $0.height == 512 }.count
        let videos = nodes.filter { $0.kind.videoTask != nil }.count
        let upscales = nodes.filter { $0.kind == .imageUpscale || $0.kind == .videoUpscale }.count
        var videoSeconds = 0.0, timedVideos = 0, untimedVideos = 0
        for node in nodes {
            guard let task = node.kind.videoTask else { continue }
            if task == .textToVideo && node.model == VideoCapabilityRegistry.wanT2VRecipeID {
                videoSeconds += wanSeconds(node.video); timedVideos += 1
            } else if let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: task),
                      let seconds = VideoTimeEstimate.seconds(node.video, capability: capability) {
                // FastMetal and LTX: scaled from takes timed on this Mac (VideoCapability.speedAnchors).
                videoSeconds += seconds; timedVideos += 1
            } else { untimedVideos += 1 }
        }
        for node in nodes where node.kind == .videoUpscale {
            let source = project.edges.first { $0.targetID == node.id }.flatMap { edge in nodes.first { $0.id == edge.sourceID } }
            if let source, source.kind == .textToVideo, source.model == VideoCapabilityRegistry.wanT2VRecipeID {
                videoSeconds += upscaleSeconds(frames: source.video.frameCount, width: source.video.width, height: source.video.height); timedVideos += 1
            } else { untimedVideos += 1 }
        }
        return .init(textGenerations: text, imageGenerations: images.count, knownImageBaselineSeconds: Double(measured) * 94.14, unknownGenerations: text + images.count - measured + videos + upscales - timedVideos, videoGenerations: videos, estimatedVideoSeconds: videoSeconds, untimedVideoGenerations: untimedVideos,
                     finalQualityNodes: nodes.filter { !$0.model.isEmpty && MacFitStandard.finalQuality(recipeID: $0.model) != nil }.map(\.label))
    }
}

struct PendingRun: Identifiable {
    let id = UUID()
    let project: WorkflowProject
    let targetID: UUID
    let plan: RunPlan
    /// One of a "Generate N takes" batch: the same node may wait in the queue more than once.
    var isBatchTake = false
}

/// Backslash escapes accepted in single-line text settings such as separators and delimiters. A one-line field
/// cannot hold a real line break, so `\n`, `\t`, `\r` and `\\` stand for them. Everything else is kept as typed.
enum TextEscapes {
    static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = "", pending = false
        for character in text {
            if pending {
                pending = false
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                default: result.append("\\"); result.append(character)
                }
            } else if character == "\\" { pending = true } else { result.append(character) }
        }
        if pending { result.append("\\") }
        return result
    }
}

enum TextArrayOperations {
    static func split(_ text: String, delimiter: String, trim: Bool) throws -> [String] {
        let delimiter = TextEscapes.unescape(delimiter)
        guard !delimiter.isEmpty else { throw StudioError.validation("Text Array delimiter cannot be empty.") }
        guard text.utf8.count <= 1_000_000 else { throw StudioError.validation("Text Array accepts at most 1 MB of text.") }
        guard !text.isEmpty else { return [] }
        let items = text.split(separator: delimiter, maxSplits: 256, omittingEmptySubsequences: false).map(String.init)
        guard items.count <= 256 else { throw StudioError.validation("Text Array supports at most 256 items.") }
        return trim ? items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } : items
    }
}

/// Turns a number into prompt text. The result is fed to models, so it must not depend on the Mac's region:
/// a South African or German locale would otherwise write 0.75 as "0,75".
enum NumberText {
    private static let style = FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
        .grouping(.never).precision(.fractionLength(0...15))
    static func string(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return (value == 0 ? 0 : value).formatted(style)
    }
}

/// `{{name}}` substitution for the Prompt Template node.
enum PromptTemplateSyntax {
    private static let expression = try! NSRegularExpression(pattern: #"\{\{([^{}]*)\}\}"#)

    private static func matches(in template: String) -> [(range: NSRange, name: String)] {
        let text = template as NSString
        return expression.matches(in: template, range: NSRange(location: 0, length: text.length)).map {
            ($0.range, text.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Names the template uses, trimmed, in order of first use.
    static func variables(in template: String) -> [String] {
        var seen = Set<String>()
        return matches(in: template).map(\.name).filter { seen.insert($0).inserted }
    }

    static func render(_ template: String, values: [String: String], label: String) throws -> String {
        let rendered = NSMutableString(string: template)
        for match in matches(in: template).reversed() {
            guard !match.name.isEmpty else { throw StudioError.validation("\(label) has an empty {{ }} variable. Name the variable or remove the braces.") }
            guard let replacement = values[match.name] else { throw StudioError.validation("\(label) has an unresolved template variable named \(match.name).") }
            rendered.replaceCharacters(in: match.range, with: replacement)
        }
        return rendered as String
    }

    /// Renames every use of `old` in the template so a renamed input never orphans its `{{ }}` reference.
    static func renaming(_ old: String, to new: String, in template: String) -> String {
        let rendered = NSMutableString(string: template)
        for match in matches(in: template).reversed() where match.name == old {
            rendered.replaceCharacters(in: match.range, with: "{{\(new)}}")
        }
        return rendered as String
    }

    /// Everything that would make the template fail, found before any model loads.
    static func issue(for node: StudioNode, connectedPorts: Set<String>) -> String? {
        let ports = node.inputPorts
        guard Set(ports.map(\.label)).count == ports.count else { return "\(node.label) has duplicate template variable names. Rename each variable uniquely." }
        let byName = Dictionary(uniqueKeysWithValues: ports.map { ($0.label, $0) })
        for name in variables(in: node.prompt) {
            guard !name.isEmpty else { return "\(node.label) has an empty {{ }} variable. Name the variable or remove the braces." }
            guard let port = byName[name] else { return "\(node.label) uses {{\(name)}} but has no input named \(name). Fix the spelling or rename an input." }
            guard connectedPorts.contains(port.id) else { return "\(node.label) uses {{\(name)}} but its \(name) input is not connected." }
        }
        return nil
    }
}
