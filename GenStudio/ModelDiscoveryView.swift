import SwiftUI

extension DiscoveryDetail: Identifiable { var id: String { model.id } }

extension DiscoveryTask {
    var title: String {
        switch self {
        case .all: "All tasks"
        case .text: "Text & prompts"
        case .vision: "Image understanding"
        case .image: "Image generation"
        case .imageEditing: "Image editing"
        case .video: "Text to video"
        case .imageToVideo: "Image to video"
        case .audio: "Sound generation"
        case .speech: "Speech generation"
        case .transcription: "Speech to text"
        case .textAnalysis: "Text analysis"
        case .textExtraction: "Extract names & details"
        case .questionAnswering: "Answer questions"
        case .similarity: "Text similarity & search"
        case .summarization: "Summaries"
        case .translation: "Translation"
        case .imageCaptioning: "Image captions"
        case .visualQuestions: "Visual questions"
        case .documents: "Document understanding"
        case .audioAnalysis: "Audio analysis"
        case .audioEditing: "Audio transformation"
        }
    }
}
extension DiscoverySort {
    var title: String { switch self { case .latest: "Newest releases"; case .downloads: "Most downloaded"; case .trending: "Trending" } }
}

struct ModelDiscoveryView: View {
    @ObservedObject var store: ModelLibraryViewModel
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find models for this Mac").font(.title2.bold())
            Text("Only complete GenStudio packages that pass this Mac’s runtime, memory and storage checks are listed. Unsupported, adapterless and resource-limited models are excluded.").font(.callout).foregroundStyle(.secondary)
            ModelDiscoveryTabs(selection: store.discoveryCategory) { category in
                store.selectDiscoveryCategory(category, query: query)
            }
            Text(store.discoveryCategory.explanation).font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Search GenStudio-ready models", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.primary.opacity(0.16)))
                    .onSubmit(search)
                Button("Search", action: search)
            }
            .padding(.vertical, 8)
            Picker("Use", selection: $store.discoveryTask) {
                ForEach(store.discoveryCategory.availableTasks, id: \.self) { Text($0 == .all ? "All uses" : $0.title).tag($0) }
            }
            Text("File sizes describe storage on disk. Memory requirements are checked separately.").font(.callout).foregroundStyle(.secondary)
            CompatibleModelFeed(store: store, query: query)
            if !store.onlyCompatibleModels {
                if let date = store.discoveryDate {
                    Text("\(store.discoveryCached ? "Saved results · offline or request unavailable" : "Live results") · checked \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)

                }
                if store.searching { HStack(spacing: 8) { StudioSpinner(); Text("Searching the model hub…") } }
                if store.inspecting { HStack(spacing: 8) { StudioSpinner(); Text("Checking model files and capabilities…") } }
                Text("NSFW labels use publisher-supplied Hugging Face metadata. An unlabelled repository is not guaranteed to contain only general-audience content.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.unknownPurposeCount > 0 {
                    Toggle("Include unclassified (\(store.unknownPurposeCount))", isOn: $store.showUnknownPurposes)
                        .toggleStyle(.switch).controlSize(.small)
                    Text("These models have incomplete purpose metadata. You can still inspect their publisher descriptions.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(store.discoveryWarnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if store.discoveryDate != nil && !store.searching {
                    Text("Showing \(store.visibleDiscoveryModels.count) models").font(.caption).foregroundStyle(.secondary)
                    if store.visibleDiscoveryModels.isEmpty {
                        Text(store.unknownPurposeCount > 0 ? "This page only contains unclassified models. Include them above, load more, or choose another category." : "No matching models. Try another use or search term.").foregroundStyle(.secondary)
                    }
                }
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.visibleDiscoveryModels) { model in
                        ModelDiscoveryCard(store: store, model: model)
                    }
                }
                if store.discoveryHasMore { Button("Load More") { store.loadMore() }.disabled(store.searching) }
            }
        }
        .sheet(item: $store.discoveryDetail) { detail in ModelDiscoveryDetailView(store: store, detail: detail) }
        .task { if store.hardware == nil { await store.refresh() } }
    }
    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { Task { await store.refresh() } }
    }
}

private struct ModelDiscoveryCard: View {
    @ObservedObject var store: ModelLibraryViewModel
    let model: DiscoveryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.id).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text("Model repository").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                Button("Inspect", systemImage: "arrow.up.right.square") { store.inspect(model.id) }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 7) {
                ModelPurposeTags(purposes: model.purposes)
                ModelAudienceTag(isAdultContent: model.isAdultContent)
                ModelPackageTag(classification: ModelPackageClassification.classify(model: model, files: []), onlyAdapters: true)
            }
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.taskSummary).font(.title2).foregroundStyle(.primary)
                if let description = model.publisherDescription, !description.isEmpty {
                    Text(description).font(.title2).lineLimit(5).textSelection(.enabled)
                    Text("Publisher description").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 18) {
                ModelDiscoveryFact(label: "Storage", content: AnyView(DiscoveryModelSizeView(store: store, model: model)))
                ModelDiscoveryFact(label: "License", value: model.license ?? "Not specified")
                ModelDiscoveryFact(label: "Access", value: model.gated ? "Publisher access required" : "Public metadata")
            }
            Text(model.gated ? "This repository requires publisher access before files can be downloaded." : "Inspect the model to check exact files, hardware fit, runtime support and installation options.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(.white.opacity(0.08)))
    }
}

private struct ModelDiscoveryFact: View {
    let label: String
    var value: String? = nil
    var content: AnyView? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            if let value { Text(value).font(.caption).lineLimit(2) }
            else if let content { content.font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelDiscoveryDetailView: View {
    @ObservedObject var store: ModelLibraryViewModel
    let detail: DiscoveryDetail
    @Environment(\.dismiss) private var dismiss
    @State private var recipe: ModelRecipe?
    @State private var error: String?
    @State private var preparing = false
    private var fileSize: ModelSizeSummary {
        ModelSizeSummary.summarize(repository: detail.model.id, revision: detail.model.sha, files: detail.files)
    }
    private var compatibility: ModelCompatibility.Assessment {
        ModelCompatibility.assess(detail: detail, hardware: store.hardware, installedModels: store.installed)
    }
    private var packageGuidance: ModelPackageGuidance {
        ModelPackageGuidance.make(detail: detail, installedIDs: Set(store.installed.filter(\.available).map(\.id)))
    }
    private var assessment: DiscoveryAssessment {
        ModelDiscovery.assess(detail: detail, hardware: store.hardware ?? HardwareProfile.current(storageURL: store.library.root))
    }
    private var candidate: ModelCandidate? {
        ModelCandidateCatalog.candidate(forRepository: detail.model.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(detail.model.id).font(.title2.bold()).textSelection(.enabled); Spacer(); Button("Done") { dismiss() } }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        ModelPurposeTags(purposes: detail.model.purposes)
                        ModelAudienceTag(isAdultContent: detail.model.isAdultContent)
                        ModelPackageTag(classification: packageGuidance.classification)
                    }
                    if detail.model.isAdultContent {
                        Text("The publisher marked this repository as not for all audiences. This label is informational and does not block installation when the model has a compatible GenStudio recipe. Review its model card and licence before use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let candidate {
                        ModelCandidateDecisionCard(candidate: candidate, detail: detail, hardware: store.hardware)
                    } else {
                        ModelDecisionCard(guidance: packageGuidance, review: { recipe = $0 })
                    }
                    if !packageGuidance.references.isEmpty {
                        KnownRecipeRouteCards(store: store, references: packageGuidance.references, installed: store.installed, hardware: store.hardware, review: { recipe = $0 })
                    }
                    Text("Files in this repository").font(.headline)
                    ModelSizeBadge(value: fileSize.title, label: fileSize.minBytes == nil ? "" : fileSize.label, detail: fileSize.detail)
                    Text(fileSize.detail).font(.callout).foregroundStyle(.secondary)
                    Text(detail.model.taskSummary).font(.title2)
                    if let description = detail.model.publisherDescription ?? detail.publisherExcerpt {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("From the publisher").font(.headline)
                            Text(description).font(.title2).textSelection(.enabled)
                            Text("Publisher’s description; quality and speed have not been independently assessed by this summary.").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No short publisher description was available. The task explanation above comes from the model’s published tags; read its model card for examples and intended uses.").font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    ModelCompatibilityBadge(assessment: compatibility)
                    Text(compatibility.detail)
                    Text(assessment.storageExplanation).font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Apple Intelligence assessment", systemImage: "apple.intelligence")
                                .font(.headline)
                            Spacer()
                            Button(store.intelligenceModelBusy ? "Assessing…" : "Assess this model") {
                                store.analyzeModel(detail: detail)
                            }
                            .disabled(store.intelligenceModelBusy)
                        }
                        Text("This explains GenStudio's deterministic result and ranks the exact route. It cannot invent an adapter, override the install check or change workflow settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        if store.intelligenceModelBusy { StudioSpinner() }
                        if let analysis = store.intelligenceModelAnalysis {
                            Text(analysis).font(.callout).textSelection(.enabled)
                        }
                        if store.intelligenceModelUnavailable {
                            Text("Apple Intelligence was unavailable, so GenStudio provided its built-in offline assessment.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
                    Text("License: \(detail.model.license ?? "Not specified — read the model card")").font(.callout)
                    if let url = URL(string: "https://huggingface.co/\(detail.model.id)") { Link("Read the publisher’s model card, examples and limitations", destination: url) }
                    Text("\(detail.isCached ? "Saved metadata" : "Metadata checked") · \(detail.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    if detail.model.gated { Text("This publisher requires a Hugging Face account and licence acceptance. You can accept the licence on the model page, but GenStudio does not send Hugging Face credentials yet, so its gated files cannot be downloaded here. GenStudio never asks for or stores a Hugging Face token.").foregroundStyle(.orange) }
                    if let note = detail.configNote { Text(note).font(.callout) }
                    if !detail.experimentalTextFiles.isEmpty {
                        Divider()
                        Text("Try a local text model").font(.headline)
                        Text("Choose one quantization. Lower-bit files usually save memory, with possible quality loss. Installation validates the checksum, standalone GGUF structure, enabled text architecture and embedded chat template. Generation speed and results remain untested until you run it.").font(.callout)
                        Text("The text adapter does not enable vision, audio or tool execution. No accompanying code or Python packages are installed.").font(.callout).foregroundStyle(.secondary)
                        ForEach(detail.experimentalTextFiles) { file in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(file.path).font(.callout).textSelection(.enabled)
                                    Spacer()
                                    Button("Review Install…") {
                                        preparing = true
                                        Task { defer { preparing = false }; do { recipe = try await store.prepareTextRecipe(detail: detail, file: file) } catch { self.error = error.localizedDescription } }
                                    }.disabled(detail.model.gated || preparing)
                                }
                                Text(fileGuidance(file)).font(.callout).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                    if !detail.mlxVLMFiles.isEmpty {
                        Divider()
                        Text("Add as an MLX vision-and-text model").font(.headline)
                        Text("This installs the complete MLX package—configuration, tokenizer and every weight shard—after GenStudio verifies its app-owned MLX runtime. GenStudio never uses Homebrew, system Python, or a manually maintained Python package for these models.").font(.callout)
                        Text("Package: \(ModelLibraryViewModel.bytes(detail.mlxVLMFiles.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) })) across \(detail.mlxVLMFiles.count) required files.").font(.caption).foregroundStyle(.secondary)
                        Button("Review MLX Install…") {
                            preparing = true
                            Task { defer { preparing = false }; do { recipe = try await store.prepareMLXVLMRecipe(detail: detail) } catch { self.error = error.localizedDescription } }
                        }.disabled(detail.model.gated || preparing)
                    }
                    let imageCheckpointFiles = detail.files.filter { ["safetensors", "ckpt"].contains($0.format) && !$0.path.contains("/") && ($0.bytes ?? 0) > 0 && $0.sha256?.count == 64 }
                    if detail.model.purposes.contains(.imageGeneration) && !imageCheckpointFiles.isEmpty {
                        Divider()
                        Text("Add as an image model").font(.headline)
                        Text("GenStudio can use a public root-level Stable Diffusion checkpoint through its generic stable-diffusion.cpp profile. The first generation is explicitly marked experimental because this exact model has not been measured here.").font(.callout)
                        ForEach(imageCheckpointFiles) { file in
                            HStack {
                                Text(file.path).font(.callout.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button("Add / Review Install…") {
                                    preparing = true
                                    Task { defer { preparing = false }; do { recipe = try await store.prepareImageRecipe(detail: detail, file: file) } catch { self.error = error.localizedDescription } }
                                }.disabled(detail.model.gated || preparing)
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                    ModelPackageTechnicalDetails(guidance: packageGuidance)
                    DisclosureGroup("Repository inventory · \(detail.files.count) files") {
                        Text("\(ModelLibraryViewModel.bytes(detail.knownRepositoryBytes)) \(detail.inventorySizeComplete ? "in the full repository" : "with known sizes"). This may include many alternative versions; it is not the download size of one model or its memory requirement.").font(.callout).foregroundStyle(.secondary)
                        ForEach(detail.files.prefix(100)) { file in
                            HStack { Text(file.path).lineLimit(2); Spacer(); Text(file.bytes.map(ModelLibraryViewModel.bytes) ?? "Size unknown") }.font(.caption)
                        }
                        if detail.files.count > 100 { Text("Showing the first 100 files. See the model hub for the complete inventory.").font(.caption) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 760, height: 670)
        .sheet(item: $recipe) { ModelInstallSheet(store: store, recipe: $0) }
        .task(id: "\(detail.model.id)@\(detail.model.sha ?? "")") {
            store.analyzeModel(detail: detail)
        }
    }
    private func fileGuidance(_ file: DiscoveryFile) -> String {
        guard let bytes = file.bytes else { return "Download size unknown" }
        let device = store.hardware
        let headroom = UInt64(max(0, bytes)) + 4 * 1024 * 1024 * 1024
        let memory = device?.memoryBytes ?? 0
        let fit = memory == 0 ? "Memory check unavailable" : headroom > memory * 3 / 4 ? "Possible, but demanding for available unified memory" : "Plausible memory fit; not benchmarked"
        return "\(ModelLibraryViewModel.bytes(bytes)) download · \(fit). Runtime buffers and context need additional memory."
    }
}

/// Package type chip. Independent of the audience label and of compatibility.
struct ModelPackageTag: View {
    let classification: ModelPackageClassification
    /// Search rows have no file inventory, so only tag-established adapters are shown there.
    var onlyAdapters = false

    var body: some View {
        if !onlyAdapters || [ModelPackageClassification.Kind.lora, .adapter].contains(classification.kind) {
            Label(classification.friendlyTitle, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.md).padding(.vertical, Space.xs + 3)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .help(classification.kind == .lora ? LoRAHelp.short : classification.isStandalone ? "Can be used without other model files." : "Not a standalone generator. Inspect for what it needs.")
        }
    }
    private var symbol: String {
        switch classification.kind {
        case .completeModel: "shippingbox.fill"
        case .modelWeights: "scalemass"
        case .lora, .adapter: "puzzlepiece.extension"
        case .components: "square.stack.3d.up"
        case .diffusersPipeline: "folder"
        case .unknown: "questionmark.circle"
        }
    }
}

/// Reusable plain-language explanation wherever LoRAs appear.
enum LoRAHelp {
    static let short = "A LoRA is a small add-on for an existing image or video model. It can’t generate on its own."
    static let body = "A LoRA is a small add-on for an existing image or video model. It can teach that base model a style, subject, character, product, motion or behaviour without replacing the base model. Each LoRA only works with the base model it was made for, and what it changes depends on how its publisher trained it."
    static let triggerWords = "Trigger words are optional words the publisher used while training. Adding them to your prompt usually makes the add-on’s effect show up more clearly. GenStudio never adds them for you."
}

struct LoRAHelpDisclosure: View {
    @State private var expanded = false
    var body: some View {
        DisclosureGroup("What is a LoRA?", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LoRAHelp.body)
                Text("When add-on support arrives, GenStudio will match it only to its exact declared base model, start at strength 1.0 (lower is subtler, higher is stronger) and let you switch it off at any time. You won’t need to type special prompt codes or file paths.")
                    .foregroundStyle(.secondary)
            }.font(.callout).padding(.top, 4)
        }.font(.callout)
    }
}

/// Curated, evidence-backed guidance for a known family that is not installable in this build.
/// This is deliberately separate from hub classification: an exact repository ID opts into it.
private struct ModelCandidateDecisionCard: View {
    let candidate: ModelCandidate
    let detail: DiscoveryDetail
    let hardware: HardwareProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Not runnable in GenStudio yet", systemImage: "xmark.circle")
                .font(.headline).foregroundStyle(.orange)
            Text("\(candidate.family) is a real local model family and the bundled engine documents it. This app does not yet have a complete validated adapter, so these files cannot be installed or selected in a workflow.")
                .font(.body)

            if !candidate.workflowUses.isEmpty {
                Text("How it would fit your workflow").font(.headline)
                ForEach(Array(candidate.workflowUses.enumerated()), id: \.offset) { _, use in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(use.task) → \(use.node) node").font(.callout.weight(.semibold))
                        Text(use.status).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Published uses: \(candidate.tasks.joined(separator: " · ")). GenStudio has no installable workflow mapping for this family yet.")
                    .font(.body)
            }

            if let total = candidate.routeDownloadBytes {
                Text("Complete assessed local route").font(.headline)
                ModelSizeBadge(value: ModelLibraryViewModel.bytes(total), label: "3 required files",
                    detail: "The combined size of the pinned MiniMax-H3 route below. Temporary installation space and runtime memory are separate.")
                Text("This is the complete video-only route GenStudio assessed—not the size range of alternatives in this one repository. The audio VAE below is an optional extra. This is not an install button because the blockers below remain unresolved.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(candidate.components.enumerated()), id: \.offset) { _, component in
                    componentRow(component)
                }
            }

            Text("Can it work on this Mac?").font(.headline)
            Text(machineGuidance).font(.body)
            if let guidance = candidate.memoryGuidance {
                Text(guidance).font(.callout).foregroundStyle(.secondary)
            }

            Text("What still blocks local generation").font(.headline)
            ForEach(candidate.blockers, id: \.self) { blocker in
                Label(blocker, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func componentRow(_ component: ModelCandidate.Component) -> some View {
        let local = component.repository.caseInsensitiveCompare(detail.model.id) == .orderedSame
        let found = local && detail.model.sha == component.revision && detail.files.contains {
            $0.path == component.filename && $0.bytes == component.byteSize && $0.sha256 == component.sha256
        }
        let status = found ? "Exact pinned file found" : local ? "Assessed route uses pinned revision \(component.revision.prefix(10)); this inspected revision does not match it exactly" : "Required from \(component.repository)"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(component.role).font(.callout.weight(.semibold))
                Spacer()
                Text(ModelLibraryViewModel.bytes(component.byteSize)).font(.callout.monospacedDigit())
            }
            Text(component.filename).font(.callout.monospaced()).textSelection(.enabled)
            Text("\(status) · \(component.note)").font(.callout).foregroundStyle(found ? Color.green : Color.secondary)
        }
        .padding(Space.md)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    private var machineGuidance: String {
        guard let hardware, hardware.memoryBytes > 0 else {
            return "This route has not been measured through GenStudio on this Mac. Memory availability could not be read."
        }
        let memory = ModelLibraryViewModel.bytes(Int64(clamping: hardware.memoryBytes))
        if hardware.memoryBytes >= 42_000_000_000 {
            return "This Mac has \(memory) unified memory. Published M1 Max evidence makes a short local render plausible, but demanding; GenStudio has not validated the route or measured its peak memory and speed."
        }
        return "This Mac has \(memory) unified memory, below the roughly 42 GB resident-memory report for a separate M1 Max setup. GenStudio has not established a configuration that fits this machine."
    }
}

/// A known recipe can span several repositories. Show its complete package independently of the
/// currently inspected repository's alternatives and inventory total.
private struct KnownRecipeRouteCards: View {
    @ObservedObject var store: ModelLibraryViewModel
    let references: [RecipeRepositoryReference]
    let installed: [InstalledGenerationModel]
    let hardware: HardwareProfile?
    let review: (ModelRecipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Complete GenStudio download").font(.headline)
            ForEach(references) { reference in
                let plan = StoragePlan.make(recipe: reference.recipe, installed: installed,
                    clonesShareStorage: hardware?.volumeSupportsCloning ?? false)
                VStack(alignment: .leading, spacing: 5) {
                    Text(ModelRecipePresentation.title(reference.recipe)).font(.callout.weight(.semibold))
                    ModelSizeBadge(value: ModelLibraryViewModel.bytes(reference.recipe.totalBytes), label: "all required components",
                        detail: "The complete pinned recipe across every repository it uses.")
                    if let plan {
                        Text("Downloads \(ModelLibraryViewModel.bytes(plan.downloadBytes)); needs \(ModelLibraryViewModel.bytes(plan.requiredFreeBytes)) free including temporary staging and reserve.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(reference.matchesInspectedRevision
                        ? "This inspected revision supplies: \(reference.roles.joined(separator: ", "))."
                        : "This recipe uses an earlier pinned revision from this repository; installing it does not substitute the current files.")
                        .font(.callout).foregroundStyle(.secondary)
                    ModelInstallControl(store: store, recipe: reference.recipe) { review(reference.recipe) }
                }
                .padding(Space.md)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.sm))
            }
        }
    }
}

/// Decision guidance first: five short answers and one recommendation. Technical evidence lives further down.
private struct ModelDecisionCard: View {
    let guidance: ModelPackageGuidance
    let review: (ModelRecipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Should I use this?").font(.headline)
            row("What is it?", guidance.whatItIs, secondary: guidance.classification.title)
            VStack(alignment: .leading, spacing: 3) {
                Text("How could it help?").font(.callout.weight(.semibold))
                ForEach(guidance.benefits, id: \.self) { Label($0, systemImage: "sparkles").font(.callout) }
                Text(guidance.benefitsNote).font(.callout).foregroundStyle(.secondary)
            }
            row("What does it need?", guidance.needs)
            row("Where would I use it?", guidance.whereToUse)
            if !guidance.classification.triggerWords.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Optional trigger words").font(.callout.weight(.semibold))
                    Text(guidance.classification.triggerWords.joined(separator: " · ")).font(.callout.monospaced()).textSelection(.enabled)
                    Text(LoRAHelp.triggerWords).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(guidance.recommendation.title, systemImage: guidance.recommendation.systemImage).font(.callout.weight(.bold))
                Text(guidance.nextAction).font(.callout)
                ForEach(guidance.references) { reference in
                    Button("Review \(ModelRecipePresentation.title(reference.recipe))…") { review(reference.recipe) }
                }
                if let base = guidance.baseRecipe, !guidance.baseInstalled {
                    Button("Review base model \(ModelRecipePresentation.title(base))…") { review(base) }
                }
            }.padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.sm))
            if guidance.classification.kind == .lora { LoRAHelpDisclosure() }
        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
    }
    private func row(_ question: String, _ answer: String, secondary: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(question).font(.callout.weight(.semibold))
            Text(answer).font(.callout)
            if let secondary { Text("Technical type: \(secondary)").font(.callout).foregroundStyle(.secondary) }
        }
    }
}

private struct ModelPackageTechnicalDetails: View {
    let guidance: ModelPackageGuidance
    var body: some View {
        DisclosureGroup("Technical package details") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Package type: \(guidance.classification.title)")
                if !guidance.classification.baseModels.isEmpty {
                    Text("Declared base model: \(guidance.classification.baseModels.joined(separator: ", "))").textSelection(.enabled)
                }
                ForEach(guidance.references) { reference in
                    Text("\(ModelRecipePresentation.title(reference.recipe)) uses this repository for: \(reference.roles.joined(separator: ", "))\(reference.matchesInspectedRevision ? "" : " · pinned to an earlier file revision")")
                }
                Text("Classified from: \(guidance.classification.evidence.joined(separator: "; ")). Package type is separate from content labels and from compatibility with this Mac.")
                    .foregroundStyle(.secondary)
            }.font(.caption).padding(.top, 4)
        }.font(.callout)
    }
}
