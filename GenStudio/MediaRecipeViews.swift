import ImageIO
import SwiftUI

/// What the picker displays: a matched preset, or Custom when the canvas doesn't correspond to
/// any preset — most often because it was fitted to a connected source image's own ratio.
enum AspectRatioSelection: Hashable {
    case preset(AspectRatioPreset)
    case custom

    /// The preset within 3% of `width`/`height`'s ratio, or `.custom` when none matches close
    /// enough — most often because the canvas was fitted to a connected source image's own
    /// ratio rather than picked from this list. A free function so it is testable without
    /// instantiating the picker's SwiftUI view.
    static func matching(width: Int, height: Int) -> AspectRatioSelection {
        guard width > 0, height > 0 else { return .custom }
        let achieved = Double(width) / Double(height)
        guard let closest = AspectRatioPreset.allCases.min(by: { abs($0.ratio - achieved) < abs($1.ratio - achieved) }),
              abs(closest.ratio - achieved) / closest.ratio < 0.03 else { return .custom }
        return .preset(closest)
    }
}

struct AspectRatioPicker: View {
    /// The node's actual current canvas — the picker derives its displayed selection from this
    /// rather than tracking its own state, so it never goes stale relative to what the node
    /// really holds (a preset pick, a manual edit, or a size adopted from a connected image).
    let currentWidth: Int
    let currentHeight: Int
    let apply: (AspectRatioPreset) -> Void

    private var selection: AspectRatioSelection { .matching(width: currentWidth, height: currentHeight) }

    var body: some View {
        AspectRatioIconSelector(
            selection: selection,
            currentDimensions: "\(currentWidth) × \(currentHeight) px",
            guidance: selection == .custom
                ? "This canvas follows a custom or connected-source ratio. Choose an icon to replace it, or adjust the exact dimensions below."
                : "Choosing a ratio fits valid pixel dimensions for the selected model. Fine-tune the exact canvas below.",
            apply: apply
        )
    }
}

/// Per-task adapter and proof chips. A task that is not listed has no adapter for this recipe.
struct RecipeTaskChips: View {
    let tasks: [RecipeTaskStatus]
    var body: some View {
        if tasks.isEmpty {
            Label("No adapter for any task in this version", systemImage: "nosign").font(.caption).foregroundStyle(.orange)
        } else {
            ModelPurposeFlowLayout(spacing: 6) {
                ForEach(tasks) { task in
                    let (symbol, color, state) = Self.style(task.proof)
                    Label("\(task.title) · \(state)", systemImage: symbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(color.opacity(0.12), in: Capsule())
                        .help(task.note)
                        .accessibilityLabel("\(task.title): \(state)")
                }
            }
        }
    }
    static func style(_ proof: RecipeTaskStatus.Proof) -> (String, Color, String) {
        switch proof {
        case .verified: ("checkmark.seal.fill", .green, "verified locally")
        case .awaitingProof: ("hourglass", .orange, "adapter ready, not verified")
        case .unavailable: ("nosign", .secondary, "unavailable")
        }
    }
}

/// Exact storage, memory and proof details for one image/video recipe.
struct MediaRecipeFitDetails: View {
    let fit: RecipeFit
    let recipe: ModelRecipe
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(fit.label, systemImage: Self.symbol(fit.state)).font(.callout.weight(.semibold)).foregroundStyle(Self.color(fit.state))
            Text(fit.detail).font(.callout).foregroundStyle(.secondary)
            RecipeTaskChips(tasks: fit.tasks)
            if let storage = fit.storage, !fit.installed {
                Text(storageSummary(storage)).font(.caption)
                ForEach(storage.reused, id: \.componentID) { reuse in
                    Text("Reuses \(reuse.componentID) (\(ModelLibraryViewModel.bytes(reuse.bytes))) from installed \(reuse.installedModelName); checksum is verified again.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Memory: weights alone need at least \(ModelLibraryViewModel.bytes(Int64(clamping: fit.memoryFloorBytes))) (includes 2 GB runtime overhead). Activations and decoding add an unmeasured amount.").font(.callout).foregroundStyle(.secondary)
            ForEach(fit.tasks.compactMap(\.measured), id: \.self) { Text("Measured: \($0)").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func storageSummary(_ storage: StoragePlan) -> String {
        let reuse = storage.reusedBytes > 0 ? " · \(ModelLibraryViewModel.bytes(storage.reusedBytes)) reused\(storage.clonesShareStorage ? " as space-sharing clones" : " as copies")" : ""
        return "Download \(ModelLibraryViewModel.bytes(storage.downloadBytes))\(reuse) · needs \(ModelLibraryViewModel.bytes(storage.requiredFreeBytes)) free including staging and reserve"
    }
    static func symbol(_ state: RecipeFit.State) -> String {
        switch state {
        case .locallyVerified: "checkmark.seal.fill"
        case .adapterUnverified: "hourglass"
        case .possibleDemanding: "gauge.with.dots.needle.67percent"
        case .insufficientResources: "exclamationmark.triangle"
        case .adapterNeeded: "puzzlepiece.extension"
        case .incompatible: "xmark.octagon"
        }
    }
    static func color(_ state: RecipeFit.State) -> Color {
        switch state {
        case .locallyVerified: .green
        case .adapterUnverified, .possibleDemanding: .orange
        case .insufficientResources, .incompatible: .red
        case .adapterNeeded: .secondary
        }
    }
}

/// Model Library section for curated image/video recipes and information-only candidates.
struct MediaRecipeCatalogSection: View {
    @ObservedObject var store: ModelLibraryViewModel
    let select: (ModelRecipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image & video recipes").font(.title2.bold())
            Text("Exact pinned files for the bundled stable-diffusion.cpp build. Each task shows whether GenStudio has an adapter and whether a real render on this Mac has verified it. Downloads never start until you choose one.").font(.callout).foregroundStyle(.secondary)
            ForEach(store.mediaRecipes, id: \.id) { recipe in
                let fit = store.mediaFit(recipe)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ModelRecipePresentation.title(recipe)).font(.headline)
                        if let profile = MediaModelCatalog.profile(recipe.id) { Text("\(profile.family) · \(profile.summary)").font(.callout) }
                        ModelPurposeTags(purposes: ModelRecipePresentation.purposeTags(recipe))
                        MediaRecipeFitDetails(fit: fit, recipe: recipe)
                    }
                    Spacer()
                    if fit.installed {
                        VStack(alignment: .trailing, spacing: 6) {
                            Label("Installed", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                            if let update = store.updates[recipe.id], let candidate = update.candidate {
                                Button("Update available") { select(candidate) }
                            }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Button("Review") { select(recipe) }
                                .buttonStyle(.plain)
                            if fit.canInstall {
                                Button("Install") { store.install(recipe) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(store.busy)
                            }
                        }
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
            }
            DisclosureGroup("Assessed, not installable (\(ModelCandidateCatalog.candidates.count))") {
                Text("These families are real, but GenStudio cannot describe a complete, pinned, downloadable recipe for them in this version. They cannot be installed.").font(.callout).foregroundStyle(.secondary)
                ForEach(ModelCandidateCatalog.candidates) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.family).font(.headline)
                        Text("\(candidate.tasks.joined(separator: " · ")) — \(candidate.runtime)").font(.callout)
                        ForEach(candidate.blockers, id: \.self) { Label($0, systemImage: "lock").font(.callout).foregroundStyle(.secondary) }
                    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Image Generator recipe selection filtered by the task implied by its wiring.
struct ImageGeneratorInspector: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode
    let binding: (WritableKeyPath<StudioNode, String>) -> Binding<String>
    let intBinding: (WritableKeyPath<StudioNode, Int>) -> Binding<Int>
    let strengthBinding: Binding<Double>

    private var referenceCount: Int {
        model.currentProject?.edges.filter { $0.targetID == node.id && node.imageGeneratorReferencePortIDs.contains($0.targetPortID) }.count ?? 0
    }
    private var referenceConnected: Bool { referenceCount > 0 }
    private var characterSheetSubject: CharacterSheetSubject? {
        model.currentProject?.characterSheetSource(feeding: node.id)?.characterSheetSubject
    }
    private var usesCharacterSheetCanvas: Bool {
        guard let subject = characterSheetSubject else { return false }
        let canvas = subject.recommendedCanvas
        let ratio = Double(node.width) / Double(node.height)
        return abs(ratio - Double(canvas.width) / Double(canvas.height)) < 0.025
    }

    var body: some View {
        let task = ImageCapabilityRegistry.task(referenceCount: referenceCount)
        let choices = ImageCapabilityRegistry.selectableCapabilities(
            task: task, referenceCount: referenceCount, installed: model.libraryStore.installed,
            cloudSignedIn: model.chatGPTSubscription.isSignedIn
        )
        VStack(alignment: .leading, spacing: 8) {
            Text("Task: \(task.title)\(referenceConnected ? " (\(referenceCount) Reference\(referenceCount == 1 ? "" : "s") connected)" : "")").font(.callout.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Picker("Model", selection: Binding(
                    get: { (model.currentProject?.nodes.first { $0.id == node.id } ?? node).model },
                    set: { id in
                        model.updateNodeFromBinding(node.id) { current in
                            current.model = id
                            // Keep the first local attempt available without making the
                            // user discover a separate safety switch in the inspector.
                            // The engine still requires the exact installed recipe.
                            current.experimentalImageRecipeID = id.isEmpty ? nil : id
                        }
                    }
                )) {
                    Text("Choose an installed model").tag("")
                    if !node.model.isEmpty, !choices.contains(where: { $0.recipeID == node.model }) {
                        Text("\(ModelCatalog.recipes.first { $0.id == node.model }.map(ModelRecipePresentation.title) ?? node.model) · unavailable saved selection").tag(node.model)
                    }
                    ForEach(choices) { capability in
                        Text(recipeName(capability.recipeID) + ModelAdvisor.pickerNote(capability.recipeID)).tag(capability.recipeID)
                    }
                }
                Button(model.isDefaultModel(node) ? "Default" : "Set as default") { model.setDefaultModel(for: node) }
                    .buttonStyle(.borderless)
                    .disabled(node.model.isEmpty || !choices.contains(where: { $0.recipeID == node.model }))
            }
            .disabled(choices.isEmpty)
            FinalQualityBadge(recipeID: node.model)
            if choices.isEmpty {
                Text("No installed model supports this image-generation task. Install a compatible model in Model Library.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let issue = model.imageGeneratorIssue(for: node) {
                Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else {
                Label("Ready to run with the connected inputs.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            }
            if let capability = ImageCapabilityRegistry.capability(recipeID: node.model, task: task) ?? model.libraryStore.installed.first(where: { $0.id == node.model })?.recipeSnapshot.flatMap({ ImageCapabilityRegistry.userCapability(recipe: $0, task: task) }) {
                if let subject = characterSheetSubject {
                    let canvas = subject.recommendedCanvas
                    GroupBox("Character Sheet canvas") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(subject.layoutSummary)
                            if usesCharacterSheetCanvas {
                                Label("The canvas shape matches this sheet layout.", systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            } else {
                                Label("Use the suggested \(canvas.width) × \(canvas.height) canvas to give these views room.", systemImage: "rectangle.resize")
                                    .foregroundStyle(.orange)
                            }
                            if (node.width != canvas.width || node.height != canvas.height),
                               capability.width.contains(canvas.width), capability.height.contains(canvas.height) {
                                Button("Use Sheet Canvas \(canvas.width) × \(canvas.height)") {
                                    model.updateNodeFromBinding(node.id) { current in
                                        current.width = canvas.width
                                        current.height = canvas.height
                                    }
                                }
                            }
                            if !capability.width.contains(canvas.width) || !capability.height.contains(canvas.height) {
                                Text("This recipe does not support that exact size. Choose its nearest supported \(canvas.height > canvas.width ? "portrait" : "landscape") canvas.")
                                    .foregroundStyle(.secondary)
                            }
                            Text(referenceConnected
                                 ? "Use pictures of the same subject. Check identity, view angles and detail continuity in the result."
                                 : "Connect the original subject pictures to Reference inputs to preserve a specific identity.")
                                .foregroundStyle(.secondary)
                            if referenceConnected, capability.conditioning == .startImageStrength {
                                Text("This model edits the whole starting composition. Choose a reference-editing model such as FLUX.2 Klein to arrange the subject into a new sheet.")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if capability.conditioning == .referenceImage, referenceConnected {
                    ReferenceRoleEditor(model: model, node: node)
                }
                if referenceConnected && capability.conditioning == .startImageStrength {
                    GroupBox("Recommended for reference edits") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Stable Diffusion 1.5 is a whole-image img2img adapter. FLUX.2 Klein has GenStudio's reference-edit command and is the better choice when you want to preserve the source composition while changing a named object.")
                            Button("Use FLUX.2 Klein reference edit") {
                                model.updateNodeFromBinding(node.id) { current in
                                    current.model = MediaModelCatalog.kleinRecipeID
                                    current.experimentalImageRecipeID = MediaModelCatalog.kleinRecipeID
                                }
                            }
                            Text("Install FLUX.2 Klein first, then enable its exact first experimental run if it has not been locally verified yet.")
                                .foregroundStyle(.secondary)
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if capability.conditioning == .startImageStrength {
                    Label("Whole-image edit: this adapter has no mask/inpainting input. It may change details outside the requested area. Use a low strength for preservation, or a mask-capable workflow when localized replacement is required.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                AspectRatioPicker(currentWidth: node.width, currentHeight: node.height) { preset in
                    guard let size = preset.dimensions(width: capability.width, height: capability.height, targetPixels: capability.optimalPixels) else { return }
                    model.editGraph { project in
                        guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                        project.nodes[index].width = size.0
                        project.nodes[index].height = size.1
                        VideoDimensionSync.resyncTargets(of: node.id, in: &project)
                    }
                }
                RatioLockToggle(locked: node.ratioLocked) { on in model.updateNodeFromBinding(node.id) { $0.ratioLocked = on } }
                dimensionControl("Width", keyPath: \.width, value: node.width, bounds: capability.width, changedWidth: true, capability: capability)
                dimensionControl("Height", keyPath: \.height, value: node.height, bounds: capability.height, changedWidth: false, capability: capability)
                GenerationSeedControls(model: model, node: node)
                if node.seedLocked { TextField("Seed", value: intBinding(\.imageSeed), format: .number.grouping(.never)) }
                if let bounds = capability.strength {
                    FullWidthInspectorSlider(
                        title: "Strength",
                        valueText: strengthBinding.wrappedValue.formatted(.number.precision(.fractionLength(2))),
                        value: strengthBinding,
                        range: bounds.minimum...bounds.maximum
                    )
                }
            } else if !referenceConnected {
                Text("Connect a Reference image only when the chosen model supports image to image. A connected image is never ignored.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Model Library") { model.sidebarSection = .models }
                Button("Refresh") { Task { await model.refreshModels() } }
            }
        }
        .onAppear { authorizeFirstRunIfNeeded(task: task) }
        .onChange(of: node.model) { _, _ in authorizeFirstRunIfNeeded(task: task) }
    }

    private func recipeName(_ id: String) -> String {
        if id == ChatGPTSubscriptionImageEngine.recipeID { return "ChatGPT Images (My Subscription) · Experimental" }
        return ModelCatalog.recipes.first { $0.id == id }.map(ModelRecipePresentation.title) ?? model.modelName(id)
    }

    private func authorizeFirstRunIfNeeded(task: ImageTask) {
        guard let capability = ImageCapabilityRegistry.capability(recipeID: node.model, task: task),
              !capability.readiness.proven,
              let installed = model.libraryStore.installed.first(where: { $0.id == capability.recipeID }),
              installed.available,
              installed.hasVerifiedImageTask(task) == false else { return }
        model.updateNodeFromBinding(node.id) { current in
            current.experimentalImageRecipeID = capability.recipeID
        }
    }

    private func setDimension(_ raw: Int, changedWidth: Bool, keyPath: WritableKeyPath<StudioNode, Int>, capability: ImageCapability) {
        model.editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
            if project.nodes[index].ratioLocked {
                let n = project.nodes[index]
                let size = RatioLock.resolve(changedWidth: changedWidth, raw: raw, currentWidth: n.width, currentHeight: n.height, widthBounds: capability.width, heightBounds: capability.height)
                project.nodes[index].width = size.width; project.nodes[index].height = size.height
            } else {
                project.nodes[index][keyPath: keyPath] = raw
            }
            VideoDimensionSync.resyncTargets(of: node.id, in: &project)
        }
    }

    @ViewBuilder private func dimensionControl(_ title: String, keyPath: WritableKeyPath<StudioNode, Int>, value: Int, bounds: IntegerBounds, changedWidth: Bool, capability: ImageCapability) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                Text("px").foregroundStyle(.secondary)
            }
            TextField("Enter \(title.lowercased())", value: Binding(get: { node[keyPath: keyPath] }, set: { setDimension($0, changedWidth: changedWidth, keyPath: keyPath, capability: capability) }), format: .number.grouping(.never))
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
}

/// Header-only pixel-dimension read (no full decode) for the target-size preview.
enum ImageDimensionProbe {
    static func dimensions(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

/// Image Upscale recipe selection, scale/tile controls and honest limitations.
struct ImageUpscaleInspector: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode

    private var sourceURL: URL? { model.referenceImages(for: node).first }
    private var sourceDimensions: (width: Int, height: Int)? { sourceURL.flatMap(ImageDimensionProbe.dimensions) }

    var body: some View {
        let choices = UpscaleCapabilityRegistry.shipped.filter { capability in
            model.libraryStore.installed.contains { installed in
                installed.id == capability.recipeID && installed.available
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
            Picker("Model", selection: Binding(
                get: { (model.currentProject?.nodes.first { $0.id == node.id } ?? node).model },
                set: { id in
                    model.updateNodeFromBinding(node.id) { current in
                        current.model = id
                        if current.experimentalUpscaleRecipeID != id { current.experimentalUpscaleRecipeID = nil }
                    }
                }
            )) {
                Text("Choose an installed model").tag("")
                if !node.model.isEmpty, !choices.contains(where: { $0.recipeID == node.model }) {
                    Text("\(recipeName(node.model)) · unavailable saved selection").tag(node.model)
                }
                ForEach(choices) { capability in
                    Text("\(recipeName(capability.recipeID)) · \(status(capability))\(ModelAdvisor.pickerNote(capability.recipeID))").tag(capability.recipeID)
                }
            }
            .disabled(choices.isEmpty)
            Button(model.isDefaultModel(node) ? "Default" : "Set as default") { model.setDefaultModel(for: node) }
                .buttonStyle(.borderless)
                .disabled(node.model.isEmpty || !choices.contains(where: { $0.recipeID == node.model }))
            }
            Text("General model: photography and mixed artwork. Illustration model: flat art, animation and line work.").font(.callout).foregroundStyle(.secondary)
            if choices.isEmpty {
                Text("No installed upscaler supports this node. Install a compatible model in Model Library.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Picker("Scale", selection: Binding(get: { node.upscaleScale }, set: { value in model.updateNodeFromBinding(node.id) { $0.upscaleScale = value } })) {
                Text("2×").tag(2)
                Text("4×").tag(4)
            }.pickerStyle(.segmented)

            if let source = sourceDimensions {
                let target = node.upscaleScale == 4 ? (source.width * 4, source.height * 4) : (source.width * 2, source.height * 2)
                Text("Source \(source.width) × \(source.height) px → \(target.0) × \(target.1) px").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Connect an image to preview the target size.").font(.callout).foregroundStyle(.secondary)
            }
            if node.upscaleScale == 2 {
                Label("2× still renders the full proven 4× model output first, then downsamples it with GenStudio's deterministic high-quality resize. A temporary 4× image is created and discarded.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced") {
                Picker("Tile size", selection: Binding(get: { node.upscaleTileSize }, set: { value in model.updateNodeFromBinding(node.id) { $0.upscaleTileSize = value } })) {
                    Text("Auto").tag(0)
                    Text("64").tag(64)
                    Text("128").tag(128)
                    Text("256").tag(256)
                }
                Text("Tiling processes the image in smaller pieces to bound memory use. Smaller tiles use less memory but can show seams; 128 is the default until benchmarks justify Auto.").font(.callout).foregroundStyle(.secondary)
            }

            Label("Learned detail may modify faces, text, logos and fine patterns. Compare with the source at 100%; use Image Resize instead where exact pixels matter.", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)

            if let issue = model.imageUpscaleIssue(for: node) {
                Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else {
                Label("Ready to run with the connected input.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            }

            if let capability = UpscaleCapabilityRegistry.capability(recipeID: node.model) {
                Text(capability.qualityNote).font(.callout).foregroundStyle(.secondary)
                if !capability.readiness.proven {
                    let installed = model.libraryStore.installed.first { $0.id == capability.recipeID }
                    GroupBox("First-run safety") {
                        VStack(alignment: .leading, spacing: 6) {
                            if installed?.hasVerifiedUpscale == true {
                                Label("This recipe has completed a decoded local render. Future runs are verified.", systemImage: "checkmark.seal.fill")
                                    .foregroundStyle(.green)
                            } else if let installed, installed.available {
                                Toggle("Allow first experimental run on this Mac", isOn: Binding(
                                    get: { (model.currentProject?.nodes.first { $0.id == node.id } ?? node).experimentalUpscaleRecipeID == capability.recipeID },
                                    set: { enabled in model.updateNodeFromBinding(node.id) { $0.experimentalUpscaleRecipeID = enabled ? capability.recipeID : nil } }
                                ))
                                Text("This lets GenStudio try the exact installed recipe once before it has local proof. A successful decoded, dimension-verified image records verification; a failed run stays unverified.")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else if installed != nil {
                                Label("The recipe is installed but files are unavailable. Repair it in the Model Library before testing.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            } else {
                                Label("Install this exact recipe in the Model Library before enabling an experimental first run.", systemImage: "arrow.down.circle")
                                    .foregroundStyle(.orange)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let baseline = capability.measuredBaseline { Text(baseline).font(.callout).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Open Model Library") { model.sidebarSection = .models }
                Button("Refresh") { Task { await model.refreshModels() } }
            }
        }
    }

    private func recipeName(_ id: String) -> String { ModelCatalog.recipes.first { $0.id == id }.map(ModelRecipePresentation.title) ?? id }
    private func status(_ capability: UpscaleCapability) -> String {
        let installed = model.libraryStore.installed.first { $0.id == capability.recipeID }
        if !capability.readiness.proven { return installed?.hasVerifiedUpscale == true ? "ready" : "adapter ready, not verified" }
        guard let installed else { return "not installed" }
        return installed.available ? "ready" : "files missing"
    }
}

/// Video Upscale: same recipe/scale/tile controls as Image Upscale, but no per-frame dimension preview
/// (dimensions aren't known until each extracted frame decodes) and an explicit frame-based-restoration
/// limitation plus the first-release frame-count bound.
struct VideoUpscaleInspector: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode

    var body: some View {
        let choices = UpscaleCapabilityRegistry.shipped.filter { capability in
            model.libraryStore.installed.contains { installed in
                installed.id == capability.recipeID && installed.available
            }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
            Picker("Model", selection: Binding(
                get: { (model.currentProject?.nodes.first { $0.id == node.id } ?? node).model },
                set: { id in model.updateNodeFromBinding(node.id) { current in
                    current.model = id
                    if current.experimentalUpscaleRecipeID != id { current.experimentalUpscaleRecipeID = nil }
                } }
            )) {
                Text("Choose an installed model").tag("")
                if !node.model.isEmpty, !choices.contains(where: { $0.recipeID == node.model }) {
                    Text("\(ModelCatalog.recipes.first { $0.id == node.model }.map(ModelRecipePresentation.title) ?? node.model) · unavailable saved selection").tag(node.model)
                }
                ForEach(choices) { capability in Text(ModelCatalog.recipes.first { $0.id == capability.recipeID }.map(ModelRecipePresentation.title) ?? capability.recipeID).tag(capability.recipeID) }
            }
            .disabled(choices.isEmpty)
            Button(model.isDefaultModel(node) ? "Default" : "Set as default") { model.setDefaultModel(for: node) }
                .buttonStyle(.borderless)
                .disabled(node.model.isEmpty || !choices.contains(where: { $0.recipeID == node.model }))
            }
            if choices.isEmpty {
                Text("No installed upscaler supports this node. Install a compatible model in Model Library.")
                    .font(.callout).foregroundStyle(.secondary)
            }
                Picker("Scale", selection: Binding(get: { node.upscaleScale }, set: { value in model.updateNodeFromBinding(node.id) { $0.upscaleScale = value } })) {
                Text("2×").tag(2); Text("4×").tag(4)
            }.pickerStyle(.segmented)
            DisclosureGroup("Advanced") {
                Picker("Tile size", selection: Binding(get: { node.upscaleTileSize }, set: { value in model.updateNodeFromBinding(node.id) { $0.upscaleTileSize = value } })) {
                    Text("Auto").tag(0); Text("64").tag(64); Text("128").tag(128); Text("256").tag(256)
                }
            }
            Label("Frame-based restoration only: each frame is upscaled independently with no adjacent-frame conditioning, so fine detail can shimmer between frames. Not a Topaz-level temporal model.", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
            Text("Bounded to \(VideoUpscaleBounds.maximumFrames) frames in this release — each frame reloads the model, so longer clips are rejected before extraction with a clear remedy. Original timing, orientation and audio are preserved exactly.")
                .font(.callout).foregroundStyle(.secondary)
            if let issue = model.imageUpscaleIssue(for: node) {
                Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            } else {
                Label("Ready to run with the connected input.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            }
            if let capability = UpscaleCapabilityRegistry.capability(recipeID: node.model) {
                Text(capability.qualityNote).font(.callout).foregroundStyle(.secondary)
                if !capability.readiness.proven {
                    let installed = model.libraryStore.installed.first { $0.id == capability.recipeID }
                    if installed?.hasVerifiedUpscale != true, let installed, installed.available {
                        Toggle("Allow first experimental run on this Mac", isOn: Binding(
                            get: { (model.currentProject?.nodes.first { $0.id == node.id } ?? node).experimentalUpscaleRecipeID == capability.recipeID },
                            set: { enabled in model.updateNodeFromBinding(node.id) { $0.experimentalUpscaleRecipeID = enabled ? capability.recipeID : nil } }
                        ))
                    }
                }
            }
            HStack {
                Button("Open Model Library") { model.sidebarSection = .models }
                Button("Refresh") { Task { await model.refreshModels() } }
            }
        }
    }
}

extension StudioModel {
    func imageUpscaleIssue(for node: StudioNode) -> String? {
        if let issue = NodeModelCompatibility.issue(for: node, installed: libraryStore.installed, externalTextModels: Set(models.map(\.name))) { return issue }
        do { _ = try UpscaleRequestPlanner.validateSettings(recipeID: node.model, scale: node.upscaleScale, tileSize: node.upscaleTileSize, registry: UpscaleCapabilityRegistry.shipped) }
        catch { return error.localizedDescription }
        return nil
    }
}

extension StudioModel {
    func imageGeneratorIssue(for node: StudioNode) -> String? {
        let referenceCount = currentProject?.edges.filter { $0.targetID == node.id && node.imageGeneratorReferencePortIDs.contains($0.targetPortID) }.count ?? 0
        let task = ImageCapabilityRegistry.task(referenceCount: referenceCount)
        let allowUnverified = node.experimentalImageRecipeID == node.model
        if let issue = NodeModelCompatibility.issue(for: node, installed: libraryStore.installed, externalTextModels: Set(models.map(\.name)), allowUnverifiedImage: allowUnverified, cloudSignedIn: chatGPTSubscription.isSignedIn) { return issue }
        let dynamic = libraryStore.installed.compactMap { $0.recipeSnapshot }.flatMap { recipe in ImageTask.allCases.compactMap { ImageCapabilityRegistry.userCapability(recipe: recipe, task: $0) } }
        do { _ = try ImageRequestPlanner.validate(recipeID: node.model, task: task, width: node.width, height: node.height, seed: node.imageSeed, strength: node.imageStrength, registry: ImageCapabilityRegistry.shipped + dynamic, referenceCount: referenceCount) }
        catch { return error.localizedDescription }
        return nil
    }
}

/// Says what each connected Reference supplies, and shows the exact sentences that
/// will be sent. The preview matters more than the fields: it is where the user
/// sees that GenStudio numbers references by the order they reach the model, not by
/// the socket they were plugged into.
struct ReferenceRoleEditor: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode

    var body: some View {
        GroupBox("Reference roles") { ReferenceRoleEditorContent(model: model, node: node) }
    }
}

/// The editor's contents, separated from its `GroupBox` chrome so it can be
/// rendered and checked on its own.
struct ReferenceRoleEditorContent: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode

    private var liveNode: StudioNode { model.currentProject?.nodes.first { $0.id == node.id } ?? node }
    private var connectedPortIDs: [String] {
        ReferenceRoleComposer.connectedReferencePortIDs(node: liveNode, edges: model.currentProject?.edges ?? [])
    }
    private var preamble: String {
        ReferenceRoleComposer.preamble(roles: liveNode.referenceRoles, connectedPortIDs: connectedPortIDs, conditioning: .referenceImage)
    }
    private func socketLabel(_ portID: String) -> String {
        liveNode.inputPorts.first { $0.id == portID }?.label ?? portID
    }
    private func roleBinding(_ portID: String) -> Binding<String> {
        Binding(get: { liveNode.referenceRoles?[portID] ?? "" },
                set: { model.setReferenceRole(nodeID: node.id, portID: portID, to: $0) })
    }

    var body: some View {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Reference order is significant: references reach FLUX.2 Klein in socket order, each with its own position. Naming what a reference supplies gives the model something to bind that position to. Leave a role blank to say nothing about it.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(connectedPortIDs.enumerated()), id: \.element) { position, portID in
                    HStack(spacing: Space.sm) {
                        Text(ReferenceRoleComposer.socketCaption(
                            label: socketLabel(portID),
                            socketIndex: liveNode.imageGeneratorReferencePortIDs.firstIndex(of: portID) ?? position,
                            runPosition: position + 1))
                            .font(.callout.weight(.medium))
                            .frame(width: 148, alignment: .leading)
                        TextField("Description", text: roleBinding(portID))
                            .textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(ReferenceRolePreset.all) { preset in
                                Button(preset.title) { model.setReferenceRole(nodeID: node.id, portID: portID, to: preset.phrase) }
                            }
                            Divider()
                            Button("Clear") { model.setReferenceRole(nodeID: node.id, portID: portID, to: "") }
                        } label: {
                            Image(systemName: "text.badge.plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                if preamble.isEmpty {
                    Text("No roles set. The prompt is sent exactly as written.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Sent before your prompt").font(.caption).foregroundStyle(.secondary)
                        Text(preamble)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.sm)
                            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(.quaternary.opacity(0.4)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
