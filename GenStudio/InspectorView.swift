import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorView: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        let bulkNodes = model.bulkImageGenerators(model.multiSelectedNodeIDs)
        Form {
            if !bulkNodes.isEmpty {
                BulkImageGeneratorInspector(model: model, nodes: bulkNodes)
            } else if let node = model.selectedNode {
                Section(node.kind.title) {
                    Text(node.kind.detail).font(.caption).foregroundStyle(.secondary)
                    TextField("Label", text: nodeBinding(node, \.label))
                    switch node.kind {
                    case .prompt:
                        ZStack(alignment: .bottomLeading) {
                            TextEditor(text: model.promptBinding(for: node))
                                .frame(minHeight: 240).font(.body)
                                .disabled(node.isLockedFinal)
                                .accessibilityLabel("Prompt text in inspector")
                                .accessibilityIdentifier("prompt-inspector-\(node.id)")
                            ReferenceMentionSuggestions(text: model.promptBinding(for: node), mentions: model.referenceMentions(forPromptNodeID: node.id))
                                .disabled(node.isLockedFinal)
                        }
                        HStack {
                            Button("Load from File…") { model.loadPrompt(node.id) }.disabled(node.isLockedFinal)
                            Button("Save As…") { model.savePromptAs(node.id) }.disabled(node.prompt.isEmpty)
                        }
                        Text(node.isLockedFinal ? "Locked as final. Unlock it to edit." : "Edit here or directly in the node. Load reads a .txt file into this prompt; Save As writes the prompt to a .txt file to reuse in another project.").font(.caption).foregroundStyle(.secondary)
                    case .imagePrompt:
                        ImagePromptInspector(settings: imagePromptSettingsBinding(node))
                    case .videoPrompt:
                        VideoPromptInspector(settings: videoPromptSettingsBinding(node))
                    case .promptTemplate:
                        TextEditor(text: nodeBinding(node, \.prompt)).frame(minHeight: 140).font(.body.monospaced())
                            .accessibilityLabel("Prompt template text")
                        if let issue = PromptTemplateSyntax.issue(for: node, connectedPorts: connectedInputPortIDs(node)) {
                            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        } else {
                            Label("Every placeholder has a connected input.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                        }
                        Text("Write {{name}} where connected text should go, for example \"A portrait of {{subject}}, {{style}}\". Names are matched exactly, ignoring spaces inside the braces.").font(.caption).foregroundStyle(.secondary)
                    case .stickyNote:
                        TextEditor(text: nodeBinding(node, \.prompt)).frame(minHeight: 140).font(.body.monospaced())
                    case .promptEnhancer:
                        promptEnhancerSection(node)
                    case .textModel:
                        Text("Local text · bundled llama.cpp").font(.caption).foregroundStyle(.secondary)
                        generationModelPicker(node, kind: .text)
                        FullWidthInspectorSlider(title: "Temperature", valueText: node.temperature.formatted(.number.precision(.fractionLength(1))), value: nodeBinding(node, \.temperature), range: 0...2)
                        Stepper("Maximum tokens: \(node.maxTokens)", value: nodeBinding(node, \.maxTokens), in: 1...512, step: 16)
                    case .imageDescriber:
                        generationModelPicker(node, kind: .vision)
                        Picker("Persona", selection: imageDescriberPersonaBinding(node)) {
                            Text("No persona — General").tag(PersonaExpert?.none)
                            Divider()
                            ForEach(PersonaExpert.allCases) { persona in
                                Text(persona.displayName).tag(Optional(persona))
                            }
                        }
                        Text("Image Instructions").font(.headline)
                        TextEditor(text: nodeBinding(node, \.prompt)).frame(minHeight: 240).font(.body)
                        Text("Choose a persona to replace these instructions with its specialist image-analysis lens, then edit them if needed.").font(.caption).foregroundStyle(.secondary)
                        let images = model.referenceImages(for: node)
                        if !images.isEmpty {
                            HStack { ForEach(Array(images.enumerated()), id: \.offset) { item in LocalImageThumbnail(url: item.element).frame(width: 62, height: 62) } }
                        }
                        FullWidthInspectorSlider(title: "Creativity", valueText: node.temperature.formatted(.number.precision(.fractionLength(1))), value: nodeBinding(node, \.temperature), range: 0...1)
                        Stepper("Maximum tokens: \(node.maxTokens)", value: nodeBinding(node, \.maxTokens), in: 128...4096, step: 128)
                        Text("Camera settings are estimates from the picture. Check the resulting description before using it to direct a shoot.").font(.caption).foregroundStyle(.secondary)
                    case .characterSheet:
                        Picker("Subject", selection: characterSheetSubjectBinding(node)) {
                            ForEach(CharacterSheetSubject.allCases) { subject in
                                Text(subject.title).tag(subject)
                            }
                        }
                        Text(node.characterSheetSubject.layoutSummary).font(.callout)
                        if node.characterSheetSubject == .person || node.characterSheetSubject == .animatedCharacter {
                            Picker("Body pose", selection: characterSheetPoseBinding(node)) {
                                ForEach(CharacterSheetPose.allCases) { pose in Text(pose.title).tag(pose) }
                            }
                            Text("Choose Seated for a seated baby, or Standing for a standing subject. Explicit poses are more reliable than asking the image model to infer one.").font(.caption).foregroundStyle(.secondary)
                        }
                        TextField(node.characterSheetSubject.heightLabel, value: characterSheetHeightBinding(node), format: .number)
                        Text(node.characterSheetSubject.heightHelp).font(.caption).foregroundStyle(.secondary)
                        Text("Body views share one scale. A supplied height adds a small size caption; the generated sheet is a visual reference, not a calibrated measuring tool.").font(.caption).foregroundStyle(.secondary)
                        Text("Sheet brief").font(.headline)
                        Text(node.characterSheetBrief).font(.body).textSelection(.enabled)
                        Text("Connect Text to Image Generator Prompt and the original pictures of one subject to its Reference inputs. Keep different people on separate sheets. Choose the suggested canvas size on Image Generator. This brief is used directly, without an LLM rewrite.").font(.caption).foregroundStyle(.secondary)
                    case .imageInput:
                        Button("Choose Image…") { chooseImage(node.id) }
                        if let path = node.imagePath {
                            LocalImageThumbnail(url: URL(fileURLWithPath: path)).frame(height: 170)
                            Text(path).font(.caption).textSelection(.enabled)
                        }
                        Text("To generate a new image, add an Image Generator node.").font(.caption).foregroundStyle(.secondary)
                    case .videoInput:
                        Button("Choose Video…") { chooseVideo(node.id) }
                        if let path = node.videoPath { Text(path).font(.caption).textSelection(.enabled) }
                    case .maskInput:
                        Button("Choose Mask…") { chooseMask(node.id) }
                        if let path = node.imagePath {
                            LocalImageThumbnail(url: URL(fileURLWithPath: path)).frame(height: 170)
                            Text(path).font(.caption).textSelection(.enabled)
                        }
                        Text("White marks the area to change; black is preserved. The mask must match the source image's exact pixel dimensions.").font(.caption).foregroundStyle(.secondary)
                    case .maskOperations:
                        Toggle("Invert", isOn: nodeBinding(node, \.maskInvert))
                        Stepper("Grow / shrink: \(node.maskGrowShrink) px", value: nodeBinding(node, \.maskGrowShrink), in: -256...256)
                        FullWidthInspectorSlider(title: "Feather", valueText: "\(node.maskFeather.formatted()) px", value: nodeBinding(node, \.maskFeather), range: 0...100)
                        Text("Grow/shrink and feather are Core Image morphology and Gaussian blur; no model is involved. Connect a Source Image to validate the mask matches its exact pixel dimensions before it is used.").font(.caption).foregroundStyle(.secondary)
                    case .textArray:
                        TextField("Delimiter (\\n = line break)", text: nodeBinding(node, \.arrayDelimiter))
                        Toggle("Trim whitespace", isOn: nodeBinding(node, \.arrayTrim))
                        Text("Order and empty items are preserved. Maximum 256 items; no batch generation.").font(.caption).foregroundStyle(.secondary)
                    case .listSelect:
                        Stepper("Item \(node.listIndex) (starts at 1)", value: nodeBinding(node, \.listIndex), in: 1...256)
                    case .imageRotateFlip:
                        Picker("Clockwise rotation", selection: nodeBinding(node, \.quarterTurns)) { ForEach(0..<4) { Text("\($0 * 90)°").tag($0) } }
                        Toggle("Flip horizontally", isOn: nodeBinding(node, \.flipHorizontal))
                        Toggle("Flip vertically", isOn: nodeBinding(node, \.flipVertical))
                    case .imageBlur:
                        FullWidthInspectorSlider(title: "Blur radius", valueText: "\(node.blurRadius.formatted()) px", value: nodeBinding(node, \.blurRadius), range: 0...100)
                    case .imageInvert:
                        Text("Inverts RGB colors. Alpha is preserved.").font(.caption)
                    case .colourCorrect:
                        Text("Connect the approved source image and the generated image. Running this node transfers the source's global colour and tonal balance to the generated image; geometry and detail are not regenerated.").font(.caption).foregroundStyle(.secondary)
                    case .number:
                        TextField("Value", value: nodeBinding(node, \.numberValue), format: .number)
                    case .combineText:
                        HStack {
                            TextField("Separator", text: Binding(get: { SeparatorField.display(nodeBinding(node, \.separator).wrappedValue) }, set: { nodeBinding(node, \.separator).wrappedValue = $0 }))
                            Menu("Presets") { ForEach(SeparatorField.presets, id: \.title) { preset in Button(preset.title) { nodeBinding(node, \.separator).wrappedValue = preset.value } } }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        Text("Placed between parts. \\n is a line break and \\t a tab. Empty parts are skipped.").font(.caption).foregroundStyle(.secondary)
                    case .imageResize:
                        ClampedIntField(title: "Width (px)", value: nodeBinding(node, \.width), range: 1...16_384)
                        ClampedIntField(title: "Height (px)", value: nodeBinding(node, \.height), range: 1...16_384)
                        Text("Stretches to exactly this size; it does not keep the aspect ratio. Total size is limited to 67 megapixels.").font(.caption).foregroundStyle(.secondary)
                    case .imageCrop:
                        TextField("X", value: nodeBinding(node, \.cropX), format: .number)
                        TextField("Y", value: nodeBinding(node, \.cropY), format: .number)
                        TextField("Width", value: nodeBinding(node, \.cropWidth), format: .number)
                        TextField("Height", value: nodeBinding(node, \.cropHeight), format: .number)
                        if let problem = CropBounds.issue(x: node.cropX, y: node.cropY, width: node.cropWidth, height: node.cropHeight) {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("Fractions of the image: 0 is the top-left edge and 1 the far edge.").font(.caption).foregroundStyle(.secondary)
                        }
                    case .imageBlend:
                        FullWidthInspectorSlider(title: "Opacity", valueText: node.opacity.formatted(.percent.precision(.fractionLength(0))), value: nodeBinding(node, \.opacity), range: 0...1)
                    case .imageCompare:
                        Picker("Selected output", selection: nodeBinding(node, \.comparisonSelection)) { Text("Image A").tag(0); Text("Image B").tag(1) }
                        ForEach(["a", "b", "selected"], id: \.self) { portID in
                            if let value = model.runtimeValues[.init(nodeID: node.id, portID: portID)] {
                                VStack(alignment: .leading) { Text(portID == "selected" ? "Selected" : "Image \(portID.uppercased())").font(.caption.bold()); RuntimeValueView(value: value, compact: true) }
                            }
                        }
                    case .extractFrame:
                        TextField("Time in seconds", value: nodeBinding(node, \.numberValue), format: .number)
                    case .imageGenerator:
                        ImageGeneratorInspector(model: model, node: node, binding: { nodeBinding(node, $0) }, intBinding: { nodeBinding(node, $0) },
                                                strengthBinding: Binding(get: { model.currentProject?.nodes.first { $0.id == node.id }?.imageStrength ?? ImageCapabilityRegistry.defaultStrength }, set: { value in model.mutateProjectFromBinding { project in if let index = project.nodes.firstIndex(where: { $0.id == node.id }) { project.nodes[index].imageStrength = value } } }))
                    case .imageUpscale:
                        ImageUpscaleInspector(model: model, node: node)
                    case .videoUpscale:
                        VideoUpscaleInspector(model: model, node: node)
                    case .frameInterpolate:
                        Stepper("Delivery frame rate: \(node.deliveryFPS) fps", value: nodeBinding(node, \.deliveryFPS), in: 12...60)
                        Text("Metal-accelerated RIFE creates genuine intermediate frames locally. For Instagram, leave this at 30 fps. This does not run diffusion again.").font(.caption).foregroundStyle(.secondary)
                    case .instagramExport:
                        Picker("Format", selection: Binding(get: { node.format }, set: { value in model.updateNodeFromBinding(node.id) { $0.format = value } })) {
                            ForEach(DeliveryFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        LabeledContent("Output", value: "\(node.format.width) × \(node.format.height) · 24, 25 or 30 fps")
                        Text("Aspect-fill preserves the frame without stretching and crops overflow at the sides. Sound is kept. A 24, 25 or 30 fps source keeps its rate; for slower drafts, connect a 30 fps Frame Interpolation result before export.").font(.caption).foregroundStyle(.secondary)
                    case .voiceover:
                        VoiceoverInspector(model: model, store: model.libraryStore, node: node, settings: Binding(get: { model.currentProject?.nodes.first(where: { $0.id == node.id })?.voiceoverSettings ?? .init() }, set: { value in
                            model.mutateProjectFromBinding { project in
                                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                                project.nodes[index].voiceoverSettings = value
                            }
                        }))
                    case .textOverlay:
                        TextOverlayInspector(model: model, settings: Binding(get: { model.currentProject?.nodes.first(where: { $0.id == node.id })?.textOverlaySettings ?? .init() }, set: { value in
                            model.mutateProjectFromBinding { project in
                                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                                project.nodes[index].textOverlaySettings = value
                            }
                        }))
                    case .endCard:
                        EndCardInspector(model: model, settings: endCardSettingsBinding(node))
                    case .textToVideo, .imageToVideo, .startEndVideo, .guidedShot, .videoToVideo, .shotSequence, .animatic, .assembleVideo:
                        VideoNodeInspector(model: model, node: node)
                    case .numberToText, .textRouter, .imageRouter, .videoRouter, .textPreview, .imagePreview, .videoPreview:
                        Text("This deterministic node uses its connected values.").foregroundStyle(.secondary)
                    }
                    if let reason = model.supersededAttempts[node.id] {
                        Label(reason, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
                        Text(node.supportsTakes ? "Your previous successful take is still selected. Generate again to retry." : "Earlier results remain in the gallery.").font(.caption).foregroundStyle(.secondary)
                    }
                    if node.kind.supportsDynamicTextInputs {
                        TextInputSlotList(model: model, node: node)
                    } else if node.kind.supportsDynamicImageInputs && node.kind != .imageGenerator {
                        ForEach(node.dynamicInputs) { port in HStack { Text(port.label); Spacer(); Button("Remove") { model.removeDynamicInput(nodeID: node.id, portID: port.id) }.disabled(node.dynamicInputs.count == 1) } }
                        Button("Add Image Input") { model.addDynamicInput(to: node.id) }
                    }
                }
                FinalInspectorSection(model: model, node: node)
                if let project = model.currentProject {
                    Section("Run Preview") {
                        Text(RunPlan.make(project: project, target: node.id).summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let value = model.displayedValue(for: node) {
                    Section(node.supportsTakes ? "Selected Take" : "Last Output") {
                        if node.supportsTakes { GenerationTakeControls(model: model, node: node) }
                        RuntimeValueView(value: value, compact: true, fullText: true)
                        if let take = model.selectedTake(for: node), let settings = take.graphSnapshot.nodes.first(where: { $0.id == node.id }) {
                            Text("\(take.createdAt.formatted()) · \(model.modelName(settings.model)) · seed \(settings.kind == .imageGenerator ? settings.imageSeed : settings.video.seed)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("The selected take is used by connected nodes.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Delete Node", role: .destructive) { model.deleteSelected() }
                }
            } else {
                if let project = model.currentProject {
                    WorkflowInspectorDetails(model: model, project: project).id(project.id)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func generationModelPicker(_ node: StudioNode, kind: GenerationModelKind) -> some View {
        let available = model.generationModels(kind)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Picker("Model", selection: nodeBinding(node, \.model)) {
                    Text("Choose an installed model").tag("")
                    if !node.model.isEmpty, !available.contains(where: { $0.id == node.model }) {
                        Text("\(model.modelName(node.model)) · unavailable saved selection").tag(node.model)
                    }
                    ForEach(available, id: \.id) { Text($0.name + ($0.inferenceVerified ? "" : " · untested") + ModelAdvisor.pickerNote($0.id)).tag($0.id) }
                }
                Button(model.isDefaultModel(node) ? "Default" : "Set as default") {
                    model.setDefaultModel(for: node)
                }
                .buttonStyle(.borderless)
                .disabled(node.model.isEmpty || !available.contains(where: { $0.id == node.model }))
            }
            .disabled(available.isEmpty)
            FinalQualityBadge(recipeID: node.model)
            if let issue = model.generationModelIssue(for: node) {
                Text(issue).font(.caption).foregroundStyle(.orange)
            }
            if let selected = available.first(where: { $0.id == node.model }) {
                Text(ModelRecipePresentation.installedPurpose(selected)).font(.caption).foregroundStyle(.secondary)
            }
            Text("Only installed \(NodeModelCompatibility.purpose(kind)) models supported by this node are listed.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Open Model Library") { model.sidebarSection = .models }
                Button("Refresh") { Task { await model.refreshModels() } }
            }
            Text(model.isRunning ? "Engine: \(model.nativeRuntimeState). Releases memory after this run." : "Unloaded. Loads for each run, then releases memory.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func promptEnhancerSection(_ node: StudioNode) -> some View {
        let project = model.currentProject ?? .init(name: "", nodes: [node], edges: [])
        let detected = PromptEnhancer.destinations(of: node.id, in: project).first
        Label(PromptEnhancer.summary(for: node, in: project, modelName: model.modelName), systemImage: "wand.and.sparkles")
            .font(.callout)
        Picker("Write for", selection: nodeBinding(node, \.promptEnhancerTarget)) {
            Text(detected.map { "Auto · \($0.target.title) (\($0.label))" } ?? "Auto · follow the connected node").tag(PromptEnhancerTarget?.none)
            Divider()
            ForEach(PromptEnhancerTarget.allCases) { target in Text(target.title).tag(Optional(target)) }
        }
        generationModelPicker(node, kind: .text)
        let pictures = connectedInputPortIDs(node).contains(PromptEnhancer.imagePortID) || !PromptEnhancer.contextSources(of: node.id, in: project).isEmpty
        if pictures, !node.model.isEmpty, !ExecutionQueue.canSeePictures(node.model, installedGenerationModels: model.libraryStore.installed) {
            Label("This model reads text only, so it will not look at the picture. Choose Qwen3.8 MLX to let it see the image.", systemImage: "eye.slash")
                .font(.caption).foregroundStyle(.orange)
        }
        FullWidthInspectorSlider(title: "Creativity", valueText: node.temperature.formatted(.number.precision(.fractionLength(1))), value: nodeBinding(node, \.temperature), range: 0...1)
        Text("Connect your Prompt to Rough Prompt and Enhanced to the image or video node. Run this node to write the prompt; it looks at the picture that node receives (or one you connect to Image). Image and video runs reuse it until the rough prompt, destination or model changes.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func connectedInputPortIDs(_ node: StudioNode) -> Set<String> {
        Set(model.currentProject?.edges.filter { $0.targetID == node.id }.map(\.targetPortID) ?? [])
    }

    private func nodeBinding<T>(_ node: StudioNode, _ keyPath: WritableKeyPath<StudioNode, T>) -> Binding<T> {
        Binding(get: { model.currentProject?.nodes.first(where: { $0.id == node.id })?[keyPath: keyPath] ?? node[keyPath: keyPath] }, set: { value in
            model.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                project.nodes[index][keyPath: keyPath] = value
            }
        })
    }

    private func imagePromptSettingsBinding(_ node: StudioNode) -> Binding<ImagePromptSettings> {
        Binding(get: { model.currentProject?.nodes.first(where: { $0.id == node.id })?.imagePromptSettings ?? .init() }, set: { value in
            model.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                project.nodes[index].imagePromptSettings = value
            }
        })
    }

    private func endCardSettingsBinding(_ node: StudioNode) -> Binding<EndCardSettings> {
        Binding(get: { model.currentProject?.nodes.first(where: { $0.id == node.id })?.endCardSettings ?? .init() }, set: { value in
            model.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                project.nodes[index].endCardSettings = value
            }
        })
    }

    private func videoPromptSettingsBinding(_ node: StudioNode) -> Binding<VideoPromptSettings> {
        Binding(get: { model.currentProject?.nodes.first(where: { $0.id == node.id })?.videoPromptSettings ?? .init() }, set: { value in
            model.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                project.nodes[index].videoPromptSettings = value
            }
        })
    }

    private func imageDescriberPersonaBinding(_ node: StudioNode) -> Binding<PersonaExpert?> {
        Binding(get: {
            model.currentProject?.nodes.first(where: { $0.id == node.id })?.imageDescriberPersona
        }, set: { persona in
            model.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                project.nodes[index].imageDescriberPersona = persona
                project.nodes[index].prompt = StudioNode.imageDescriberInstructions(for: persona)
            }
        })
    }

    private func characterSheetSubjectBinding(_ node: StudioNode) -> Binding<CharacterSheetSubject> {
        Binding(get: {
            model.currentProject?.nodes.first(where: { $0.id == node.id })?.characterSheetSubject ?? .person
        }, set: { subject in
            model.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                if project.nodes[index].characterSheetSubject != subject {
                    project.nodes[index].characterSheetHeightCM = nil
                }
                project.nodes[index].characterSheetSubject = subject
                project.nodes[index].prompt = project.nodes[index].characterSheetBrief
            }
        })
    }

    private func characterSheetHeightBinding(_ node: StudioNode) -> Binding<Double?> {
        Binding(get: {
            model.currentProject?.nodes.first(where: { $0.id == node.id })?.characterSheetHeightCM
        }, set: { value in
            model.updateNodeFromBinding(node.id) { current in
                current.characterSheetHeightCM = value.flatMap { $0.isFinite && $0 > 0 && $0 <= 100_000 ? $0 : nil }
                current.prompt = current.characterSheetBrief
            }
        })
    }

    private func characterSheetPoseBinding(_ node: StudioNode) -> Binding<CharacterSheetPose> {
        Binding(get: {
            model.currentProject?.nodes.first(where: { $0.id == node.id })?.characterSheetPose ?? .original
        }, set: { pose in
            model.updateNodeFromBinding(node.id) { current in
                current.characterSheetPose = pose
                current.prompt = current.characterSheetBrief
            }
        })
    }

    private func chooseImage(_ nodeID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.mutateProject { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            project.nodes[index].imagePath = url.path
            VideoDimensionSync.resyncTargets(of: nodeID, in: &project)
        }
    }

    private func chooseVideo(_ nodeID: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setInputVideo(url, for: nodeID)
    }

    private func chooseMask(_ nodeID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.mutateProject { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            project.nodes[index].imagePath = url.path
        }
    }
}
