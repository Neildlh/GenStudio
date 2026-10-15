import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ModelLibraryView: View {
    @ObservedObject var store: ModelLibraryViewModel
    var generationRunning: Bool
    @State private var lane = 0
    @State private var query = ""
    @State private var selectedRecipe: ModelRecipe?
    @State private var confirmDiscardPartials = false
    @State private var showingManifestImporter = false
    @State private var preparingMultitaskCore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Model Library").font(.largeTitle.bold())
                        Text("Install the local runtime once, then download models once and generate locally.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.checkingUpdates ? "Checking…" : "Check for Updates") {
                        Task { await store.checkUpdates() }
                    }
                    .disabled(store.checkingUpdates || store.installed.isEmpty)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                }
                if let device = store.hardware {
                    Text("\(device.chip) · \((device.memoryBytes == 0 ? "Unknown" : "\(device.memoryBytes / (1024 * 1024 * 1024)) GB unified")) memory · macOS \(device.osVersion) · \((device.freeDiskBytes == 0 ? "Unknown" : ModelLibraryViewModel.bytes(device.freeDiskBytes))) free")
                        .font(.caption).padding(Space.md).background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.sm))
                    if device.totalDiskBytes > 0 {
                        Text("Library drive capacity: \(ModelLibraryViewModel.bytes(device.totalDiskBytes)). Installation checks the free space on this drive, including temporary download space.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Model storage: \(ModelLibraryViewModel.bytes(store.installedStorageBytes)) installed (deduplicated) · \(ModelLibraryViewModel.bytes(store.starterDownloadBytes)) still needed for the starter set")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("MLX VLM runtime", systemImage: "cpu")
                            .font(.headline)
                        Spacer()
                        Button("Check") { store.refreshMLXRuntime() }
                            .disabled(store.mlxRuntimeStatus.contains("Checking"))
                        if store.canInstallLocalRuntime {
                            Button(store.installingLocalRuntime ? "Installing…" : "Install Local Runtime") {
                                store.installLocalRuntime()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.installingLocalRuntime)
                        }
                    }
                    Text(store.mlxRuntimeStatus).font(.caption).foregroundStyle(store.mlxRuntimeStatus.hasPrefix("Ready") ? .green : .secondary).textSelection(.enabled)
                    Text("The pinned app-owned runtime serves llama.cpp, stable-diffusion.cpp, Qwen text/vision, FastMetal and LTX. Development builds keep it in Application Support so clean builds stay small and fast. Model weights remain separate; GenStudio never uses Homebrew, system Python or user packages.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
                if let failure = store.failure {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                        if let recipe = store.lastRecipe, !store.busy {
                            Button("Review and Retry…") { selectedRecipe = recipe }
                        }
                    }.font(.caption)
                }
                if let updateStatus = store.updateStatus {
                    Label(updateStatus, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let id = store.activeRecipeID {
                    VStack(alignment: .leading) {
                        Text("Installing \(store.lastRecipe?.name ?? id)").fontWeight(.semibold)
                        StudioLinearProgress(value: store.progress)
                        HStack { Text(store.progressText).font(.caption); Spacer(); Button("Cancel") { store.cancel() } }
                        if !store.queuedRecipes.isEmpty {
                            Label("Then: \(store.queuedRecipes.map { ModelRecipePresentation.title($0).components(separatedBy: " · ").first ?? $0.name }.joined(separator: ", "))", systemImage: "clock")
                                .font(.caption).foregroundStyle(.blue)
                        }
                        Text("This download continues in the background. You can build workflows, search models, and run an already-installed model while it finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                coreModelChecklist
                Picker("Browse", selection: $lane) {
                    Text("Recommended for This Mac").tag(0)
                    Text("Advanced Search / Import").tag(1)
                }.pickerStyle(.segmented)
                if lane == 0 {
                    Text("Right for this Mac").font(.title2.bold())
                    Text("Only models that fit this Mac and meet its speed-and-quality bar. The Models sidebar judges what you already have installed; everything else is under Advanced Search.").font(.caption).foregroundStyle(.secondary)
                    if store.hardware != nil && store.recommendedForThisMac.isEmpty {
                        Text("No model packages currently meet this Mac’s memory, storage, speed and quality checks.").foregroundStyle(.secondary)
                    }
                    ForEach(store.recommendedForThisMac, id: \.id) { recipe in recipeRow(recipe) }
                } else {
                    ModelDiscoveryView(store: store)
                    if !store.controlledEvaluationRecipes.isEmpty {
                        DisclosureGroup("Controlled evaluation — not yet recommended") {
                            Text("These exact packages have a complete app-owned backend and automatic auxiliary downloads, but no accepted decoded benchmark on this M1 Max yet. They remain outside Search and Start Here. Install only when you intend to run and judge the documented evaluation profile.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(store.controlledEvaluationRecipes, id: \.id) { recipe in recipeRow(recipe) }
                        }
                    }
                    if !store.onlyCompatibleModels {
                        DisclosureGroup("Import an existing model set") {
                            Text("Choose a recipe, then select each required file. Imports are copied into GenStudio and checked against the recipe's sizes and hashes. Your original files remain yours.").font(.caption).foregroundStyle(.secondary)
                            ForEach(ModelCatalog.recipes, id: \.id) { recipe in recipeRow(recipe) }
                        }
                    }
                }
                ModelRadarSection(store: store) { selectedRecipe = $0 }
                modelScoutSection
                intelligenceGuide
                Divider()
                HStack {
                    Button("Clean Interrupted Downloads") { Task { await store.cleanupInterrupted() } }
                        .disabled(store.busy)
                    Text("Only GenStudio's abandoned staging files. Saved partial downloads are kept.").font(.caption).foregroundStyle(.secondary)
                }
                if store.partialDownloadCount > 0 {
                    HStack {
                        Button("Discard Saved Downloads…") { confirmDiscardPartials = true }
                            .disabled(store.busy)
                        Text("\(store.partialDownloadCount) unfinished download(s) · \(ModelLibraryViewModel.bytes(store.partialDownloadBytes)). Installing the same recipe again resumes them.").font(.caption).foregroundStyle(.secondary)
                    }
                    .confirmationDialog("Discard saved downloads?", isPresented: $confirmDiscardPartials) {
                        Button("Discard \(ModelLibraryViewModel.bytes(store.partialDownloadBytes))", role: .destructive) { Task { await store.discardPartialDownloads() } }
                    } message: {
                        Text("This frees disk space but loses resume progress: those files will download again from the beginning. Installed models are not affected.")
                    }
                }
                if !store.busy && !store.progressText.isEmpty { Text(store.progressText).font(.caption).foregroundStyle(.secondary) }
                Text(generationRunning ? "Generation is running independently of downloads. The engine releases its model when this run ends." : "Models load for each generation and unload when the process exits. Downloads can continue independently in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .task { await store.refresh() }
        .sheet(item: $selectedRecipe) { recipe in ModelInstallSheet(store: store, recipe: recipe) }
        .fileImporter(isPresented: $showingManifestImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { store.importUserManifest(from: url) }
        }
    }

    private var modelScoutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find a working model").font(.title2.bold())
            Text("Searches only exact GenStudio packages with a retained successful run and a runtime included in this build. Hub popularity, matching file formats and an installable adapter are not enough to appear here.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("e.g. text + vision, image editing, video upscale", text: $store.scoutQuery)
                    .textFieldStyle(.roundedBorder)
                Button("Import manifest…") { showingManifestImporter = true }
            }
            if !store.scoutCatalogMatches.isEmpty {
                Text("Verified matches").font(.headline)
                ForEach(store.scoutCatalogMatches) { recipe in recipeRow(recipe) }
            } else if !store.scoutQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("No proven package matches. GenStudio will not substitute an untested model.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Import is retained for recovery and developer testing, but imported models do not enter normal search until a real run validates their exact recipe and task.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Space.lg).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.md))
    }
    private func recipeRow(_ recipe: ModelRecipe) -> some View {
        let fit = store.compatibility(recipe)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(ModelRecipePresentation.title(recipe)).font(.headline)
                ModelPurposeTags(purposes: [ModelRecipePresentation.purposeTag(recipe.kind)])
                ModelSizeBadge(value: ModelLibraryViewModel.bytes(recipe.totalBytes), label: "Download", detail: "Includes this model and every supporting component in its installation package.")
                Text(ModelRecipePresentation.purpose(recipe)).font(.callout)
                Text(ModelRecipePresentation.limits(recipe)).font(.callout).foregroundStyle(.secondary)
                Text(fit.label).font(.callout.bold())
                Text(fit.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            VStack(alignment: .trailing, spacing: 6) {
                ModelInstallControl(store: store, recipe: recipe) { selectedRecipe = recipe }
                if store.isInstalled(recipe.id), let update = store.updates[recipe.id], let candidate = update.candidate {
                    // Updates are generated from verified repository
                    // metadata and are installed into the app-owned model
                    // library. Manual file selection remains available
                    // only from the explicit import/review flow.
                    Button("Install Update") { store.install(candidate) }
                        .disabled(store.busy)
                }
            }
        }.padding(Space.lg).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    @ViewBuilder private var coreModelChecklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Start here: compact creative core").font(.title2.bold())
                Spacer()
                Button(store.bulkInstalling ? "Setting up…" : "Set Up Working Core") {
                    store.installRunnableStarterSet()
                }
                .disabled(store.bulkInstalling || store.busy)
            }
            Text("Only models that met a speed-and-quality bar on this M1 Max: Qwen 3.8 MLX for text and image understanding, FLUX.2 Klein 9B for image creation and editing, FastMetal 5B for fast video drafts, LTX-2.3 MLX Q4 for final and image-to-video, and Real-ESRGAN for finishing. Each was measured here.")
                .font(.callout).foregroundStyle(.secondary)
            multitaskRecommendationRow
            recommendedRecipeRow(MediaModelCatalog.klein9BRecipeID,
                                 title: "Images and editing · FLUX.2 Klein 9B",
                                 detail: "About 32 s at 512² and 2 min at 1024²; third-best open-weight editor. FLUX Non-Commercial License — a separate licence is needed for commercial work.")
            fastMetalEvaluationRow
            ltxEvaluationRow
            recommendedRecipeRow(UpscaleCapabilityRegistry.realesrganX4PlusRecipeID,
                                 title: "Finishing · Real-ESRGAN",
                                 detail: "Recommended general image and video upscaling model.")
            Text(store.starterQueueSummary)
                .font(.callout.bold()).foregroundStyle(store.starterPendingRecipes.isEmpty ? .green : .blue)
            Text("One Qwen download serves Local Text, Image Describer and Character Sheet. Klein 9B serves Image Generator. Real-ESRGAN serves Image Upscale and frame-based Video Upscale. Deterministic editing and delivery nodes need no model.")
                .font(.caption).foregroundStyle(.secondary)
            if !store.bulkQueueDescription.isEmpty {
                Label(store.bulkQueueDescription, systemImage: "arrow.down.circle").font(.callout).foregroundStyle(.blue)
            }
            Text("Measured here: FastMetal 5B drafts a 5 s 832×480 clip in about 1½ min (under a minute as a fast draft). LTX-2.3 MLX Q4 makes a 5 s 768×448 clip in about 3 min (text-to-video and image-to-video), peaking at about 22 GB of memory.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Space.lg)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    @ViewBuilder private var ltxEvaluationRow: some View {
        if let recipe = ModelCatalog.recipes.first(where: { $0.id == MLXVideoModelCatalog.ltx23Q4RecipeID }) {
            let installedModel = store.installed.first { $0.id == recipe.id && $0.available }
            let installed = installedModel != nil
            let i2vVerified = VideoCapabilityRegistry.ltx23ImageToVideo.readiness.proven || installedModel?.hasVerifiedVideoTask(.imageToVideo) == true
            let t2vVerified = VideoCapabilityRegistry.ltx23TextToVideo.readiness.proven || installedModel?.hasVerifiedVideoTask(.textToVideo) == true
            let fullyVerified = i2vVerified && t2vVerified
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: fullyVerified ? "checkmark.seal.fill" : (installed ? "checkmark.circle.fill" : "photo.stack"))
                    .foregroundStyle(fullyVerified ? Color.green : (installed ? Color.green : Color.orange))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Video — Image to Video / Flexible · LTX-2.3 MLX Q4\(fullyVerified ? " · recommended" : "")").fontWeight(.semibold)
                    Text(fullyVerified
                         ? "Verified through decoded I2V and T2V graph renders on the reference M1 Max."
                         : installed
                            ? "Installed. Proof: I2V \(i2vVerified ? "complete" : "pending") · T2V \(t2vVerified ? "complete" : "pending")."
                            : "Apple Silicon · Native MLX · T2V · I2V · complete pinned model, Gemma, VAE and upscaler recipe.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(fullyVerified ? "Recommended" : "Controlled") still-to-motion production · distilled two-stage mode · video-only output.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                ModelInstallControl(store: store, recipe: recipe, actionTitle: fullyVerified ? "Install" : "Download & Test") { selectedRecipe = recipe }
            }
            .padding(Space.md).background((fullyVerified ? Color.green : Color.orange).opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    @ViewBuilder private var fastMetalEvaluationRow: some View {
        if let recipe = ModelCatalog.recipes.first(where: { $0.id == MLXVideoModelCatalog.fastMetal5BRecipeID }) {
            let installed = store.installed.contains { $0.id == recipe.id && $0.available }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: installed ? "checkmark.circle.fill" : "testtube.2")
                    .foregroundStyle(installed ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Video · FastMetal-5B-QAD · fast drafts").fontWeight(.semibold)
                    Text(installed ? "Installed. Measured on this M1 Max: a 5-second 832×480 clip in 88 s (46 s as a fast draft), 1280×704 in 319 s. Your first run in a workflow records its proof." : "Apple Silicon MLX · 3 steps · measured on this M1 Max: a 5-second 832×480 clip in 88 s (46 s as a fast draft), 1280×704 in 319 s.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Works with: Text to Video. Does not work with: Image to Video. No audio claim.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                ModelInstallControl(store: store, recipe: recipe, actionTitle: "Download & Test") { selectedRecipe = recipe }
            }
            .padding(Space.md).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    private var multitaskRecommendationRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.hasMultitaskCore ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(store.hasMultitaskCore ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Text + vision · Qwen 3.8 27B MLX 4-bit").fontWeight(.semibold)
                Text(store.hasMultitaskCore ? "Installed and proven locally: \(store.installedMultitaskModels.map(\.name).joined(separator: ", "))" : "Recommended shared model for Local Text, Image Describer and Prompt Enhancer. Exact 16.1 GB package; four retained vision runs completed in about 44–82 seconds on this M1 Max.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.md)
            if store.hasMultitaskCore {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
                    .frame(width: ModelInstallControl.regularWidth, alignment: .trailing)
            } else if let recipe = ModelCatalog.recipes.first(where: { $0.id == MLXVLMModelCatalog.qwen38RecipeID }),
                      store.activeRecipeID == recipe.id || store.queuePosition(recipe.id) != nil {
                // Once preparation has admitted the package, it behaves like every other listing.
                ModelInstallControl(store: store, recipe: recipe)
            } else {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    Button { prepareMultitaskCore(reviewOnly: false) } label: {
                        Label(preparingMultitaskCore ? "Preparing…" : "Install · 16.1 GB", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(preparingMultitaskCore)
                    Button("Details") { prepareMultitaskCore(reviewOnly: true) }
                        .buttonStyle(.link).font(.callout)
                }
                .frame(width: ModelInstallControl.regularWidth, alignment: .trailing)
            }
        }
        .padding(Space.md).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    @ViewBuilder private func recommendedRecipeRow(_ id: String, title: String, detail: String) -> some View {
        if let recipe = ModelCatalog.recipes.first(where: { $0.id == id }) {
            let installed = store.installed.contains { $0.id == id && $0.available }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(installed ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.semibold)
                    Text(installed ? "Installed: \(recipe.name)" : detail)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.md)
                ModelInstallControl(store: store, recipe: recipe) { selectedRecipe = recipe }
            }
            .padding(Space.md).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    private func prepareMultitaskCore(reviewOnly: Bool) {
        guard !preparingMultitaskCore else { return }
        preparingMultitaskCore = true
        Task {
            defer { preparingMultitaskCore = false }
            do {
                let recipe = try await store.prepareRecommendedMultitaskCore()
                if reviewOnly { selectedRecipe = recipe } else { store.requestInstall(recipe) }
            } catch {
                store.failure = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var intelligenceGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Setup guide", systemImage: "apple.intelligence")
                    .font(.headline)
                Spacer()
                Button(store.intelligenceBusy ? "Thinking…" : "Explain my setup") {
                    store.explainSetup()
                }
                .disabled(store.intelligenceBusy)
            }
            Text("Apple Intelligence can explain the models that already passed GenStudio's hardware checks. It does not choose compatibility, install files or change workflow settings.")
                .font(.caption).foregroundStyle(.secondary)
            if store.intelligenceBusy { StudioSpinner() }
            if let guidance = store.intelligenceGuidance {
                Text(guidance).font(.callout).textSelection(.enabled)
            }
            if store.intelligenceUnavailable {
                Text("Apple Intelligence is unavailable or still preparing on this Mac, so GenStudio is showing its built-in offline guidance instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Only catalog names, purposes and hardware totals are used; model weights, images and private files stay local.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(Space.lg)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
    }
}

struct ModelInstallSheet: View {
    @ObservedObject var store: ModelLibraryViewModel
    let recipe: ModelRecipe
    @Environment(\.dismiss) private var dismiss
    @State private var files: [String: URL] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ModelRecipePresentation.title(recipe)).font(.title2.bold())
            ModelPurposeTags(purposes: ModelRecipePresentation.purposeTags(recipe))
            ModelSizeBadge(value: ModelLibraryViewModel.bytes(recipe.totalBytes), label: "All components", detail: "Every required component. Components already installed with identical content are reused instead of downloaded; see below.")
            Text(ModelRecipePresentation.purpose(recipe)).font(.callout)
            if ModelLibraryViewModel.isMediaRecipe(recipe) {
                MediaRecipeFitDetails(fit: store.mediaFit(recipe), recipe: recipe)
            } else {
                Text(store.fit(recipe).detail).font(.caption).foregroundStyle(.secondary)
                Text("Allow \(ModelLibraryViewModel.bytes(ModelLibraryViewModel.stagingBytes(recipe))) free for download, staging and scratch").font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(recipe.components, id: \.id) { component in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(component.role) · \(ModelLibraryViewModel.bytes(component.byteSize))").fontWeight(.semibold)
                            Text("License: \(component.license)").font(.caption)
                            DisclosureGroup("Advanced file details") {
                                Text(component.filename).font(.caption).textSelection(.enabled)
                                if let url = URL(string: "https://huggingface.co/\(component.repository)/tree/\(component.revision)") { Link("\(component.repository) · revision \(component.revision.prefix(12))", destination: url).font(.caption) }
                                Text("SHA-256: \(component.sha256)").font(.caption2.monospaced()).textSelection(.enabled)
                            }
                            HStack {
                                Button("Choose Local File…") { choose(component.id) }
                                Text(files[component.id]?.lastPathComponent ?? "No local file selected").font(.caption).lineLimit(1)
                            }
                        }
                    }
                }
            }
            Text("Only these pinned files are supported. Review each model's license on Hugging Face before installation. A successful import verifies file integrity; runtime verification follows a real generation.").font(.caption).foregroundStyle(.secondary)
            Text("If you cancel, quit or lose your connection, downloaded data is kept and installing this recipe again resumes it. Every file is fully re-checked before the model is added.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Import Selected Files") { store.install(recipe, files: files); dismiss() }
                    .disabled(files.count != recipe.components.count || !store.canInstall(recipe))
                Button("Download and Install") { store.install(recipe); dismiss() }
                    .disabled(!store.canInstall(recipe))
            }
        }.padding(24).frame(width: 680, height: 640)
    }
    private func choose(_ componentID: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { files[componentID] = url }
    }
}


enum ModelRecipePresentation {
    static func purposeTag(_ kind: GenerationModelKind) -> ModelPurpose {
        switch kind {
        case .text: .textWriting
        case .image: .imageGeneration
        case .video: .videoGeneration
        case .vision: .imageUnderstanding
        case .upscaler: .imageUpscaling
        case .speech: .speechGeneration
        }
    }
    static func installedPurpose(_ model: InstalledGenerationModel) -> String {
        if let recipe = model.recipeSnapshot ?? ModelCatalog.recipes.first(where: { $0.id == model.id }) {
            return purpose(recipe)
        }
        return purposeTag(model.kind).summary
    }
    static func title(_ recipe: ModelRecipe) -> String {
        switch recipe.id {
        case "qwen25-05b-q4km": "Qwen · Lightweight Text"
        case MLXVLMModelCatalog.qwen38RecipeID: "Qwen 3.8 27B · Shared Text + Vision (verified M1 Max)"
        case "sd15-q4": "Stable Diffusion · Image Creation (fallback)"
        case MediaModelCatalog.juggernautXLRecipeID: "Juggernaut XL v9 · Photorealistic Image Creation (test candidate)"
        case MediaModelCatalog.kleinRecipeID: "FLUX.2 Klein 4B · Image Creation & Editing (verified local baseline)"
        case MediaModelCatalog.klein9BRecipeID: "FLUX.2 Klein 9B · Image Creation & Editing (needs benchmark)"
        case MediaModelCatalog.zImageTurboRecipeID: "Z-Image Turbo · Image Creation, commercial use (first run is the test)"
        case "wan21-13b-q4": "Wan · Video Generation"
        case UpscaleCapabilityRegistry.realesrganX4PlusRecipeID: "Real-ESRGAN · Image & Video Upscale (General)"
        case UpscaleCapabilityRegistry.realesrganX4PlusAnimeRecipeID: "Real-ESRGAN · Image & Video Upscale (Illustration)"
        default: recipe.name
        }
    }
    /// The exact Klein 4B route is the current evidence-backed image default:
    /// it has a decoded local T2I proof and a separately measured reference
    /// editing proof. Do not promote an unmeasured sibling by family name.
    static let recommendedImageRecipeID = MediaModelCatalog.kleinRecipeID
    /// The recommended default first, then every other recipe in its original relative order.
    static func orderedForRecommendation(_ recipes: [ModelRecipe]) -> [ModelRecipe] {
        let recommended = recipes.filter { $0.id == recommendedImageRecipeID }
        let rest = recipes.filter { $0.id != recommendedImageRecipeID }
        return recommended + rest
    }
    /// Purpose tags come from the exact recipe's task descriptors, not from its family or hub tags.
    static func purposeTags(_ recipe: ModelRecipe) -> [ModelPurpose] {
        if recipe.workflowCapabilities == [.textGeneration, .imageUnderstanding] {
            return [.textWriting, .imageUnderstanding]
        }
        let tasks = RecipeTaskStatus.statuses(recipeID: recipe.id)
        var tags: [ModelPurpose] = []
        if recipe.kind == .image || tasks.contains(where: { $0.title == ImageTask.textToImage.title }) { tags.append(.imageGeneration) }
        if tasks.contains(where: { $0.title == ImageTask.imageToImage.title || $0.title == "Reference image edit" }) { tags.append(.imageEditing) }
        if recipe.kind == .video { tags.append(.videoGeneration) }
        if recipe.kind == .upscaler { tags.append(.imageUpscaling) }
        return tags.isEmpty ? [purposeTag(recipe.kind)] : tags
    }
    static func purpose(_ recipe: ModelRecipe) -> String {
        switch recipe.kind {
        case .vision:
            recipe.id == MLXVLMModelCatalog.qwen38RecipeID
                ? "One local MLX package writes text and understands reference images. Use it in Local Text, Image Describer and picture-aware Prompt Enhancer nodes."
                : VisionModelCatalog.purpose(recipe.id)
        case .text: "Writes and rewrites text from your instructions, such as captions, ideas or prompts for the next node. Use in a Text Model node; check the model’s limitations below."
        case .image: MediaModelCatalog.profile(recipe.id).map { "\($0.summary) Use in an Image Generator node." } ?? "Creates still images from a written prompt. Use in an Image Generator node."
        case .video: recipe.id == VideoCapabilityRegistry.wanT2VRecipeID ? "Turns a written scene description into a short, low-resolution video clip. Use in a Text to Video node. Text-to-video only; it cannot animate images or join start/end frames." : MediaModelCatalog.profile(recipe.id)?.summary ?? "Designed to turn written scene descriptions into moving video clips. GenStudio has no verified adapter for this package."
        case .speech: "Speaks a script in a voice you describe in plain words, such as a warm South African woman. Use it in a Voiceover node to lay a voice over a finished video."
        case .upscaler: recipe.id == UpscaleCapabilityRegistry.realesrganX4PlusAnimeRecipeID
            ? "Enlarges a connected image or short video 2× or 4× using a learned model trained for illustration, animation and line work. The same download works in Image Upscale and Video Upscale nodes."
            : "Enlarges a connected image or short video 2× or 4× using a learned model trained for photography and mixed artwork. The same download works in Image Upscale and Video Upscale nodes."
        }
    }
    static func limits(_ recipe: ModelRecipe) -> String {
        if recipe.id.hasPrefix("text-gguf-") || recipe.baseRecipeID != nil {
            return "Untested version. Text GGUF imports require an enabled architecture and embedded chat template; image/video updates need separate adapter verification. Your first generation may take longer while the engine initializes."
        }
        return switch recipe.kind {
        case .vision:
            recipe.id == MLXVLMModelCatalog.qwen38RecipeID
                ? "Exact 4-bit package uses about 16.1 GB on disk and is intended for the 64 GB M1 Max profile. Four retained multi-image vision runs completed in about 44–82 seconds; a 24-token managed-runtime text health run completed in about 10 seconds. Accuracy remains prompt- and image-dependent."
                : VisionModelCatalog.limits(recipe.id)
        case .text: "Small text-only model with limited instruction following and repetition. It failed two local prompt-writing checks; review every output and do not rely on it as a prompt assistant."
        case .image: recipe.id == ImageCapabilityRegistry.sd15RecipeID ? "GenStudio's always-verified fallback image model, kept for when FLUX.2 Klein's first experimental run has not been completed or approved. Older SD 1.5 quality; start at 512 × 512. A standalone 20-step run took about 94 seconds on M1 Max / 64 GB; actual times vary. Image to image has its own proof status below." : (MediaModelCatalog.profile(recipe.id)?.notes.joined(separator: " ") ?? "")
        case .video: recipe.id == VideoCapabilityRegistry.wanT2VRecipeID ? "Experimental quality: short 320×192-class clips with softness, morphing and flicker. Measured directly against the pinned engine on M1 Max / 64 GB (18 Sep 2026): 320×192, 9 frames, 20 steps takes about 89 seconds — VAE decode, not sampling, is the dominant cost. Generate small and enlarge with Video Upscale rather than raising generation resolution; about 190 seconds end to end for a 1280×768 delivery, roughly 4.7× faster than generating at that resolution directly. If you already have the three component files, use Import Existing Files instead of downloading." : (MediaModelCatalog.profile(recipe.id)?.notes.joined(separator: " ") ?? "Not executable in this app; shown for compatibility discovery only.")
        case .speech: "About 3.1 GB. Measured on this M1 Max: about 6 seconds of speech in 10 seconds including loading, about 7.7 GB peak memory. Each take sounds slightly different, and the accent follows your description only approximately; listen before you publish. Apache-2.0."
        case .upscaler: "Learned detail may modify faces, text, logos and fine patterns; always compare with the source at 100% and use Image Resize instead where exact pixels matter. Verified through GenStudio's bundled Metal adapter on this M1 Max. The official RealESRGAN_x2plus checkpoint is not supported by this runtime and is deliberately not offered here (it silently returns an unchanged image)."
        }
    }
}
