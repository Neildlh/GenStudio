import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inspector controls for video generation, sequencing and assembly nodes. Edits go through undoable graph changes.
struct VideoNodeInspector: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode

    private var current: StudioNode { model.currentProject?.nodes.first { $0.id == node.id } ?? node }
    private var connectedPorts: Set<String> { Set(model.currentProject?.edges.filter { $0.targetID == node.id }.map(\.targetPortID) ?? []) }

    var body: some View {
        if current.kind == .guidedShot {
            unavailable
        } else if let task = current.kind.videoTask {
            // Every model-backed video generation kind shares this duration/capability path.
            generation(task)
        } else {
            switch current.kind {
            case .shotSequence: ShotSequenceInspector(model: model, node: current)
            case .animatic: animatic
            case .assembleVideo: StitcherInspector(model: model, node: current)
            default: EmptyView()
            }
        }
    }

    private func setting<T>(_ keyPath: WritableKeyPath<StudioNode, T>) -> Binding<T> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in model.updateNodeFromBinding(node.id) { $0[keyPath: keyPath] = value } })
    }

    @ViewBuilder private var readiness: some View {
        if let issue = VideoPreflight.generationIssue(current, connectedPorts: connectedPorts, installed: model.libraryStore.installed, registry: VideoCapabilityRegistry.shipped) {
            Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        } else {
            Label("Ready to run with the connected inputs.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
        }
    }

    private func recipeTitle(_ id: String) -> String { ModelCatalog.recipes.first { $0.id == id }.map(ModelRecipePresentation.title) ?? id }
    /// Why a listed recipe cannot run right now, or nil.
    private func blocker(_ capability: VideoCapability) -> String? {
        guard let installed = model.libraryStore.installed.first(where: { $0.id == capability.recipeID }) else { return "not installed" }
        guard installed.available else { return "files missing" }
        return nil
    }

    @ViewBuilder private func generation(_ task: VideoTask) -> some View {
        let installedModels = model.libraryStore.installed
        let capabilities = VideoCapabilityRegistry.selectableCapabilities(for: task)
            .filter { capability in
                installedModels.contains { installed in
                    installed.id == capability.recipeID && installed.available
                }
            }
            .sorted { left, right in
            func state(_ capability: VideoCapability) -> Int {
                guard let installed = installedModels.first(where: { $0.id == capability.recipeID }), installed.available else { return 2 }
                return capability.readiness.proven || installed.hasVerifiedVideoTask(task) ? 0 : 1
            }
            let lhs = state(left), rhs = state(right)
            if lhs != rhs { return lhs < rhs }
            return VideoCapabilityRegistry.recommendationPriority(left) < VideoCapabilityRegistry.recommendationPriority(right)
        }
        readiness
        if capabilities.isEmpty {
            Text("No installed model supports this video task. Install a compatible model in Model Library.").font(.caption)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
        Picker("Model", selection: Binding(get: { current.model }, set: { id in
            model.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                project.nodes[index].model = id
                // Adopt the recipe's documented defaults without discarding the duration the user chose.
                if let capability = VideoCapabilityRegistry.capability(recipeID: id, task: task) {
                    project.nodes[index].video = capability.recommendedSettings(preservingDurationFrom: project.nodes[index].video)
                }
                // The new recipe's bounds may no longer fit a size chosen for the previous one.
                VideoDimensionSync.resyncNode(node.id, in: &project)
            }
        })) {
            Text("Choose an installed model").tag("")
            if !current.model.isEmpty, !capabilities.contains(where: { $0.recipeID == current.model }) {
                Text("\(recipeTitle(current.model)) · unavailable saved selection").tag(current.model)
            }
            ForEach(capabilities) { capability in
                Text("\(recipeTitle(capability.recipeID)) · \(blocker(capability) ?? "ready")\(ModelAdvisor.pickerNote(capability.recipeID))").tag(capability.recipeID)
            }
        }
        .disabled(capabilities.isEmpty)
        Button(model.isDefaultModel(current) ? "Default" : "Set as default") { model.setDefaultModel(for: current) }
            .buttonStyle(.borderless)
            .disabled(current.model.isEmpty || !capabilities.contains(where: { $0.recipeID == current.model }))
        }
        FinalQualityBadge(recipeID: current.model)
        ForEach(capabilities.filter { blocker($0) != nil }) { capability in
            Text("\(recipeTitle(capability.recipeID)): \(blocker(capability)!).").font(.callout).foregroundStyle(.secondary)
        }
        if let capability = VideoCapabilityRegistry.capability(recipeID: current.model, task: task) {
            if capability.recipeID == MediaModelCatalog.minimaxH3RecipeID,
               model.libraryStore.installed.contains(where: { $0.id == MediaModelCatalog.minimaxH3Ref2VARecipeID && $0.available }),
               !model.libraryStore.installed.contains(where: { $0.id == MediaModelCatalog.minimaxH3RecipeID && $0.available }) {
                Label("MiniMax-H3 Ref2VA is installed, but it is the separate Video-to-Video transformer. This node requires the FL2VA transformer; GenStudio cannot substitute Ref2VA for image, text, or start/end generation.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text(capability.qualityNote).font(.callout).foregroundStyle(.secondary)
            if (task == .videoToVideo) || (task == .imageToVideo && capability.recipeID == MediaModelCatalog.wan22TI2VRecipeID) || task == .firstLastFrame {
                let recipe = ModelCatalog.recipes.first { $0.id == capability.recipeID }
                let title = task == .firstLastFrame ? "Local start/end animation" : task == .videoToVideo ? "Local video-to-video editing" : "Local image animation"
                GroupBox(title) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task == .firstLastFrame
                             ? "Connect a Start Image, End Image and Transition prompt. The complete pinned package is \(recipe.map { ModelLibraryViewModel.bytes($0.totalBytes) } ?? "16.5 GB"); shared installed Wan components can reduce the new transfer to about 12.6 GB."
                             : task == .videoToVideo
                             ? "Connect a Source Clip and an Edit Prompt. GenStudio extracts ordered 24 fps PNG reference frames, then passes them to MiniMax-H3 Ref2VA. The complete pinned package is \(recipe.map { ModelLibraryViewModel.bytes($0.totalBytes) } ?? "34.9 GB"). Audio from the source and generated soundtrack are not preserved yet."
                             : "Connect one Start Image and a Motion Prompt. The complete exact pinned package is \(recipe.map { ModelLibraryViewModel.bytes($0.totalBytes) } ?? "8.5 GB").")
                        Text(task == .videoToVideo
                             ? "Reference clips are limited to 600 frames (25 seconds at 24 fps) so a mistaken long movie cannot exhaust storage. The starter preset is conservative; memory, speed and edit quality are unmeasured on this Mac."
                             : "The starter preset is intentionally conservative. Generation time, peak memory and output quality have not been measured on this Mac; the engine offloads model work to CPU memory where supported.")
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            AspectRatioPicker(currentWidth: current.video.width, currentHeight: current.video.height) { preset in
                guard let size = preset.dimensions(width: capability.width, height: capability.height, targetPixels: capability.optimalPixels) else { return }
                model.updateNode(node.id) { current in current.video.width = size.0; current.video.height = size.1 }
            }
            RatioLockToggle(locked: current.ratioLocked) { on in model.updateNodeFromBinding(node.id) { $0.ratioLocked = on } }
            dimensionControl("Width", keyPath: \.video.width, value: current.video.width, bounds: capability.width, changedWidth: true, capability: capability)
            dimensionControl("Height", keyPath: \.video.height, value: current.video.height, bounds: capability.height, changedWidth: false, capability: capability)
            if capability.recipeID == MediaModelCatalog.lingBotRecipeID {
                HStack {
                    Button("Economy portrait 256×448") { model.updateNode(node.id) { $0.video.width = 256; $0.video.height = 448 } }
                    Button("Quality portrait 448×800") { model.updateNode(node.id) { $0.video.width = 448; $0.video.height = 800 } }
                }
                Text("Start with Economy. Switch to Quality only after the motion and seed are worth keeping.").font(.caption).foregroundStyle(.secondary)
            }
            durationControl(capability)
            qualityControl(capability)
            if capability.supportsFastDraft {
                Toggle("Fast draft", isOn: Binding(get: { current.video.fastDraft == true },
                                                   set: { on in model.updateNodeFromBinding(node.id) { $0.video.fastDraft = on ? true : nil } }))
                Text("Renders every second frame and interpolates the rest: about twice as fast, slightly softer. Same length and frame rate. Use it to explore prompts and motion, then turn it off for the keeper.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if capability.producesAudio {
                Toggle("Sound", isOn: Binding(get: { current.video.sound != false },
                                              set: { on in model.updateNodeFromBinding(node.id) { $0.video.sound = on ? nil : false } }))
                if model.libraryStore.ltxNeedsSoundFiles {
                    LTXSoundFilesRow(store: model.libraryStore)
                } else {
                    Text("Sound is generated with the picture. Describe it in the prompt: the setting's ambience, music, or a short spoken line in quotes. Turn Sound off to keep this clip silent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let estimate = VideoTimeEstimate.seconds(current.video, capability: capability) {
                Label("Estimated on this Mac: \(VideoTimeEstimate.label(estimate)) per take", systemImage: "clock")
                    .font(.callout)
                Text(capability.supportsFastDraft
                     ? "From runs measured here; a busy Mac is slower. A new prompt adds about 40 s once."
                     : "From runs measured here; a busy Mac is slower.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if current.video.frameCount > capability.recommended.frameCount || current.video.fps > capability.recommended.fps {
                let multiplier = Double(current.video.frameCount * current.video.steps * current.video.width * current.video.height) /
                    Double(max(1, capability.recommended.frameCount * capability.recommended.steps * capability.recommended.width * capability.recommended.height))
                Label("Expensive generation: approximately \(multiplier.formatted(.number.precision(.fractionLength(1))))× the recipe preview workload. Shorten the clip, lower the detail or reduce the size before testing motion.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper("Generated frame rate: \(current.video.fps) fps", value: fpsBinding(capability), in: capability.fps.minimum...capability.fps.maximum)
                    Text("Chosen for you from the clip length. This is how many frames the model draws per second of video, not the playback rate; connect Frame Interpolation for smooth playback.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Steps: \(current.video.steps)", value: setting(\.video.steps), in: capability.steps.minimum...capability.steps.maximum)
                    Text("Steps are refinement passes per frame, set by the Detail level above. More steps add detail and cost little extra time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            TextField("Guidance scale", value: setting(\.video.cfgScale), format: .number)
            if capability.usesFlowShift { TextField("Flow shift", value: setting(\.video.flowShift), format: .number) }
            if let bounds = capability.strength {
                FullWidthInspectorSlider(
                    title: "Start image strength",
                    valueText: (current.video.strength ?? ImageCapabilityRegistry.defaultStrength).formatted(.number.precision(.fractionLength(2))),
                    value: Binding(get: { current.video.strength ?? ImageCapabilityRegistry.defaultStrength }, set: { value in model.updateNodeFromBinding(node.id) { $0.video.strength = value } }),
                    range: bounds.minimum...bounds.maximum
                )
            }
            GenerationSeedControls(model: model, node: node)
            if node.seedLocked { TextField("Seed (−1 = random, recorded)", value: setting(\.video.seed), format: .number.grouping(.never)) }
            if task == .imageToVideo { Text("The canvas follows the connected start image's aspect ratio within this recipe's supported sizes. The actual selected take is checked again at run time; incompatible ratios stop with an explanation instead of being silently cropped. Original and prepared image hashes are recorded.").font(.caption).foregroundStyle(.secondary) }
            if task == .firstLastFrame { Text("The start image sets the canvas aspect ratio within this recipe's supported sizes. The end image is prepared to the same canvas; incompatible source ratios stop with an explanation instead of being silently cropped. Original and prepared hashes are recorded.").font(.callout).foregroundStyle(.secondary) }
            if task == .videoToVideo { Text("The source clip is retained by content hash. Its extracted reference frames are supplied at 24 fps; the generated output uses the selected dimensions and frame count, so it is a new clip rather than an in-place edit.").font(.callout).foregroundStyle(.secondary) }
            if let baseline = capability.measuredBaseline { Text(baseline).font(.callout).foregroundStyle(.secondary) }
        }
        if task == .textToVideo {
            Text("Negative prompt").font(.headline)
            TextEditor(text: setting(\.video.negativePrompt)).frame(minHeight: 60)
            if connectedPorts.contains("negativePrompt") { Text("The connected Negative input replaces this text for the run.").font(.caption).foregroundStyle(.secondary) }
        }
        HStack {
            Button("Open Model Library") { model.sidebarSection = .models }
            Button("Refresh") { Task { await model.refreshModels() } }
        }
        Text("Runs locally through the bundled stable-diffusion.cpp build. Output frames are encoded, decoded and validated before they are kept. A recipe for one video task is never used for another.").font(.callout).foregroundStyle(.secondary)
    }

    private func fpsBinding(_ capability: VideoCapability) -> Binding<Int> {
        Binding(get: { current.video.fps }, set: { fps in
            model.updateNodeFromBinding(node.id) { current in
                current.video.fps = fps
                _ = try? VideoDurationResolver.apply(to: &current.video, rule: capability.frames)
            }
        })
    }

    private func setLength(_ seconds: Double, _ capability: VideoCapability) {
        model.updateNodeFromBinding(node.id) { current in
            current.video.requestedDurationSeconds = seconds
            current.video.fps = VideoLengthPlanner.fps(forSeconds: seconds, capability: capability)
            _ = try? VideoDurationResolver.apply(to: &current.video, rule: capability.frames)
        }
    }

    @ViewBuilder private func durationControl(_ capability: VideoCapability) -> some View {
        if let range = VideoLengthPlanner.secondsRange(capability),
           let resolved = try? VideoDurationResolver.resolve(requestedSeconds: current.video.requestedDurationSeconds, fps: current.video.fps, rule: capability.frames) {
            VStack(alignment: .leading, spacing: 5) {
                FullWidthInspectorSlider(
                    title: "Video length",
                    valueText: String(format: "%.1f seconds", locale: Locale(identifier: "en_US_POSIX"), min(range.upperBound, max(range.lowerBound, current.video.requestedDurationSeconds))),
                    value: Binding(get: { min(range.upperBound, max(range.lowerBound, current.video.requestedDurationSeconds)) }, set: { setLength($0, capability) }),
                    range: range,
                    step: 0.5
                )
                Text("Draws \(resolved.frameCount) frames at \(resolved.fps) fps.")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let explanation = VideoDurationPresentation.snappingExplanation(resolved, rule: capability.frames) {
                    Text(explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func qualityControl(_ capability: VideoCapability) -> some View {
        let levels = VideoQualityLevel.available(capability)
        if levels.count > 1 {
            let level = VideoQualityLevel.nearest(steps: current.video.steps, capability: capability)
            let index = levels.firstIndex(of: level) ?? 0
            VStack(alignment: .leading, spacing: 5) {
                FullWidthInspectorSlider(
                    title: "Detail",
                    valueText: level.title,
                    value: Binding(get: { Double(index) }, set: { value in
                        let picked = levels[min(levels.count - 1, max(0, Int(value.rounded())))]
                        model.updateNodeFromBinding(node.id) { $0.video.steps = picked.steps(capability) }
                    }),
                    range: 0...Double(levels.count - 1),
                    step: 1
                )
                Text("\(levels.map(\.title).joined(separator: " · ")) — more detail refines each frame further and costs a little more time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Detail", value: "Fixed by this model")
        }
    }

    private func setDimension(_ raw: Int, changedWidth: Bool, keyPath: WritableKeyPath<StudioNode, Int>, capability: VideoCapability) {
        model.updateNodeFromBinding(node.id) { n in
            guard n.ratioLocked else { n[keyPath: keyPath] = raw; return }
            let size = RatioLock.resolve(changedWidth: changedWidth, raw: raw, currentWidth: n.video.width, currentHeight: n.video.height, widthBounds: capability.width, heightBounds: capability.height)
            n.video.width = size.width; n.video.height = size.height
        }
    }

    @ViewBuilder private func dimensionControl(_ title: String, keyPath: WritableKeyPath<StudioNode, Int>, value: Int, bounds: IntegerBounds, changedWidth: Bool, capability: VideoCapability) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text("px").foregroundStyle(.secondary)
            }
            TextField("Enter \(title.lowercased())", value: Binding(get: { current[keyPath: keyPath] }, set: { setDimension($0, changedWidth: changedWidth, keyPath: keyPath, capability: capability) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 34)
                .font(.body.monospacedDigit())
            FullWidthInspectorSlider(
                title: "Adjust \(title.lowercased())",
                valueText: "\(value) px",
                value: Binding(get: { Double(value) }, set: { newValue in
                    let raw = Int(newValue.rounded())
                    let snapped = min(bounds.maximum, max(bounds.minimum, (raw / bounds.multiple) * bounds.multiple))
                    setDimension(snapped, changedWidth: changedWidth, keyPath: keyPath, capability: capability)
                }),
                range: Double(bounds.minimum)...Double(bounds.maximum),
                step: Double(bounds.multiple)
            )
        }
    }

    @ViewBuilder private var unavailable: some View {
        let task = current.kind.videoTask ?? .videoToVideo
        Label("Unavailable — no adapter in this version", systemImage: "nosign").foregroundStyle(.orange).font(.headline)
        Text(VideoCapabilityRegistry.unavailableReason(for: task)).font(.callout)
        Text("You can author and connect this node. It will not run, will not substitute Text to Video or an animatic, and connected inputs are never dropped.").font(.callout).foregroundStyle(.secondary)
        ForEach(current.inputPorts) { port in
            LabeledContent(port.label, value: connectedPorts.contains(port.id) ? "Connected" : port.required ? "Required" : "Optional")
        }
        if current.kind == .guidedShot {
            VStack(alignment: .leading, spacing: 6) {
                Text("What is missing").font(.headline)
                Text("This node must send every ordered Shot Sequence image, its resolved frame index and its strength to one video diffusion job. The current bundled engine has no such command. LTX-2's KeyframeInterpolationPipeline is the candidate backend, but its runtime integration and a decoded proof on this Mac still need to be added.").font(.callout).foregroundStyle(.secondary)
                Label("Available now: Shot Sequence → Animatic for timing, or separate Start/End Video transitions followed by the Stitcher.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                Label("Do not install a model solely to unlock this node: weights without the adapter cannot execute it.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var animatic: some View {
        Text("Deterministic preview: each frame is held for its authored time with hard cuts. No AI motion is generated. Transition notes and cut/continuous choices are recorded in the sequence, not animated.").font(.caption).foregroundStyle(.secondary)
        provenance
    }

    @ViewBuilder private var provenance: some View {
        if let record = (node.supportsTakes ? model.selectedTake(for: node) : model.executionArtifacts.first(where: { $0.graphSnapshot.id == model.currentProjectID && $0.mediaProvenance?[node.id] != nil }))?.mediaProvenance?[node.id] {
            let requested = record.requestedDurationSeconds.map { "requested \(seconds($0)); " } ?? ""
            let durationLabel = record.requestedDurationSeconds == nil ? "duration" : "generated duration"
            Text("Last output: \(requested)\(record.width)×\(record.height), \(record.frameCount) frames at \(record.fps) fps, \(durationLabel) \(seconds(record.duration))\(record.lastFrameTimestamp.map { "; last frame at \(seconds($0))" } ?? "")\(record.operation == .assembly ? record.hasAudioTrack ? "; audio track kept" : "; no audio track" : "").").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func seconds(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(3)))) s" }

struct ShotSequenceInspector: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode
    private var connected: Set<String> { Set(model.currentProject?.edges.filter { $0.targetID == node.id }.map(\.targetPortID) ?? []) }

    var body: some View {
        let spec = node.sequence
        HStack {
            Button("Add Images…") { chooseImages() }
            Button("Add Empty Frame") { model.addSequenceFrames(nodeID: node.id, imagePaths: [nil]) }
        }.disabled(spec.anchors.count >= ShotSequenceSpec.maximumAnchors)
        Stepper("Output: \(spec.fps) fps", value: binding(\.sequence.fps), in: 1...60)
        Stepper("Width: \(spec.width) px", value: binding(\.sequence.width), in: 16...4096, step: 2)
        Stepper("Height: \(spec.height) px", value: binding(\.sequence.height), in: 16...4096, step: 2)
        TextField("Final hold (seconds)", value: binding(\.sequence.finalHoldSeconds), format: .number)
        switch Result(catching: { try SequenceTiming.resolve(spec) }) {
        case .success(let timing):
            Text("\(spec.anchors.count) frames · \(timing.frameCount) samples at \(timing.fps) fps · duration \(seconds(timing.duration)) · last frame at \(seconds(timing.lastFrameTimestamp))").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(spec.anchors.enumerated()), id: \.element.id) { index, anchor in
                anchorRow(anchor, index: index, count: spec.anchors.count, timing: timing.anchors.first { $0.anchorID == anchor.id })
            }
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            ForEach(Array(spec.anchors.enumerated()), id: \.element.id) { index, anchor in anchorRow(anchor, index: index, count: spec.anchors.count, timing: nil) }
        }
        if let issue = VideoPreflight.sequenceIssue(node, connectedPorts: connected) { Text(issue).font(.caption).foregroundStyle(.orange) }
        Text("Frame slots keep their identity when reordered, so connections stay with the same image. Transition notes are planning directions, not a prompt schedule.").font(.caption).foregroundStyle(.secondary)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<StudioNode, T>) -> Binding<T> {
        Binding(get: { (model.currentProject?.nodes.first { $0.id == node.id } ?? node)[keyPath: keyPath] }, set: { value in model.updateNodeFromBinding(node.id) { $0[keyPath: keyPath] = value } })
    }
    private func anchorBinding<T>(_ anchor: ShotAnchor, _ keyPath: WritableKeyPath<ShotAnchor, T>) -> Binding<T> {
        Binding(get: { (model.currentProject?.nodes.first { $0.id == node.id }?.sequence.anchors.first { $0.id == anchor.id } ?? anchor)[keyPath: keyPath] },
                set: { value in model.updateSequenceFrame(nodeID: node.id, anchorID: anchor.id) { $0[keyPath: keyPath] = value } })
    }

    private func anchorRow(_ anchor: ShotAnchor, index: Int, count: Int, timing: ResolvedAnchorTiming?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Group {
                    if let url = model.sequenceImage(nodeID: node.id, anchor: anchor) { LocalImageThumbnail(url: url) }
                    else { Image(systemName: "photo.badge.plus").foregroundStyle(.secondary) }
                }.frame(width: 56, height: 42)
                VStack(alignment: .leading) {
                    TextField("Label", text: anchorBinding(anchor, \.label))
                    Text(timing.map { "\(index + 1). starts \(seconds($0.authoredTime)) · samples \($0.startFrame)–\($0.endFrame - 1)" } ?? "\(index + 1). timing unresolved").font(.caption).foregroundStyle(.secondary)
                }
                VStack {
                    Button { model.moveSequenceFrame(nodeID: node.id, anchorID: anchor.id, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel("Move \(anchor.label) earlier")
                    Button { model.moveSequenceFrame(nodeID: node.id, anchorID: anchor.id, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1).accessibilityLabel("Move \(anchor.label) later")
                }.buttonStyle(.borderless)
            }
            if connected.contains(anchor.id) {
                Text("Image: connected socket").font(.caption).foregroundStyle(.secondary)
                if anchor.imagePath != nil { Button("Clear chosen file (a connected image is also present)") { model.updateSequenceFrame(nodeID: node.id, anchorID: anchor.id) { $0.imagePath = nil } }.foregroundStyle(.orange) }
            } else {
                HStack {
                    Text(anchor.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image").font(.caption).lineLimit(1)
                    Spacer()
                    Button("Choose…") { chooseImage(for: anchor) }
                }
            }
            if index < count - 1 {
                TextField("Hold before next (seconds)", value: anchorBinding(anchor, \.holdSeconds), format: .number)
                TextField("Direction toward next frame", text: anchorBinding(anchor, \.transitionNote))
                Picker("Boundary", selection: anchorBinding(anchor, \.boundaryToNext)) { Text("Continuous").tag(ShotBoundary.continuous); Text("Cut").tag(ShotBoundary.cut) }.pickerStyle(.segmented)
            } else {
                Text("Last frame: held for the final hold.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Remove Frame", role: .destructive) { model.removeSequenceFrame(nodeID: node.id, anchorID: anchor.id) }
        }.padding(.vertical, 4)
    }

    private func chooseImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        model.addSequenceFrames(nodeID: node.id, imagePaths: panel.urls.map(\.path))
    }
    private func chooseImage(for anchor: ShotAnchor) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateSequenceFrame(nodeID: node.id, anchorID: anchor.id) { $0.imagePath = url.path }
    }
}

extension StudioModel {
    /// Thumbnail source for a frame slot: the connected upstream image when wired, otherwise its chosen file.
    func sequenceImage(nodeID: UUID, anchor: ShotAnchor) -> URL? {
        guard let project = currentProject else { return nil }
        if let edge = project.edges.first(where: { $0.targetID == nodeID && $0.targetPortID == anchor.id }), let source = project.nodes.first(where: { $0.id == edge.sourceID }) {
            if source.kind == .imageInput, let path = source.imagePath { return URL(fileURLWithPath: path) }
            let address = PortAddress(nodeID: source.id, portID: edge.sourcePortID)
            let value = source.supportsTakes ? displayedValue(for: source) : runtimeValues[address] ?? latestValue(at: address, inProject: project.id)
            if case .image(let url) = value { return url }
            return nil
        }
        return anchor.imagePath.map { URL(fileURLWithPath: $0) }
    }
}
