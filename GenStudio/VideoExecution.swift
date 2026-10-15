import CoreGraphics
import Foundation

/// Runs the video/sequence nodes for ExecutionQueue. Outputs are validated in scratch, then retained immutably.
struct VideoNodeRunner: Sendable {
    let media: MediaProcessor
    let persistence: StudioPersistence
    let engine: (any VideoGenerationEngine)?
    let capabilities: [VideoCapability]
    var scratch: URL { persistence.root.appending(path: "GenerationScratch", directoryHint: .isDirectory) }

    struct Output: Sendable { let value: RuntimeValue; let provenance: RenderedMediaProvenance?; let run: RunRecord? }

    private func retainRendered(_ url: URL) async throws -> (URL, MediaIdentity) {
        defer { try? FileManager.default.removeItem(at: url) }
        let retained = try await media.retain(url)
        return (retained, try MediaIdentity.of(retained))
    }

    func textToVideo(node: StudioNode, projectID: UUID, prompt: String, negativePrompt: String?, compiledPrompt: String? = nil, promptCompilerModelID: String? = nil, onProgress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Output {
        let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: .textToVideo, in: capabilities)
        var request = try VideoRequestPlanner.makeRequest(settings: node.video, task: .textToVideo, capability: capability, prompt: prompt, negativePrompt: negativePrompt)
        request.compiledPrompt = compiledPrompt; request.promptCompilerModelID = promptCompilerModelID
        return try await render(node: node, projectID: projectID, request: request, capability: capability, inputs: [], onProgress: onProgress)
    }

    /// Static graph-edit-time sync (VideoDimensionSync) is only a hint: it cannot know a size
    /// that is decided by running the graph — an upstream generator node, or a different take
    /// selected after the edge was made. So the settings actually used for validation and
    /// preparation are re-derived here from the decoded start image (start wins on a mismatch;
    /// end is the fallback only when start's own dimensions cannot be established), fitted to
    /// the capability's bounds — never from whatever the node happened to be left at.
    private func effectiveSettings(_ settings: VideoGenerationSettings, capability: VideoCapability?, start: CGImage, end: CGImage? = nil) throws -> VideoGenerationSettings {
        var settings = settings
        guard let capability else { return settings }
        let primary = (start.width > 0 && start.height > 0) ? start : end
        guard let primary, primary.width > 0, primary.height > 0 else { return settings }
        let ratio = Double(primary.width) / Double(primary.height)
        guard let fitted = fittedDimensions(ratio: ratio, width: capability.width, height: capability.height, preferredLongestEdge: max(settings.width, settings.height)) else {
            throw StudioError.validation("The selected video recipe cannot preserve the connected source image's \(primary.width)×\(primary.height) aspect ratio within its supported canvas (width \(capability.width.summary), height \(capability.height.summary)). Choose a recipe with compatible dimensions or use a source with a supported aspect ratio.")
        }
        settings.width = fitted.0; settings.height = fitted.1
        return settings
    }

    /// The connected start image is validated, center-cropped to the requested size and hashed before any model loads.
    func imageToVideo(node: StudioNode, projectID: UUID, prompt: String, startImage: URL, compiledPrompt: String? = nil, promptCompilerModelID: String? = nil, onProgress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Output {
        let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: .imageToVideo, in: capabilities)
        let decodedStart = try await media.validateImage(startImage)
        let settings = try effectiveSettings(node.video, capability: capability, start: decodedStart)
        _ = try VideoRequestPlanner.validate(settings: settings, task: .imageToVideo, capability: capability, supplied: [.startImage, .prompt])
        let source = try MediaIdentity.of(startImage)
        let prepared = try await media.aspectFill(startImage, width: settings.width, height: settings.height)
        let input = VideoMediaInput(role: .startImage, identity: try MediaIdentity.of(prepared), location: prepared)
        var request = try VideoRequestPlanner.makeRequest(settings: settings, task: .imageToVideo, capability: capability, prompt: prompt, negativePrompt: nil, mediaInputs: [input])
        request.compiledPrompt = compiledPrompt; request.promptCompilerModelID = promptCompilerModelID
        request.sourceIdentities = [source]
        return try await render(node: node, projectID: projectID, request: request, capability: capability, inputs: [source, input.identity], onProgress: onProgress)
    }

    func firstLastFrame(node: StudioNode, projectID: UUID, prompt: String, startImage: URL, endImage: URL, compiledPrompt: String? = nil, promptCompilerModelID: String? = nil, onProgress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Output {
        let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: .firstLastFrame, in: capabilities)
        let roles: Set<VideoInputRole> = [.startImage, .endImage, .prompt]
        let decodedStart = try await media.validateImage(startImage)
        let decodedEnd = try await media.validateImage(endImage)
        let startRatio = Double(decodedStart.width) / Double(decodedStart.height)
        let endRatio = Double(decodedEnd.width) / Double(decodedEnd.height)
        let relativeRatioDifference = abs(startRatio - endRatio) / startRatio
        guard relativeRatioDifference <= 0.08 else {
            throw StudioError.validation("Start and end images must use the same aspect ratio. They are \(decodedStart.width)×\(decodedStart.height) and \(decodedEnd.width)×\(decodedEnd.height); resize or crop one image before generating so neither endpoint is silently reframed.")
        }
        let settings = try effectiveSettings(node.video, capability: capability, start: decodedStart, end: decodedEnd)
        _ = try VideoRequestPlanner.validate(settings: settings, task: .firstLastFrame, capability: capability, supplied: roles)
        let sources = try [MediaIdentity.of(startImage), MediaIdentity.of(endImage)]
        let preparedStart = try await media.aspectFill(startImage, width: settings.width, height: settings.height)
        let preparedEnd = try await media.aspectFill(endImage, width: settings.width, height: settings.height)
        let inputs = [
            VideoMediaInput(role: .startImage, identity: try MediaIdentity.of(preparedStart), location: preparedStart),
            VideoMediaInput(role: .endImage, identity: try MediaIdentity.of(preparedEnd), location: preparedEnd)
        ]
        var request = try VideoRequestPlanner.makeRequest(settings: settings, task: .firstLastFrame, capability: capability, prompt: prompt, negativePrompt: nil, mediaInputs: inputs)
        request.compiledPrompt = compiledPrompt; request.promptCompilerModelID = promptCompilerModelID
        request.sourceIdentities = sources
        return try await render(node: node, projectID: projectID, request: request, capability: capability, inputs: sources + inputs.map(\.identity), onProgress: onProgress)
    }

    /// MiniMax-H3 Ref2VA consumes a directory of ordered 24 fps reference
    /// frames, not a movie container. Keep the original movie identity for
    /// provenance, extract deterministic frames for the adapter, and clean the
    /// temporary frame directory after the engine has consumed it.
    func videoToVideo(node: StudioNode, projectID: UUID, prompt: String, sourceVideo: URL, compiledPrompt: String? = nil, promptCompilerModelID: String? = nil, onProgress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Output {
        let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: .videoToVideo, in: capabilities)
        _ = try VideoRequestPlanner.validate(settings: node.video, task: .videoToVideo, capability: capability, supplied: [.sourceVideo, .prompt])
        try await media.validateVideo(sourceVideo)
        let source = try MediaIdentity.of(sourceVideo)
        let frameDirectory = try await media.extractVideoFrames(sourceVideo, fps: 24, maxFrames: 600)
        defer { try? FileManager.default.removeItem(at: frameDirectory) }
        let reference = VideoMediaInput(role: .sourceVideo, identity: try MediaIdentity.of(frameDirectory), location: frameDirectory)
        var request = try VideoRequestPlanner.makeRequest(settings: node.video, task: .videoToVideo, capability: capability, prompt: prompt, negativePrompt: nil, mediaInputs: [reference])
        request.compiledPrompt = compiledPrompt; request.promptCompilerModelID = promptCompilerModelID
        request.sourceIdentities = [source]
        return try await render(node: node, projectID: projectID, request: request, capability: capability, inputs: [source, reference.identity], onProgress: onProgress)
    }

    private func render(node: StudioNode, projectID: UUID, request: VideoGenerationRequest, capability: VideoCapability?, inputs: [MediaIdentity], onProgress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Output {
        guard let engine else { throw StudioError.validation("No bundled video engine is available for \(request.task.title).") }
        var run = RunRecord(id: UUID(), snapshot: .init(projectID: projectID, nodeID: node.id, prompt: request.prompt, model: node.model, temperature: 0, maxTokens: 0, engineID: capability?.engineBuild, modelRecipe: ModelCatalog.recipes.first(where: { $0.id == node.model }), imageWidth: request.width, imageHeight: request.height, imageSeed: Int(request.seed), imageSteps: request.steps, videoRequest: request), status: .queued, queuedAt: Date())
        try await persistence.saveRun(run)
        do {
            run.status = .running; run.startedAt = Date(); try await persistence.saveRun(run)
            let generated = try await GenerationProgressContext.$report.withValue(onProgress) { try await engine.generate(request) }
            try Task.checkCancellation()
            let (retained, identity) = try await retainRendered(generated.url)
            let operation: RenderedMediaProvenance.Operation = switch request.task {
            case .textToVideo: .textToVideo
            case .imageToVideo: .imageToVideo
            case .firstLastFrame: .firstLastFrame
            case .videoToVideo: .videoToVideo
            case .timedKeyframes: .textToVideo
            }
            let provenance = RenderedMediaProvenance(operation: operation, output: identity, inputs: inputs, width: generated.probe.width, height: generated.probe.height, fps: request.fps, frameCount: generated.probe.frameCount, duration: generated.probe.duration, lastFrameTimestamp: generated.probe.lastFrameTimestamp, request: request, elapsedSeconds: generated.elapsedSeconds, requestedDurationSeconds: request.requestedDurationSeconds)
            // Record success only after the retained file exists; provenance goes with the run.
            run.snapshot.outputMedia = provenance; run.snapshot.engineLogTail = generated.logTail
            run.status = .succeeded; run.finishedAt = Date()
            try await persistence.saveRun(run)
            return .init(value: .video(retained), provenance: provenance, run: run)
        } catch {
            let cancelled = error is CancellationError
            run.status = cancelled ? .cancelled : .failed; run.finishedAt = Date(); run.error = cancelled ? "Cancelled by user." : error.localizedDescription
            try? await persistence.saveRun(run)
            throw error
        }
    }

    /// Anchor images come from exactly one source each, are retained, and carry a content hash.
    func shotSequence(node: StudioNode, connected: [String: RuntimeValue]) async throws -> Output {
        let spec = node.sequence
        let timing = try SequenceTiming.resolve(spec)
        var anchors: [ResolvedShotSequence.Anchor] = []
        for anchor in spec.anchors {
            try Task.checkCancellation()
            let image: URL
            if let value = connected[anchor.id] {
                guard anchor.imagePath == nil else { throw StudioError.validation("\(anchor.label) has both a connected image and a chosen file.") }
                guard case .image(let url) = value else { throw StudioError.validation("\(anchor.label) requires an image.") }
                _ = try await media.validateImage(url); image = url
            } else if let path = anchor.imagePath {
                let url = URL(fileURLWithPath: path)
                _ = try await media.validateImage(url); image = try await media.retain(url)
            } else { throw StudioError.validation("\(anchor.label) needs an image.") }
            anchors.append(.init(anchorID: anchor.id, label: anchor.label, image: image, identity: try MediaIdentity.of(image), transitionNote: anchor.transitionNote, boundaryToNext: anchor.boundaryToNext))
        }
        return .init(value: .shotSequence(.init(anchors: anchors, timing: timing, width: spec.width, height: spec.height)), provenance: nil, run: nil)
    }

    func animatic(_ sequence: ResolvedShotSequence) async throws -> Output {
        for anchor in sequence.anchors where try MediaIdentity.of(anchor.image) != anchor.identity {
            throw StudioError.validation("\(anchor.label) changed on disk after the sequence was resolved. Run the Shot Sequence again.")
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let output = scratch.appending(path: "animatic-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = try await AnimaticRenderer.render(sequence, to: output)
        try Task.checkCancellation()
        let (retained, identity) = try await retainRendered(output)
        let provenance = RenderedMediaProvenance(operation: .animatic, output: identity, inputs: sequence.anchors.map(\.identity), width: probe.width, height: probe.height, fps: sequence.timing.fps, frameCount: probe.frameCount, duration: sequence.timing.duration, lastFrameTimestamp: sequence.timing.lastFrameTimestamp, timing: sequence.timing)
        return .init(value: .video(retained), provenance: provenance, run: nil)
    }

    func assemble(node: StudioNode, clips: [URL]) async throws -> Output {
        for clip in clips { try await media.validateVideo(clip) }
        var inputs = try clips.map { try MediaIdentity.of($0) }
        // The music file is retained like any imported media, so the run can be reproduced from its record.
        var music: URL?
        if let path = node.assembly.musicPath {
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: source.path) else {
                throw StudioError.validation("\(node.label)'s music file \(source.lastPathComponent) can no longer be read. Choose it again in the inspector.")
            }
            let retained = try await media.retain(source)
            music = retained
            inputs.append(try MediaIdentity.of(retained))
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let output = scratch.appending(path: "assembly-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        // Clips arrive in slot order; each carries its slot's trims, level and incoming transition.
        let slots = node.inputPorts.map(\.id)
        guard slots.count == clips.count else { throw StudioError.validation("\(node.label) received \(clips.count) clips for \(slots.count) slots.") }
        let edited = zip(clips, slots).map { AssemblyClip(url: $0.0, edit: node.assembly.edit(for: $0.1)) }
        let result = try await ClipAssembler.assemble(clips: edited, settings: node.assembly, music: music, to: output)
        try Task.checkCancellation()
        let (retained, identity) = try await retainRendered(output)
        let provenance = RenderedMediaProvenance(operation: .assembly, output: identity, inputs: inputs, width: result.width, height: result.height, fps: result.fps, frameCount: result.probe.frameCount, duration: result.probe.duration, lastFrameTimestamp: result.probe.lastFrameTimestamp, audio: node.assembly.audio, hasAudioTrack: result.hasAudioTrack, assembly: node.assembly.pruned(to: slots))
        return .init(value: .video(retained), provenance: provenance, run: nil)
    }
}
