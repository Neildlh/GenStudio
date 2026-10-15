import AppKit
import Combine
import Foundation
import SwiftUI

/// A snapshot of the wiring at one specific port (copied via the canvas's port context menu), ready to be
/// reapplied to a different port of the same direction and type.
struct CopiedPortConnections {
    let sourcePortAddress: PortAddress
    let direction: PortDirection
    let portDataType: PortDataType
    let edges: [StudioEdge]
}

@MainActor
final class StudioModel: ObservableObject {
    /// Deliberately not `@Published`. SwiftUI controls write project edits back
    /// through bindings while a view update is still in flight, and publishing
    /// synchronously from there is exactly the "Publishing changes from within
    /// view updates" warning. The stored value changes immediately — so a second
    /// control reading the same project never observes stale state — while the
    /// change notification is coalesced onto the next main-queue turn, after
    /// SwiftUI has finished the current update transaction. This mirrors the
    /// debounce already applied to the model library's notifications.
    var projects: [WorkflowProject] = [] {
        didSet { scheduleChangeNotification() }
    }
    private var changeNotificationScheduled = false
    @Published var currentProjectID: UUID?
    @Published var selectedNodeID: UUID?
    /// Every node in the canvas selection (mirrored from the canvas) so the inspector can offer bulk edits.
    @Published var multiSelectedNodeIDs: Set<UUID> = []
    @Published var models: [InstalledModel] = []
    @Published var runs: [RunRecord] = []
    @Published var outputs: [TextOutput] = []
    @Published var executionArtifacts: [ExecutionArtifact] = [] { didSet { lookupCache.reset() } }
    /// Takes and latest results derived from `executionArtifacts`, memoized until it changes. The canvas asks
    /// every node for them on every redraw; recomputing them took ~0.4 s per redraw on a 150-node workflow.
    var lookupCache = CanvasLookupCache()
    @Published var alertMessage: String?
    @Published var copiedPortConnections: CopiedPortConnections?
    @Published var deletingProjectIDs: Set<UUID> = []
    @Published var deletingGalleryItemIDs: Set<UUID> = []
    @Published var deletingRunIDs: Set<UUID> = []
    @Published var pendingRun: PendingRun?
    /// A whole-workflow run awaiting one batch confirmation, in the order it will be queued.
    @Published var pendingWorkflowRun: [PendingRun]?
    /// A confirmed-once batch of fresh-seed takes of one node (see `runTakes(of:count:)`).
    @Published var pendingTakeBatch: [PendingRun]?
    @Published var nativeRuntimeState = "Unloaded"
    @Published var isRunning = false
    /// True while a project is being copied into a package folder.
    @Published var isPackaging = false
    /// Set when a package has just been written and the project could now leave the library.
    @Published var packageOffer: PackageOffer?
    /// User-requested node runs waiting for the single local model worker.
    @Published private(set) var queuedRuns: [PendingRun] = []
    @Published var workflowProgress: WorkflowProgress?
    @Published var runtimeValues: [PortAddress: RuntimeValue] = [:]
    @Published var sidebarSection = SidebarSection.projects
    /// Latest attempt status is separate from the last successful take.
    @Published var supersededAttempts: [UUID: String] = [:]
    private let wakeGuard = RunWakeGuard()
    private var batchRecord: RunBatchRecord?
    /// True while anything runs or waits in the queue: the Mac is kept from idling to sleep.
    var isKeepingMacAwake: Bool { wakeGuard.isHolding }
    /// The business details every new End Card and Start Video Ad starts from (`brand-kit.json`).
    @Published var brandKit = BrandKit()

    let library: ModelLibrary
    let libraryStore: ModelLibraryViewModel
    private var libraryObservation: AnyCancellable?
    private var chatGPTSubscriptionObservation: AnyCancellable?
    let persistence: StudioPersistence
    let engine: any TextGenerationEngine
    let queue: ExecutionQueue
    private var runTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// Projects whose folder file could not be written, so the problem is reported once, not on every autosave.
    var mirrorWarnings: Set<UUID> = []
    private var undoStacks: [UUID: [WorkflowProject]] = [:]
    private var redoStacks: [UUID: [WorkflowProject]] = [:]

    enum SidebarSection: String, CaseIterable {
        case projects = "Workspaces", models = "Models", gallery = "Images", history = "Errors"
    }

    struct GalleryMediaItem: Identifiable, Hashable {
        let artifactID: UUID
        let address: PortAddress
        let value: RuntimeValue
        let createdAt: Date
        let defaultName: String
        let name: String
        var id: String { "\(artifactID.uuidString)-\(address.nodeID.uuidString)-\(address.portID)" }
    }

    /// One entry per node/port — the take currently selected or last produced on that
    /// node, not the node's full generation history. Mirrors `displayedValue(for:)`,
    /// generalized across projects since the gallery spans the whole app.
    var galleryMediaItems: [GalleryMediaItem] {
        var currentByAddress: [PortAddress: (artifact: ExecutionArtifact, value: RuntimeValue)] = [:]
        for artifact in executionArtifacts {
            for (address, value) in artifact.values {
                switch value {
                case .image, .video: break
                default: continue
                }
                guard artifact.generatedNodeIDs?.contains(address.nodeID) == true else { continue }
                if let existing = currentByAddress[address], existing.artifact.createdAt > artifact.createdAt { continue }
                currentByAddress[address] = (artifact, value)
            }
        }
        let liveNodes = Dictionary(uniqueKeysWithValues: projects.flatMap(\.nodes).map { ($0.id, $0) })
        for address in Array(currentByAddress.keys) {
            guard let node = liveNodes[address.nodeID], node.supportsTakes, let selectedTakeID = node.selectedTakeID,
                  let selected = executionArtifacts.first(where: { $0.id == selectedTakeID }), let value = selected.values[address] else { continue }
            currentByAddress[address] = (selected, value)
        }
        return currentByAddress.map { address, entry in
            let node = entry.artifact.graphSnapshot.nodes.first { $0.id == address.nodeID }
            let fallback = "\(node?.label ?? "Generation") · \(entry.artifact.createdAt.formatted(date: .abbreviated, time: .shortened))"
            let key = Self.galleryMediaKey(address)
            // A locked node's file is named after its heading, so that heading is the name.
            let lockedName = liveNodes[address.nodeID].flatMap { $0.isLockedFinal ? $0.label : nil }
            return GalleryMediaItem(artifactID: entry.artifact.id, address: address, value: entry.value,
                                    createdAt: entry.artifact.createdAt, defaultName: fallback,
                                    name: lockedName ?? entry.artifact.mediaNames?[key] ?? fallback)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func galleryMediaKey(_ address: PortAddress) -> String { "\(address.nodeID.uuidString)/\(address.portID)" }

    private static func defaultModelKey(for kind: NodeKind) -> String {
        "studio.defaultModel.\(kind.rawValue)"
    }

    func defaultModel(for kind: NodeKind) -> String? {
        UserDefaults.standard.string(forKey: Self.defaultModelKey(for: kind))
    }

    func isDefaultModel(_ node: StudioNode) -> Bool {
        guard !node.model.isEmpty else { return false }
        return defaultModel(for: node.kind) == node.model
    }

    /// Coalesces `objectWillChange` onto the next main-queue turn so a mutation
    /// that starts inside a view update publishes after that update finishes.
    private func scheduleChangeNotification() {
        guard !changeNotificationScheduled else { return }
        changeNotificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeNotificationScheduled = false
            self.objectWillChange.send()
        }
    }

    func setDefaultModel(for node: StudioNode) {
        guard !node.model.isEmpty else { return }
        UserDefaults.standard.set(node.model, forKey: Self.defaultModelKey(for: node.kind))
        objectWillChange.send()
    }

    /// Shared with the ChatGPT Subscription Settings window so both read/write the
    /// same connected-or-not state. Experimental, unofficial route; see
    /// ChatGPTSubscriptionAuth.swift.
    let chatGPTSubscription = ChatGPTSubscriptionSessionStore()

    init(persistence: StudioPersistence = StudioPersistence(), engine: (any TextGenerationEngine)? = nil, imageEngine: (any ImageGenerationEngine)? = nil, visionEngine: (any VisionGenerationEngine)? = nil, videoEngine: (any VideoGenerationEngine)? = nil, upscaleEngine: (any ImageUpscaleEngine)? = nil) {
        let modelRoot = persistence.root.appending(path: "ModelLibrary")
        let library = ModelLibrary(root: modelRoot, catalog: ModelCatalog.recipes + UserModelCatalog.load(root: modelRoot))
        self.library = library
        libraryStore = ModelLibraryViewModel(library: library)
        self.persistence = persistence
        brandKit = BrandKit.load(root: persistence.root)
        let textEngine = engine ?? NativeTextEngine(library: library)
        self.engine = textEngine
        let resolvedImage: (any ImageGenerationEngine)? = imageEngine ?? (engine == nil ? ImageEngineRouter(
            local: NativeImageEngine(library: library, outputRoot: persistence.root.appending(path: "GenerationScratch")),
            chatGPTSubscription: ChatGPTSubscriptionImageEngine(authenticator: chatGPTSubscription.authenticator, outputRoot: persistence.root.appending(path: "GenerationScratch"))
        ) : nil)
        let resolvedVision = visionEngine ?? (engine == nil ? NativeVisionEngine(library: library) : nil)
        let resolvedVideo = videoEngine ?? (engine == nil ? LocalVideoEngineRouter(
            stableDiffusion: NativeWanVideoEngine(library: library, scratchRoot: persistence.root.appending(path: "GenerationScratch")),
            fastVideo: MLXFastVideoEngine(library: library, scratchRoot: persistence.root.appending(path: "GenerationScratch")),
            ltx: MLXLTXVideoEngine(library: library, scratchRoot: persistence.root.appending(path: "GenerationScratch"))
        ) : nil)
        let resolvedUpscale: (any ImageUpscaleEngine)? = upscaleEngine ?? (engine == nil ? NativeUpscaleEngine(library: library, outputRoot: persistence.root.appending(path: "GenerationScratch")) : nil)
        let resolvedSpeech: (any SpeechGenerationEngine)? = engine == nil ? MLXSpeechEngine(library: library) : nil
        queue = ExecutionQueue(engine: textEngine, persistence: persistence, imageEngine: resolvedImage, visionEngine: resolvedVision, videoEngine: resolvedVideo, upscaleEngine: resolvedUpscale, speechEngine: resolvedSpeech)
        // Library controls can change their own @Published state while SwiftUI is
        // reconciling a Binding. Forwarding that notification synchronously makes
        // StudioModel publish from inside the same view-update pass. Debouncing on
        // the main queue coalesces a refresh's related property changes and delivers
        // them after SwiftUI has finished the current update transaction.
        libraryObservation = libraryStore.objectWillChange
            .debounce(for: .milliseconds(10), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        chatGPTSubscriptionObservation = chatGPTSubscription.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func generationModels(_ kind: GenerationModelKind) -> [InstalledGenerationModel] {
        let eligible = libraryStore.installed.filter { model in
            // Image adapters may be installed before their first decoded
            // proof. Keep those exact recipes selectable so the inspector's
            // explicit experimental-run opt-in can actually be used.
            if kind == .image, model.kind == .image, model.available, ImageCapabilityRegistry.hasAdapter(model.id) || (model.recipeSnapshot.map(UserModelCatalog.isSupported) == true) {
                return true
            }
            return NodeModelCompatibility.supports(model, kind: kind)
        }
        guard kind == .image else { return eligible }

        // New Image Generator nodes use the first eligible model. Keep the
        // picker aligned with the Model Library's documented production
        // recommendation instead of depending on registry/install order (which
        // commonly leaves the older SD fallback selected after Klein is added).
        let recommendationOrder = Dictionary(uniqueKeysWithValues: ModelRecipePresentation
            .orderedForRecommendation(ModelCatalog.recipes)
            .enumerated()
            .map { ($0.element.id, $0.offset) })
        return eligible.enumerated().sorted { left, right in
            let leftRank = recommendationOrder[left.element.id] ?? recommendationOrder.count
            let rightRank = recommendationOrder[right.element.id] ?? recommendationOrder.count
            if leftRank != rightRank { return leftRank < rightRank }
            return left.offset < right.offset
        }.map(\.element)
    }
    func generationModelIssue(for node: StudioNode) -> String? {
        NodeModelCompatibility.issue(for: node, installed: libraryStore.installed, externalTextModels: Set(models.map(\.name)), cloudSignedIn: chatGPTSubscription.isSignedIn)
    }
    func modelName(_ id: String) -> String { libraryStore.installed.first(where: { $0.id == id })?.name ?? id }
    /// The canvas must not create a reference socket that the selected recipe
    /// cannot consume. The cloud route remains unavailable until the user has
    /// explicitly signed in; this is never a fallback from a local recipe.
    static func imageReferenceLimit(for node: StudioNode, capabilities: [ImageCapability], cloudSignedIn: Bool) -> Int? {
        guard node.kind == .imageGenerator,
              let capability = capabilities.first(where: { $0.recipeID == node.model && $0.task == .imageToImage }),
              capability.engineID != ChatGPTSubscriptionImageEngine.engineID || cloudSignedIn else { return nil }
        return capability.maximumReferenceImages
    }
    func imageReferenceLimit(for node: StudioNode) -> Int? {
        Self.imageReferenceLimit(for: node, capabilities: ImageCapabilityRegistry.runtimeRegistry(installed: libraryStore.installed), cloudSignedIn: chatGPTSubscription.isSignedIn)
    }
    func canAddImageInput(to node: StudioNode) -> Bool {
        guard let limit = imageReferenceLimit(for: node) else { return false }
        return node.imageGeneratorReferencePortIDs.count < limit
    }
    func imageReferenceInputHint(for node: StudioNode) -> String? {
        guard node.kind == .imageGenerator else { return nil }
        guard let limit = imageReferenceLimit(for: node) else { return "Selected model has no reference-image adapter" }
        return "\(node.imageGeneratorReferencePortIDs.count) of \(limit) reference inputs"
    }
    func referenceImages(for node: StudioNode) -> [URL] {
        guard let project = currentProject else { return [] }
        if node.kind == .shotSequence { return node.sequence.anchors.compactMap { sequenceImage(nodeID: node.id, anchor: $0) } }
        return node.inputPorts.filter { $0.type == .image }.compactMap { port in
            guard let edge = project.edges.first(where: { $0.targetID == node.id && $0.targetPortID == port.id }),
                  let source = project.nodes.first(where: { $0.id == edge.sourceID }) else { return nil }
            if source.kind == .imageInput, let path = source.imagePath { return URL(fileURLWithPath: path) }
            let address = PortAddress(nodeID: source.id, portID: edge.sourcePortID)
            let value = source.supportsTakes ? displayedValue(for: source) : runtimeValues[address] ?? latestValue(at: address, inProject: project.id)
            if case .image(let url) = value { return url }
            return nil
        }
    }

    func referenceMentions(forPromptNodeID nodeID: UUID) -> [ReferenceMention] {
        guard let project = currentProject else { return [] }
        return ReferenceMentionCatalog.suggestions(forPromptNodeID: nodeID, in: project)
    }

    var currentProject: WorkflowProject? {
        guard let currentProjectID else { return nil }
        return projects.first { $0.id == currentProjectID }
    }

    func displayedValue(for node: StudioNode) -> RuntimeValue? {
        guard let port = node.outputPorts.first else { return nil }
        let address = PortAddress(nodeID: node.id, portID: port.id)
        if let final = finalValue(for: node) { return final }
        if node.supportsTakes, let value = selectedTake(for: node)?.values[address] { return value }
        guard supersededAttempts[node.id] == nil else { return nil }
        return runtimeValues[address] ?? latestValue(at: address, inProject: currentProjectID)
    }

    /// The newest result at `address` in a workflow's history (`executionArtifacts` is kept newest first).
    func latestValue(at address: PortAddress, inProject projectID: UUID?) -> RuntimeValue? {
        let key = CanvasLookupCache.Key(projectID: projectID, address: address)
        if let cached = lookupCache.latestValues[key] { return cached }
        let value = executionArtifacts.first(where: { $0.graphSnapshot.id == projectID && $0.values[address] != nil })?.values[address]
        lookupCache.latestValues[key] = .some(value)
        return value
    }

    var selectedNode: StudioNode? { currentProject?.nodes.first { $0.id == selectedNodeID } }

    /// Prompt-style cards edit their primary authored text in place. Image and
    /// video prompt cards bind to the same structured field shown in the inspector,
    /// so the canvas never becomes a second, competing source of truth. A stale
    /// editor cannot edit another workflow.
    func promptBinding(for node: StudioNode) -> Binding<String> {
        let projectID = currentProjectID
        return Binding(get: { [weak self] in
            guard let self, self.currentProjectID == projectID,
                  let current = self.currentProject?.nodes.first(where: { $0.id == node.id }) else {
                return Self.primaryPromptText(for: node)
            }
            return Self.primaryPromptText(for: current)
        }, set: { [weak self] text in
            guard let self, self.currentProjectID == projectID else { return }
            self.mutateProjectFromBinding { project in
                guard let index = project.nodes.firstIndex(where: { $0.id == node.id }) else { return }
                switch project.nodes[index].kind {
                case .imagePrompt:
                    var settings = project.nodes[index].imagePromptSettings ?? .init()
                    settings.subject = text
                    project.nodes[index].imagePromptSettings = settings
                case .videoPrompt:
                    var settings = project.nodes[index].videoPromptSettings ?? .init()
                    settings.action = text
                    project.nodes[index].videoPromptSettings = settings
                default:
                    project.nodes[index].prompt = text
                }
            }
        })
    }

    private static func primaryPromptText(for node: StudioNode) -> String {
        switch node.kind {
        case .imagePrompt: node.imagePromptSettings?.subject ?? ""
        case .videoPrompt: node.videoPromptSettings?.action ?? ""
        default: node.prompt
        }
    }


    func start() async {
        let supportRoot = persistence.root
        Task.detached(priority: .background) { StartupMaintenance.run(supportRoot: supportRoot) }
        do {
            var loaded = try await persistence.loadProjects()
            let migratedProjectIDs = Set(loaded.indices.compactMap { projectIndex -> UUID? in
                var changed = false
                for nodeIndex in loaded[projectIndex].nodes.indices {
                    let node = loaded[projectIndex].nodes[nodeIndex]
                    guard isAutoGeneratedLabel(node) else { continue }
                    loaded[projectIndex].nodes[nodeIndex].label = node.kind.title
                    changed = true
                }
                // Projects saved before text-joining nodes kept a free socket have every socket wired; the next
                // wire dropped on one would replace an existing connection.
                let before = loaded[projectIndex]
                loaded[projectIndex].normalizeDynamicTextSockets()
                if loaded[projectIndex] != before { changed = true }
                return changed ? loaded[projectIndex].id : nil
            })
            projects = loaded
            for project in loaded where migratedProjectIDs.contains(project.id) { scheduleSave(project) }
            if let first = loaded.first { currentProjectID = first.id }
            else { currentProjectID = nil }
            runs = try await persistence.loadRuns()
            outputs = try await persistence.loadOutputs()
            executionArtifacts = try await persistence.loadExecutionArtifacts()
        } catch {
            projects = []
            currentProjectID = nil
            alertMessage = error.localizedDescription
        }
        await refreshModels()
    }

    func refreshModels() async {
        await libraryStore.refresh()
        do {
            models = try await engine.listModels()
        } catch { alertMessage = error.localizedDescription }
    }

    func createProject() {
        let project = WorkflowProject(name: "Untitled Workflow", nodes: [], edges: [])
        projects.insert(project, at: 0)
        currentProjectID = project.id
        undoStacks[project.id] = []
        redoStacks[project.id] = []
        selectedNodeID = nil
        scheduleSave(project)
    }

    /// Creates a practical, local-first starting point for short social adverts.
    /// The template deliberately uses only existing node contracts: image
    /// understanding can accept several references, while generation still has
    /// the explicit single-reference contract supported by the current image
    /// adapters. The animatic path is deterministic and does not imply that an
    /// unsupported multi-reference video adapter exists.
    func createShortAdvertWorkflow() {
        let characterSheet = StudioNode(kind: .imageInput, label: "Character Sheet", position: .init(x: 40, y: 80))
        let portrait = StudioNode(kind: .imageInput, label: "Character Portrait", position: .init(x: 40, y: 430))
        let scene = StudioNode(kind: .imageInput, label: "Scene Reference", position: .init(x: 40, y: 780))
        var describer = StudioNode(kind: .imageDescriber, label: "Reference Brief", position: .init(x: 430, y: 260))
        describer.dynamicInputs = [
            .init(id: "character-sheet", label: "Character Sheet", type: .image),
            .init(id: "portrait", label: "Portrait", type: .image),
            .init(id: "scene", label: "Scene", type: .image)
        ]
        var generator = StudioNode(kind: .imageGenerator, label: "Hero Still", position: .init(x: 850, y: 310))
        generator.model = generationModels(.image).first?.id ?? ""
        var sequence = StudioNode(kind: .shotSequence, label: "Advert Shot Sequence", position: .init(x: 1260, y: 180))
        sequence.sequence.anchors = [
            ShotAnchor(id: "shot-1", label: "Setup", holdSeconds: 2.0, transitionNote: "Establish the warm setting", boundaryToNext: .cut),
            ShotAnchor(id: "shot-2", label: "Action", holdSeconds: 2.0, transitionNote: "Show the character action", boundaryToNext: .cut),
            ShotAnchor(id: "shot-3", label: "Punchline / End Card", holdSeconds: 2.0, transitionNote: "Hold the final beat and leave room for end-card copy", boundaryToNext: .cut)
        ]
        let animatic = StudioNode(kind: .animatic, label: "Instagram Animatic", position: .init(x: 1660, y: 300))
        let nodes = [characterSheet, portrait, scene, describer, generator, sequence, animatic]
        func edge(_ source: StudioNode, _ sourcePort: String, _ target: StudioNode, _ targetPort: String, _ type: PortDataType) -> StudioEdge {
            .init(sourceID: source.id, sourcePortID: sourcePort, targetID: target.id, targetPortID: targetPort, type: type)
        }
        let edges = [
            edge(characterSheet, "image", describer, "character-sheet", .image),
            edge(portrait, "image", describer, "portrait", .image),
            edge(scene, "image", describer, "scene", .image),
            edge(describer, "text", generator, "prompt", .text),
            edge(scene, "image", generator, "referenceImage", .image),
            edge(characterSheet, "image", sequence, "shot-1", .image),
            edge(portrait, "image", sequence, "shot-2", .image),
            edge(generator, "image", sequence, "shot-3", .image),
            edge(sequence, "sequence", animatic, "sequence", .shotSequence)
        ]
        let project = WorkflowProject(name: "Short Advert · Character + Scene", nodes: nodes, edges: edges)
        projects.insert(project, at: 0)
        currentProjectID = project.id
        undoStacks[project.id] = []
        redoStacks[project.id] = []
        selectedNodeID = sequence.id
        scheduleSave(project)
    }

    /// A real local video advert: three shots, each a FLUX.2 Klein 9B still animated by the chosen video model
    /// (LTX-2.3 by default), joined in order and exported as a 9:16 vertical video for Instagram, Facebook and
    /// WhatsApp. Every node is ordinary and editable; the canvas note explains the model choices and timings.
    func createLocalVideoAdWorkflow() {
        let installedIDs = Set(libraryStore.installed.filter(\.available).map(\.id))
        let imageModel = [MediaModelCatalog.klein9BRecipeID].first { installedIDs.contains($0) } ?? generationModels(.image).first?.id ?? ""
        let videoModel = [MLXVideoModelCatalog.ltx23Q4RecipeID].first { installedIDs.contains($0) }
            ?? VideoCapabilityRegistry.selectableCapabilities(for: .imageToVideo).first { installedIDs.contains($0.recipeID) }?.recipeID ?? ""
        var clipSettings = VideoCapabilityRegistry.capability(recipeID: videoModel, task: .imageToVideo)?.recommended ?? VideoGenerationSettings()
        clipSettings.width = 576; clipSettings.height = 1024; clipSettings.frameCount = 121; clipSettings.fps = 24
        clipSettings.requestedDurationSeconds = 121.0 / 24.0
        let perClip = VideoCapabilityRegistry.capability(recipeID: videoModel, task: .imageToVideo)
            .flatMap { VideoTimeEstimate.seconds(clipSettings, capability: $0) }.map(VideoTimeEstimate.label) ?? "several minutes"

        func motion(_ action: String, recipe: String, camera: String? = nil, ambience: String) -> VideoPromptSettings {
            var direction = VideoPromptSettings()
            direction.mode = .imageToVideo; direction.action = action
            if let recipe = VideoShotRecipe.all.first(where: { $0.title == recipe }) { direction.apply(recipe) }
            if let camera { direction.cameraMovement = camera }
            direction.ambience = ambience
            return direction
        }
        let shots: [(still: String, motion: VideoPromptSettings)] = [
            ("A confident South African small-business owner smiling at the camera in a bright modern studio in Cape Town, natural window light, clean background, photorealistic, vertical composition with space above the head for a headline",
             motion("The person smiles warmly and gives a small, friendly nod to the camera.", recipe: "Happy customer", ambience: "Natural room tone")),
            ("Close-up of hands working on a laptop showing colourful brand designs on screen, a cup of coffee beside it, warm afternoon light, shallow depth of field, photorealistic, vertical composition",
             motion("The hands type and scroll smoothly while the light from the screen shifts softly.", recipe: "Detail close-up", ambience: "Soft keyboard tapping in a quiet studio")),
            ("The same business owner shaking hands with a happy client in a sunny Johannesburg office, warm golden light, photorealistic, vertical composition with a plain wall on one side for contact details",
             motion("They shake hands and both laugh naturally.", recipe: "Happy customer", camera: "Slow orbit", ambience: "Friendly office chatter"))
        ]
        var note = StudioNode(kind: .stickyNote, label: "How this ad works", position: .init(x: 40, y: 40))
        note.prompt = """
        Local Video Ad · about 18 s, vertical 9:16, with sound
        1. Write each shot's Still prompt. Its Motion node sets the camera move, action and sound; try "Start from a shot recipe".
        2. Edit the End Card: your name, offer and WhatsApp number, then press Save as Brand Kit (and Choose Logo…) so every future ad starts branded.
        3. Run "Ad · 9:16 Export". Each still takes a few minutes (FLUX.2 Klein 9B), each 5 s clip \(perClip) on this Mac, the end card a few seconds.
        4. Not happy with one shot? Generate another take of just that node, then run the export again.
        Sound: LTX-2.3 makes each clip's sound from its Motion node (the setting's ambience, or a short spoken line). For music, select "Ad · Assemble" and choose a music file: it plays under the whole ad, dips under each clip's sound and fades out. No clip sound? Models → Add Sound Files.
        Video model per clip (select a Clip node): LTX-2.3 for good quality with sound; MiniMax-H3 for the highest quality but silent and 25+ minutes a clip. For quick idea tests, add a Text to Video node with FastMetal 5B (about 1½ min).
        Missing a model? Install it from Models → Start Here.
        """
        var nodes = [note], edges: [StudioEdge] = []
        func edge(_ source: StudioNode, _ sourcePort: String, _ target: StudioNode, _ targetPort: String, _ type: PortDataType) -> StudioEdge {
            .init(sourceID: source.id, sourcePortID: sourcePort, targetID: target.id, targetPortID: targetPort, type: type)
        }
        var assemble = StudioNode(kind: .assembleVideo, label: "Ad · Assemble", position: .init(x: 1300, y: 700))
        // Delivery size, so the 1080×1920 End Card is never shrunk to the clips' size and enlarged again.
        assemble.assembly = .init(width: 1080, height: 1920, fps: clipSettings.fps, audio: .preserve)
        assemble.assembly.transition = .dissolve; assemble.assembly.transitionSeconds = 0.4; assemble.assembly.fadeOut = true
        var clips: [StudioNode] = []
        var lastStill: StudioNode?
        for (index, shot) in shots.enumerated() {
            let row = 330.0 + Double(index) * 420
            let number = index + 1
            let stillPrompt = StudioNode(kind: .prompt, label: "Shot \(number) · Still prompt", position: .init(x: 40, y: row), prompt: shot.still)
            var motionPrompt = StudioNode(kind: .videoPrompt, label: "Shot \(number) · Motion", position: .init(x: 40, y: row + 200))
            motionPrompt.videoPromptSettings = shot.motion
            var still = StudioNode(kind: .imageGenerator, label: "Shot \(number) · Still", position: .init(x: 450, y: row), model: imageModel)
            still.width = 576; still.height = 1024
            var clip = StudioNode(kind: .imageToVideo, label: "Shot \(number) · Clip", position: .init(x: 880, y: row + 60), model: videoModel)
            clip.video = clipSettings
            nodes += [stillPrompt, motionPrompt, still, clip]
            edges += [edge(stillPrompt, "text", still, "prompt", .text), edge(still, "image", clip, "startImage", .image), edge(motionPrompt, "prompt", clip, "prompt", .text)]
            clips.append(clip)
            lastStill = still
        }
        var card = StudioNode(kind: .endCard, label: "End Card", position: .init(x: 880, y: 330 + Double(shots.count) * 420))
        var cardSettings = EndCardSettings()
        cardSettings.headline = "Your business name"; cardSettings.offer = "Your offer, e.g. Logos from R1 500"
        cardSettings.contact = "WhatsApp 0XX XXX XXXX"; cardSettings.website = "yourbusiness.co.za"
        brandKit.fill(&cardSettings)
        cardSettings.width = 1080; cardSettings.height = 1920; cardSettings.fps = clipSettings.fps
        card.endCardSettings = cardSettings
        if let lastStill { edges.append(edge(lastStill, "image", card, "background", .image)) }
        if let logo = brandKit.logoURL(root: persistence.root) {
            let logoInput = StudioNode(kind: .imageInput, label: "Brand logo", position: .init(x: 450, y: 330 + Double(shots.count) * 420), imagePath: logo.path)
            nodes.append(logoInput)
            edges.append(edge(logoInput, "image", card, "logo", .image))
        }
        nodes.append(card)
        let parts = clips + [card]
        assemble.dynamicInputs = parts.indices.map { DynamicInputPort(label: "Clip \($0 + 1)", type: .video) }
        for (part, port) in zip(parts, assemble.dynamicInputs) { edges.append(edge(part, "video", assemble, port.id, .video)) }
        let export = StudioNode(kind: .instagramExport, label: "Ad · 9:16 Export", position: .init(x: 1700, y: 700))
        nodes += [assemble, export]
        // A spoken line over the ad, when a voice model is installed: the Brand Kit's name, offer and contact.
        if let voiceModel = generationModels(.speech).first {
            var voice = StudioNode(kind: .voiceover, label: "Ad · Voiceover", position: .init(x: 1500, y: 900), model: voiceModel.id)
            let starter = VoiceoverSettings.starterScript(brandKit)
            voice.voiceoverSettings?.script = starter.isEmpty ? "Your business name. Your offer. WhatsApp 0XX XXX XXXX." : starter
            voice.voiceoverSettings?.startSeconds = 0.5
            nodes.append(voice)
            edges += [edge(assemble, "video", voice, "video", .video), edge(voice, "video", export, "video", .video)]
        } else {
            edges.append(edge(assemble, "video", export, "video", .video))
        }
        let project = WorkflowProject(name: "Local Video Ad · 9:16", nodes: nodes, edges: edges)
        projects.insert(project, at: 0)
        currentProjectID = project.id
        undoStacks[project.id] = []
        redoStacks[project.id] = []
        selectedNodeID = export.id
        scheduleSave(project)
    }

    func renameProject(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StudioError.validation("Workflow name cannot be empty.") }
        guard !deletingProjectIDs.contains(id), var project = projects.first(where: { $0.id == id }) else { return }
        project.name = trimmed; project.updatedAt = Date()
        undoStacks[id] = undoStacks[id]?.map { var snapshot = $0; snapshot.name = trimmed; return snapshot }
        redoStacks[id] = redoStacks[id]?.map { var snapshot = $0; snapshot.name = trimmed; return snapshot }
        replace(project)
    }

    func duplicateProject(_ id: UUID) {
        guard !deletingProjectIDs.contains(id), let source = projects.first(where: { $0.id == id }) else { return }
        let copy = freshIdentityCopy(of: source, name: uniqueProjectName(source.name + " Copy"))
        projects.insert(copy, at: 0); selectProject(copy.id); scheduleSave(copy)
    }

    func uniqueProjectName(_ base: String) -> String {
        let names = Set(projects.map { $0.name.lowercased() })
        var name = base; var ordinal = 2
        while names.contains(name.lowercased()) { name = "\(base) \(ordinal)"; ordinal += 1 }
        return name
    }

    /// A copy that shares no project, node, socket or connection identity with its source.
    private func freshIdentityCopy(of source: WorkflowProject, name: String) -> WorkflowProject {
        var copy = source
        copy.id = UUID(); copy.createdAt = Date(); copy.updatedAt = copy.createdAt
        copy.name = name
        // A copy has no folder of its own, and its nodes are drafts again rather than claiming the original's saved files.
        copy.homeFolder = nil
        let ids = Dictionary(uniqueKeysWithValues: source.nodes.map { ($0.id, UUID()) })
        var ports: [UUID: [String: String]] = [:]
        copy.nodes = source.nodes.map { original in
            var node = original; node.id = ids[original.id]!
            node.finalized = nil
            node.dynamicInputs = original.dynamicInputs.map { originalPort in
                var port = originalPort; port.id = "input-\(UUID().uuidString.lowercased())"
                ports[original.id, default: [:]][originalPort.id] = port.id
                return port
            }
            return node
        }
        copy.edges = source.edges.map { original in
            var edge = original; edge.id = UUID()
            edge.sourceID = ids[original.sourceID]!; edge.targetID = ids[original.targetID]!
            edge.targetPortID = ports[original.targetID]?[original.targetPortID] ?? original.targetPortID
            return edge
        }
        return copy
    }

    // MARK: Flow files

    /// Builds nodes the way a hand-added node is built, so imported model and video defaults match the app's own.
    private var flowCompiler: FlowRecipeCompiler {
        FlowRecipeCompiler(makeNode: { [self] kind in configuredNode(kind, at: .init(x: 0, y: 0)) })
    }

    func importFlowFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GenStudio flow (.genflow.json) or a workflow backup (.genstudio.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importFlow(text: try String(contentsOf: url, encoding: .utf8)) }
        catch { alertMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    func importFlowFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            alertMessage = "The clipboard has no text. Copy the AI's JSON reply first, then choose Paste Flow."
            return
        }
        importFlow(text: text)
    }

    /// Always adds a new workflow; nothing existing is overwritten.
    func importFlow(text: String) {
        switch FlowDocumentParser.parse(text) {
        case .failure(let failure):
            reportFlowFailure(failure.message)
        case .success(.fullProject(let backup)):
            adoptImportedProject(freshIdentityCopy(of: backup, name: uniqueProjectName(backup.name)))
        case .success(.recipe(let recipe)):
            let result = flowCompiler.compile(recipe)
            guard var project = result.project else { reportFlowFailure(result.report(for: recipe.name)); return }
            project.name = uniqueProjectName(project.name)
            adoptImportedProject(project)
            if !result.warnings.isEmpty { alertMessage = "Imported “\(project.name)”.\n\n" + result.report() }
        }
    }

    func adoptImportedProject(_ project: WorkflowProject) {
        projects.insert(project, at: 0)
        currentProjectID = project.id
        undoStacks[project.id] = []
        redoStacks[project.id] = []
        selectedNodeID = nil
        scheduleSave(project)
    }

    /// The report is written to be pasted back to the AI, so it goes on the clipboard as well as on screen.
    private func reportFlowFailure(_ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        alertMessage = message + "\n\nThis report is on your clipboard. Paste it back to your AI and ask for the complete corrected JSON."
    }

    func exportFlow(_ id: UUID? = nil) {
        guard let project = projects.first(where: { $0.id == id ?? currentProjectID }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(project.name).genflow.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try FlowRecipeExporter.data(FlowRecipeExporter.recipe(from: project, makeNode: flowCompiler.makeNode)).write(to: url, options: .atomic) }
        catch { alertMessage = error.localizedDescription }
    }

    func copyAIBriefing() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(FlowBriefing.markdown(), forType: .string)
        alertMessage = "The AI briefing is on your clipboard. Paste it at the start of a chat with your AI, then describe the workflow you want."
    }

    func saveAIBriefing() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = FlowBriefing.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try FlowBriefing.markdown().write(to: url, atomically: true, encoding: .utf8) }
        catch { alertMessage = error.localizedDescription }
    }

    func deleteProject(_ id: UUID) async {
        guard !isRunning, !deletingProjectIDs.contains(id), projects.contains(where: { $0.id == id }) else { return }
        deletingProjectIDs.insert(id)
        let previous = saveTask
        let deletion = Task {
            await previous?.value
            do {
                try await persistence.deleteProject(id)
                if let index = projects.firstIndex(where: { $0.id == id }) {
                    projects.remove(at: index)
                    if currentProjectID == id {
                        currentProjectID = projects.isEmpty ? nil : projects[min(index, projects.count - 1)].id
                        selectedNodeID = nil; runtimeValues = [:]
                    }
                }
                undoStacks[id] = nil; redoStacks[id] = nil
            } catch { alertMessage = error.localizedDescription }
            deletingProjectIDs.remove(id)
        }
        saveTask = deletion
        await deletion.value
    }

    func flushProjectWrites() async { await saveTask?.value }

    func deleteOutput(_ output: TextOutput) async {
        await deleteGalleryItems(outputIDs: [output.id], artifactIDs: [])
    }

    func renameGalleryMedia(_ item: GalleryMediaItem, to name: String) async {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Renaming a locked node's image renames the node and its file, so there is one name everywhere.
        if let owner = projects.first(where: { project in project.nodes.contains { $0.id == item.address.nodeID && $0.isLockedFinal } }) {
            renameNode(item.address.nodeID, to: cleaned, inProject: owner.id)
            return
        }
        guard !cleaned.isEmpty, var artifact = executionArtifacts.first(where: { $0.id == item.artifactID }) else { return }
        var names = artifact.mediaNames ?? [:]
        names[Self.galleryMediaKey(item.address)] = cleaned
        artifact.mediaNames = names
        do {
            try await persistence.saveExecutionArtifact(artifact)
            executionArtifacts = try await persistence.loadExecutionArtifacts()
        } catch { alertMessage = error.localizedDescription }
    }

    func exportGalleryMedia(_ items: [GalleryMediaItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            for item in items {
                let source: URL? = switch item.value {
                case .image(let url), .video(let url): url
                default: nil
                }
                guard let source else { continue }
                try MediaExport.copy(source: source, destination: folder.appending(path: Self.exportName(for: item, source: source)))
            }
        } catch { alertMessage = "Could not export selected media: \(error.localizedDescription)" }
    }

    private static func exportName(for item: GalleryMediaItem, source: URL) -> String {
        let base = item.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
        return base + ext
    }

    func retryRuns(_ ids: Set<UUID>) {
        let failures = runs.filter { ids.contains($0.id) && ($0.status == .failed || $0.status == .interrupted) }
        guard !failures.isEmpty else { return }
        for run in failures {
            guard let project = projects.first(where: { $0.id == run.snapshot.projectID }),
                  project.nodes.contains(where: { $0.id == run.snapshot.nodeID }) else { continue }
            let request = PendingRun(project: project, targetID: run.snapshot.nodeID, plan: RunPlan.make(project: project, target: run.snapshot.nodeID))
            do { try preflight(request); enqueue(request) }
            catch { alertMessage = error.localizedDescription }
        }
        if let first = failures.first, let project = projects.first(where: { $0.id == first.snapshot.projectID }) {
            selectProject(project.id); selectedNodeID = first.snapshot.nodeID
        }
    }

    func openRun(_ run: RunRecord) {
        guard let project = projects.first(where: { $0.id == run.snapshot.projectID }) else { return }
        selectProject(project.id)
        selectedNodeID = run.snapshot.nodeID
        sidebarSection = .projects
    }

    func deleteExecutionArtifact(_ artifact: ExecutionArtifact) async {
        await deleteGalleryItems(outputIDs: [], artifactIDs: [artifact.id])
    }

    /// Removes one visible generation take and moves selection to the nearest
    /// surviving take when the deleted take was selected.
    func deleteTake(_ artifact: ExecutionArtifact, for node: StudioNode) async {
        guard !isRunning,
              let currentNode = currentProject?.nodes.first(where: { $0.id == node.id }) else { return }
        let history = takes(for: currentNode)
        guard let index = history.firstIndex(where: { $0.id == artifact.id }) else { return }
        let replacement = history.enumerated()
            .filter { $0.offset != index }
            .first { $0.offset >= index }?.element ?? history.dropLast().last
        if selectedTake(for: currentNode)?.id == artifact.id {
            updateNode(currentNode.id) { $0.selectedTakeID = replacement?.id }
        }
        await deleteGalleryItems(outputIDs: [], artifactIDs: [artifact.id])
    }

    /// Removes every take before the currently selected take, which is useful
    /// after iterating through several generations to find a final result.
    func deleteEarlierTakes(for node: StudioNode) async {
        guard !isRunning,
              let currentNode = currentProject?.nodes.first(where: { $0.id == node.id }) else { return }
        let history = takes(for: currentNode)
        guard let selected = selectedTake(for: currentNode),
              let index = history.firstIndex(where: { $0.id == selected.id }), index > 0 else { return }
        await deleteGalleryItems(outputIDs: [], artifactIDs: Set(history.prefix(index).map(\.id)))
    }

    /// Removes every take this node has produced, leaving it empty like a new node.
    func clearTakes(for node: StudioNode) async {
        guard !isRunning,
              let currentNode = currentProject?.nodes.first(where: { $0.id == node.id }) else { return }
        let history = takes(for: currentNode)
        guard !history.isEmpty else { return }
        updateNode(currentNode.id) { $0.selectedTakeID = nil }
        await deleteGalleryItems(outputIDs: [], artifactIDs: Set(history.map(\.id)))
    }

    func deleteGalleryItems(outputIDs requestedOutputIDs: Set<UUID>, artifactIDs requestedArtifactIDs: Set<UUID>) async {
        let outputIDs = requestedOutputIDs.intersection(outputs.map(\.id))
        let artifactIDs = requestedArtifactIDs.intersection(executionArtifacts.map(\.id))
        let deletingIDs = outputIDs.union(artifactIDs)
        guard !deletingIDs.isEmpty, deletingIDs.isDisjoint(with: deletingGalleryItemIDs) else { return }
        deletingGalleryItemIDs.formUnion(deletingIDs)
        defer { deletingGalleryItemIDs.subtract(deletingIDs) }

        let artifacts = executionArtifacts.filter { artifactIDs.contains($0.id) }
        // Build the post-deletion runtime snapshot without publishing while the
        // gallery confirmation view is still being reconciled. Publishing a
        // dictionary mutation here can trigger SwiftUI's "Publishing changes
        // from within view updates" warning because this async action may start
        // in the same update transaction as the confirmation dismissal.
        let deletedRuntimeAddresses = Set(artifacts.flatMap { artifact in
            artifact.values.compactMap { address, value in
                runtimeValues[address] == value ? address : nil
            }
        })
        let preservedRuntimeValues = runtimeValues.filter { !deletedRuntimeAddresses.contains($0.key) }
        do {
            try await persistence.deleteGalleryItems(outputIDs: outputIDs, artifacts: artifacts, preserving: Array(preservedRuntimeValues.values))
            runtimeValues = preservedRuntimeValues
            outputs.removeAll { outputIDs.contains($0.id) }
            executionArtifacts.removeAll { artifactIDs.contains($0.id) }
        } catch {
            outputs = (try? await persistence.loadOutputs()) ?? outputs
            executionArtifacts = (try? await persistence.loadExecutionArtifacts()) ?? executionArtifacts
            alertMessage = error.localizedDescription
        }
    }

    func deleteHistoryItems(_ requestedIDs: Set<UUID>) async {
        let ids = requestedIDs.intersection(runs.map(\.id))
        guard !isRunning, !ids.isEmpty, ids.isDisjoint(with: deletingRunIDs) else { return }
        deletingRunIDs.formUnion(ids)
        defer { deletingRunIDs.subtract(ids) }
        do {
            try await persistence.deleteRuns(ids)
            runs.removeAll { ids.contains($0.id) }
        } catch {
            runs = (try? await persistence.loadRuns(recoverInterrupted: false)) ?? runs
            alertMessage = error.localizedDescription
        }
    }

    func selectProject(_ id: UUID) {
        currentProjectID = id
        selectedNodeID = nil
        sidebarSection = .projects
    }

    /// Points an Image Input node at a file the user picked or dropped.
    func setInputImage(_ url: URL, for nodeID: UUID) {
        mutateProject { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            project.nodes[index].imagePath = url.path
            VideoDimensionSync.resyncTargets(of: nodeID, in: &project)
        }
    }

    /// Points a Video Input node at a file the user picked or dropped.
    func setInputVideo(_ url: URL, for nodeID: UUID) {
        mutateProject { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            project.nodes[index].videoPath = url.path
        }
    }

    /// Turns files dragged in from Finder into Image/Video Input nodes, stacked
    /// downward from the drop point in the order Finder supplied them. One undo
    /// step covers the whole drop; unsupported files are skipped.
    @discardableResult
    func importDroppedMedia(_ urls: [URL], at position: CanvasPoint) -> [UUID] {
        let media = urls.compactMap { url in DroppedMedia.nodeKind(for: url).map { (url, $0) } }
        guard !media.isEmpty else {
            alertMessage = "GenStudio can import images and videos. Drop image files (PNG, JPEG, HEIC…) or movie files (MOV, MP4…) onto the canvas."
            return []
        }
        var ids: [UUID] = []
        editGraph { project in
            var y = position.y
            for (url, kind) in media {
                var node = configuredNode(kind, at: CanvasPoint(x: position.x, y: y))
                node.label = url.deletingPathExtension().lastPathComponent
                if kind == .videoInput { node.videoPath = url.path } else { node.imagePath = url.path }
                project.nodes.append(node)
                ids.append(node.id)
                y += NodeLayout.cardHeight(node) + 32
            }
        }
        selectedNodeID = ids.last
        return ids
    }

    func mutateProject(_ mutation: (inout WorkflowProject) -> Void) {
        guard var project = currentProject, !deletingProjectIDs.contains(project.id) else { return }
        let before = project
        mutation(&project)
        // SwiftUI controls may write their current value back while reconciling a
        // view. Treat that as a no-op so it cannot publish during the update pass.
        guard project != before else { return }
        project.updatedAt = Date()
        replace(project)
    }

    /// Apply binding edits immediately so a second control reading the same
    /// value cannot observe stale state and overwrite the first edit.
    func mutateProjectFromBinding(_ mutation: @escaping (inout WorkflowProject) -> Void) {
        mutateProject(mutation)
    }

    func replace(_ project: WorkflowProject) {
        guard !deletingProjectIDs.contains(project.id), let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        // A finalized node's file is named after its heading, so a renamed heading (or an undone rename) renames the file.
        let reconciled = reconcileFinalFiles(from: projects[index], to: project)
        projects[index] = reconciled
        scheduleSave(reconciled)
    }

    func scheduleSave(_ project: WorkflowProject) {
        guard !deletingProjectIDs.contains(project.id) else { return }
        let previous = saveTask
        let models = project.homeFolder == nil ? [] : packageModelUsages(for: project)
        saveTask = Task {
            await previous?.value
            do {
                try await persistence.saveProject(project)
            } catch { alertMessage = error.localizedDescription }
            // A project with a folder also keeps its .genstudio file there; the library copy above stays as the fallback.
            guard project.homeFolder != nil else { return }
            do {
                try await persistence.mirror(project, models: models)
                mirrorWarnings.remove(project.id)
            } catch {
                if mirrorWarnings.insert(project.id).inserted { alertMessage = error.localizedDescription }
            }
        }
    }

    func saveNow() {
        guard let project = currentProject else { return }
        scheduleSave(project)
    }

    /// Picks a useful recipe when a generation node is created. A completed
    /// task proof wins, then an installed adapter, then the first documented
    /// adapter for that task so the inspector is never left with a blank model
    /// when the app already knows a route for the node.
    private func configureVideoNode(_ node: inout StudioNode, task: VideoTask) {
        let capabilities = VideoCapabilityRegistry.selectableCapabilities(for: task)
        let installedIDs = Set(libraryStore.installed.filter(\.available).map(\.id))
        let verifiedID = capabilities
            .filter { capability in
                libraryStore.installed.first { $0.id == capability.recipeID && $0.available }?.hasVerifiedVideoTask(task) == true
            }
            .min { VideoCapabilityRegistry.recommendationPriority($0) < VideoCapabilityRegistry.recommendationPriority($1) }?.recipeID
        let installedID = capabilities
            .filter { installedIDs.contains($0.recipeID) }
            .min { VideoCapabilityRegistry.recommendationPriority($0) < VideoCapabilityRegistry.recommendationPriority($1) }?.recipeID
        let preferredID = defaultModel(for: node.kind).flatMap { preferred in
            capabilities.contains { $0.recipeID == preferred } && installedIDs.contains(preferred) ? preferred : nil
        }
        let recipeID = preferredID ?? verifiedID ?? installedID ?? capabilities.first?.recipeID ?? ""
        node.model = recipeID
        if let capability = capabilities.first(where: { $0.recipeID == recipeID }) {
            node.video = capability.recommended
        }
    }

    /// Picks a useful upscaler recipe when an Image Upscale node is created: a locally verified install
    /// wins, then any installed recipe, then the first documented recipe, mirroring configureVideoNode.
    private func configureUpscaleNode(_ node: inout StudioNode) {
        let recipes = UpscaleCapabilityRegistry.shipped
        let installed = libraryStore.installed.filter { $0.kind == .upscaler && $0.available }
        let installedIDs = Set(installed.map(\.id))
        let preferredID = defaultModel(for: node.kind).flatMap { preferredID in
            installedIDs.contains(preferredID) && recipes.contains(where: { $0.recipeID == preferredID }) ? preferredID : nil
        }
        let verifiedID = recipes.first { capability in installed.first { $0.id == capability.recipeID }?.hasVerifiedUpscale == true }?.recipeID
        let installedID = recipes.first { capability in installed.contains { $0.id == capability.recipeID } }?.recipeID
        node.model = preferredID ?? verifiedID ?? installedID ?? recipes.first?.recipeID ?? ""
        if node.kind == .videoUpscale { node.upscaleScale = 2 }
    }

    func configuredNode(_ kind: NodeKind, at position: CanvasPoint) -> StudioNode {
        var node = StudioNode(kind: kind, label: kind.title, position: position)
        if kind == .textModel { node.model = defaultModel(for: kind).flatMap { preferred in generationModels(.text).contains { $0.id == preferred } ? preferred : nil } ?? generationModels(.text).first?.id ?? "" }
        if kind == .imageGenerator {
            let textToImageChoices = ImageCapabilityRegistry.selectableCapabilities(task: .textToImage, referenceCount: 0, installed: libraryStore.installed)
            node.model = defaultModel(for: kind).flatMap { preferred in
                textToImageChoices.contains { $0.recipeID == preferred } ? preferred : nil
            } ?? generationModels(.image).first?.id ?? ""
        }
        if kind == .imageUpscale || kind == .videoUpscale { configureUpscaleNode(&node) }
        if kind == .promptEnhancer {
            // Prefer a model that also sees pictures, so the enhancer can look at the image its destination animates.
            let text = generationModels(.text), seeing = Set(generationModels(.vision).map(\.id))
            node.model = defaultModel(for: kind).flatMap { preferred in text.contains { $0.id == preferred } ? preferred : nil }
                ?? text.first { seeing.contains($0.id) }?.id ?? text.first?.id ?? ""
        }
        if kind == .imageDescriber { node.model = defaultModel(for: kind).flatMap { preferred in generationModels(.vision).contains { $0.id == preferred } ? preferred : nil } ?? generationModels(.vision).first?.id ?? "" }
        if kind == .textToVideo { configureVideoNode(&node, task: .textToVideo) }
        if kind == .imageToVideo { configureVideoNode(&node, task: .imageToVideo) }
        if kind == .startEndVideo { configureVideoNode(&node, task: .firstLastFrame) }
        if kind == .videoToVideo { configureVideoNode(&node, task: .videoToVideo) }
        if kind == .endCard, var card = node.endCardSettings { brandKit.fill(&card); node.endCardSettings = card }
        if kind == .textOverlay, var caption = node.textOverlaySettings { brandKit.fill(&caption); node.textOverlaySettings = caption }
        if kind == .voiceover {
            node.model = generationModels(.speech).first?.id ?? ""
            node.voiceoverSettings?.script = VoiceoverSettings.starterScript(brandKit)
        }
        return node
    }

    /// Picks a music file for an Assemble node. The file is copied into the run's record each time it renders.
    func chooseAssemblyMusic(nodeID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a music track to play under the whole video."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateNode(nodeID) { $0.assembly.musicPath = url.path }
    }

    func saveBrandKit() {
        do { try brandKit.save(root: persistence.root) }
        catch { alertMessage = "Could not save the Brand Kit: \(error.localizedDescription)" }
    }

    /// Picks a logo for the Brand Kit; the file is copied into the app's own folder.
    func chooseBrandLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.message = "Choose your logo. A PNG with a transparent background looks best on the End Card."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try brandKit.adoptLogo(from: url, root: persistence.root); saveBrandKit() }
        catch { alertMessage = "Could not use that logo: \(error.localizedDescription)" }
    }

    func addNode(_ kind: NodeKind, at position: CanvasPoint? = nil) {
        editGraph { project in
            let count = project.nodes.filter { $0.kind == kind }.count + 1
            let node = configuredNode(kind, at: position ?? CanvasPoint(x: 100 + Double(count * 28), y: 100 + Double(count * 24)))
            project.nodes.append(node)
            selectedNodeID = node.id
        }
    }

    /// Adds a node beside a selected node and creates the first compatible
    /// typed connection. Returns nil when the kinds have no compatible ports;
    /// callers can then fall back to ordinary free placement.
    @discardableResult
    func addNodeConnectedToSelection(_ kind: NodeKind, selectedNodeID: UUID, gap: Double = 96) -> UUID? {
        guard let project = currentProject,
              let selected = project.nodes.first(where: { $0.id == selectedNodeID }) else { return nil }
        let selectedInputs = Set(project.edges.filter { $0.targetID == selected.id }.map(\.targetPortID))
        var node = configuredNode(kind, at: selected.position)
        guard let plan = CanvasInteraction.automaticConnection(newNode: node, selectedNode: selected, selectedInputPortIDs: selectedInputs) else { return nil }
        node.position.x = plan.side == .left
            ? selected.position.x - NodeLayout.cardWidth(node) - gap
            : selected.position.x + NodeLayout.cardWidth(selected) + gap
        var candidate = project
        candidate.nodes.append(node)
        let sourceID = plan.side == .left ? node.id : selected.id
        let targetID = plan.side == .left ? selected.id : node.id
        guard appendAutomaticConnection(sourceID: sourceID, sourcePortID: plan.sourcePortID, targetID: targetID, preferredTargetPortID: plan.targetPortID, in: &candidate) else { return nil }
        do {
            _ = try GraphValidator().validateStructure(candidate)
            editGraph { $0 = candidate }
            self.selectedNodeID = node.id
            return node.id
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    /// Appends a connection while creating the next repeatable input when a
    /// selected dynamic socket is already occupied.
    private func appendAutomaticConnection(sourceID: UUID, sourcePortID: String, targetID: UUID, preferredTargetPortID: String, in candidate: inout WorkflowProject) -> Bool {
        guard let source = candidate.nodes.first(where: { $0.id == sourceID }),
              let output = source.outputPorts.first(where: { $0.id == sourcePortID }),
              let targetIndex = candidate.nodes.firstIndex(where: { $0.id == targetID }) else { return false }
        let occupied = Set(candidate.edges.filter { $0.targetID == targetID }.map(\.targetPortID))
        var input = candidate.nodes[targetIndex].inputPorts.first { port in
            port.type == output.type && port.id == preferredTargetPortID && !occupied.contains(port.id)
        }
        if input == nil {
            input = candidate.nodes[targetIndex].inputPorts.first { $0.type == output.type && !occupied.contains($0.id) }
        }
        if input == nil, candidate.nodes[targetIndex].kind.supportsDynamicTextInputs, output.type == .text {
            let prefix = candidate.nodes[targetIndex].kind == .promptTemplate ? "Variable" : "Part"
            let used = Set(candidate.nodes[targetIndex].dynamicInputs.map(\.label)); var ordinal = 1
            while used.contains("\(prefix) \(ordinal)") { ordinal += 1 }
            candidate.nodes[targetIndex].dynamicInputs.append(.init(label: "\(prefix) \(ordinal)"))
            input = candidate.nodes[targetIndex].inputPorts.last
        }
        if input == nil, candidate.nodes[targetIndex].kind.supportsDynamicImageInputs, output.type == .image {
            let used = Set(candidate.nodes[targetIndex].dynamicInputs.map(\.label)); var ordinal = 1
            let prefix = candidate.nodes[targetIndex].kind == .imageGenerator ? "Reference" : "Image"
            while used.contains("\(prefix) \(ordinal)") { ordinal += 1 }
            candidate.nodes[targetIndex].dynamicInputs.append(.init(label: "\(prefix) \(ordinal)", type: .image))
            input = candidate.nodes[targetIndex].inputPorts.last
        }
        if input == nil, candidate.nodes[targetIndex].kind == .shotSequence, output.type == .image {
            let anchor = ShotAnchor(label: SequenceEditing.nextLabel(candidate.nodes[targetIndex].sequence.anchors))
            candidate.nodes[targetIndex].sequence.anchors.append(anchor)
            input = candidate.nodes[targetIndex].inputPorts.last
        }
        if input == nil, candidate.nodes[targetIndex].kind.supportsDynamicVideoInputs, output.type == .video {
            candidate.nodes[targetIndex].dynamicInputs.append(.init(label: SequenceEditing.nextClipLabel(candidate.nodes[targetIndex].dynamicInputs), type: .video))
            input = candidate.nodes[targetIndex].inputPorts.last
        }
        guard let input else { return false }
        candidate.edges.append(.init(sourceID: sourceID, sourcePortID: output.id, targetID: targetID, targetPortID: input.id, type: output.type))
        VideoDimensionSync.resyncNode(targetID, in: &candidate)
        return true
    }

    /// Duplicates one node as a reusable configured starting point. External
    /// connections stay on the source so required inputs are never ambiguous.
    func duplicateNode(_ nodeID: UUID) {
        _ = duplicateNodes([nodeID])
    }

    @discardableResult
    func duplicateNodes(_ nodeIDs: Set<UUID>) -> Set<UUID> {
        Set(duplicateNodes(nodeIDs, offset: .init(x: 40, y: 40)).values)
    }

    /// Creates copies at their source positions so a pointer gesture can take
    /// over immediately, matching the standard Option-drag canvas behavior.
    func duplicateNodesForDrag(_ nodeIDs: Set<UUID>) -> [UUID: UUID] {
        duplicateNodes(nodeIDs, offset: .init(x: 0, y: 0))
    }

    @discardableResult
    private func duplicateNodes(_ nodeIDs: Set<UUID>, offset: CanvasPoint) -> [UUID: UUID] {
        guard let project = currentProject,
              !nodeIDs.isEmpty else { return [:] }
        let sources = project.nodes.filter { nodeIDs.contains($0.id) }
        guard !sources.isEmpty else { return [:] }
        var ids: [UUID: UUID] = [:]
        var copies: [StudioNode] = []
        var usedLabels = project.nodes.map(\.label)
        for source in sources {
            let newID = UUID()
            ids[source.id] = newID
            var copy = source
            copy.id = newID
            copy.position = .init(x: source.position.x + offset.x, y: source.position.y + offset.y)
            copy.label = duplicateLabel(for: source.label, in: usedLabels)
            copy.selectedTakeID = nil
            copy.finalized = nil
            usedLabels.append(copy.label)
            copies.append(copy)
        }
        let internalEdges = project.edges.compactMap { edge -> StudioEdge? in
            guard let sourceID = ids[edge.sourceID], let targetID = ids[edge.targetID] else { return nil }
            var copy = edge
            copy.id = UUID()
            copy.sourceID = sourceID
            copy.targetID = targetID
            return copy
        }
        let cloned = cloneGenerations(generations(for: nodeIDs), idMap: ids, into: project)
        for index in copies.indices { copies[index].selectedTakeID = cloned.selectedTakeIDs[copies[index].id] }
        executionArtifacts.append(contentsOf: cloned.artifacts)
        persistArtifacts(cloned.artifacts)
        editGraph {
            $0.nodes.append(contentsOf: copies)
            $0.edges.append(contentsOf: internalEdges)
        }
        selectedNodeID = copies.first?.id
        return ids
    }

    private func duplicateLabel(for label: String, in labels: [String]) -> String {
        let existing = Set(labels)
        let base = label.hasSuffix(" Copy") ? label : "\(label) Copy"
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func isAutoGeneratedLabel(_ node: StudioNode) -> Bool {
        let prefix = "\(node.kind.title) "
        guard node.label.hasPrefix(prefix) else { return false }
        return Int(node.label.dropFirst(prefix.count)) != nil
    }

    func deleteSelected() {
        guard let id = selectedNodeID else { return }
        deleteNodes([id])
    }

    func deleteNodes(_ nodeIDs: Set<UUID>) {
        guard !nodeIDs.isEmpty, currentProject?.nodes.contains(where: { nodeIDs.contains($0.id) }) == true else { return }
        editGraph {
            $0.nodes.removeAll { nodeIDs.contains($0.id) }
            $0.edges.removeAll { nodeIDs.contains($0.sourceID) || nodeIDs.contains($0.targetID) }
        }
        selectedNodeID = nil
    }

    func renameNode(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == id }) else { return }
            project.nodes[index].label = trimmed
        }
    }

    func connect(sourceID: UUID, targetID: UUID) {
        guard let project = currentProject,
              let source = project.nodes.first(where: { $0.id == sourceID }),
              let target = project.nodes.first(where: { $0.id == targetID }),
              let output = source.outputPorts.first,
              let input = target.inputPorts.first(where: { $0.type == output.type }) else {
            alertMessage = "Those node ports are not compatible."
            return
        }
        connect(sourceID: sourceID, sourcePortID: output.id, targetID: targetID, targetPortID: input.id, replacing: true)
    }

    func connect(sourceID: UUID, sourcePortID: String, targetID: UUID, targetPortID: String, replacing: Bool = false) {
        guard let project = currentProject,
              let source = project.nodes.first(where: { $0.id == sourceID }),
              let output = source.outputPorts.first(where: { $0.id == sourcePortID }),
              let target = project.nodes.first(where: { $0.id == targetID }),
              target.inputPorts.contains(where: { $0.id == targetPortID && $0.type == output.type }) else { alertMessage = "Those node ports are not compatible."; return }
        var candidate = project
        if replacing { candidate.edges.removeAll { $0.targetID == targetID && ($0.targetPortID == targetPortID || ($0.targetPortID.isEmpty && $0.type == output.type)) } }
        candidate.edges.append(.init(sourceID: sourceID, sourcePortID: sourcePortID, targetID: targetID, targetPortID: targetPortID, type: output.type))
        VideoDimensionSync.resyncNode(targetID, in: &candidate)
        do {
            _ = try GraphValidator().validateStructure(candidate)
            editGraph { $0 = candidate }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func disconnect(edgeID: UUID) { editGraph { $0.edges.removeAll { $0.id == edgeID } } }

    /// A node can have an input and an output that share the same port ID (e.g. Text Preview's "text" in and
    /// out), so `direction` — not just `PortAddress` — is what disambiguates which one is meant.
    func hasConnections(at address: PortAddress, direction: PortDirection) -> Bool {
        guard let project = currentProject else { return false }
        switch direction {
        case .output: return project.edges.contains { $0.sourceID == address.nodeID && $0.sourcePortID == address.portID }
        case .input: return project.edges.contains { $0.targetID == address.nodeID && $0.targetPortID == address.portID }
        }
    }

    /// The paste menu item's enablement: same direction and type as what's on the clipboard, and not the port it was copied from.
    func canPasteConnections(onto address: PortAddress, portType: PortDataType, direction: PortDirection) -> Bool {
        guard let copied = copiedPortConnections, copied.direction == direction, copied.portDataType == portType else { return false }
        return copied.sourcePortAddress != address
    }

    /// Snapshots the wiring at exactly this port: an output's full fan-out, or an input's single source edge.
    func copyConnections(from address: PortAddress, direction: PortDirection) {
        guard let project = currentProject, let node = project.nodes.first(where: { $0.id == address.nodeID }) else { return }
        switch direction {
        case .output:
            guard let output = node.outputPorts.first(where: { $0.id == address.portID }) else { return }
            let edges = project.edges.filter { $0.sourceID == address.nodeID && $0.sourcePortID == address.portID }
            guard !edges.isEmpty else { return }
            copiedPortConnections = CopiedPortConnections(sourcePortAddress: address, direction: .output, portDataType: output.type, edges: edges)
        case .input:
            guard let input = node.inputPorts.first(where: { $0.id == address.portID }) else { return }
            guard let edge = project.edges.first(where: { $0.targetID == address.nodeID && $0.targetPortID == address.portID }) else { return }
            copiedPortConnections = CopiedPortConnections(sourcePortAddress: address, direction: .input, portDataType: input.type, edges: [edge])
        }
    }

    /// Reapplies the copied wiring onto a different port of the same direction and type. An output paste adds
    /// alongside whatever that port already fans out to; an input paste replaces its single existing connection.
    func pasteConnections(onto address: PortAddress) {
        guard let copied = copiedPortConnections, let project = currentProject, let node = project.nodes.first(where: { $0.id == address.nodeID }) else { return }
        switch copied.direction {
        case .output:
            guard let output = node.outputPorts.first(where: { $0.id == address.portID }), output.type == copied.portDataType else {
                alertMessage = "That output isn't compatible with the copied connections."
                return
            }
            // Each copied edge is pasted with the same replace-on-conflict semantics as an ordinary drag-to-connect:
            // an input only ever has one source, so wiring this port to a target already fed by the copied-from
            // node hands that target over to this port rather than being rejected as "already connected."
            var pasted = 0, skipped = 0
            for edge in copied.edges {
                guard let target = currentProject?.nodes.first(where: { $0.id == edge.targetID }),
                      target.inputPorts.contains(where: { $0.id == edge.targetPortID && $0.type == output.type }) else { skipped += 1; continue }
                connect(sourceID: address.nodeID, sourcePortID: address.portID, targetID: edge.targetID, targetPortID: edge.targetPortID, replacing: true)
                let landed = currentProject?.edges.contains { $0.sourceID == address.nodeID && $0.sourcePortID == address.portID && $0.targetID == edge.targetID && $0.targetPortID == edge.targetPortID } == true
                if landed { pasted += 1 } else { skipped += 1 }
            }
            if skipped > 0 { alertMessage = "Pasted \(pasted) of \(copied.edges.count) connection\(copied.edges.count == 1 ? "" : "s") — \(skipped) skipped (incompatible or already connected)." }
        case .input:
            guard let input = node.inputPorts.first(where: { $0.id == address.portID }), input.type == copied.portDataType, let edge = copied.edges.first else {
                alertMessage = "That input isn't compatible with the copied connection."
                return
            }
            guard let source = project.nodes.first(where: { $0.id == edge.sourceID }), source.outputPorts.contains(where: { $0.id == edge.sourcePortID && $0.type == input.type }) else {
                alertMessage = "The copied connection's source is no longer available."
                return
            }
            connect(sourceID: edge.sourceID, sourcePortID: edge.sourcePortID, targetID: address.nodeID, targetPortID: address.portID, replacing: true)
        }
    }
    func setWireColor(edgeID: UUID, color: WireColor?) {
        editGraph { project in
            guard let index = project.edges.firstIndex(where: { $0.id == edgeID }) else { return }
            project.edges[index].color = color
        }
    }
    func connectToBody(sourceID: UUID, sourcePortID: String, targetID: UUID) {
        guard let project = currentProject, let source = project.nodes.first(where: { $0.id == sourceID }), let output = source.outputPorts.first(where: { $0.id == sourcePortID }), let targetIndex = project.nodes.firstIndex(where: { $0.id == targetID }) else { return }
        var candidate = project
        let occupied = Set(candidate.edges.filter { $0.targetID == targetID }.map(\.targetPortID))
        var input = candidate.nodes[targetIndex].inputPorts.first(where: { $0.type == output.type && !occupied.contains($0.id) })
        if input == nil, candidate.nodes[targetIndex].kind.supportsDynamicTextInputs, output.type == .text {
            let prefix = candidate.nodes[targetIndex].kind == .promptTemplate ? "Variable" : "Part"; let used = Set(candidate.nodes[targetIndex].dynamicInputs.map(\.label)); var ordinal = 1; while used.contains("\(prefix) \(ordinal)") { ordinal += 1 }
            let dynamic = DynamicInputPort(label: "\(prefix) \(ordinal)"); candidate.nodes[targetIndex].dynamicInputs.append(dynamic); input = candidate.nodes[targetIndex].inputPorts.first { $0.id == dynamic.id }
        }
        if input == nil, candidate.nodes[targetIndex].kind.supportsDynamicImageInputs, output.type == .image {
            let used = Set(candidate.nodes[targetIndex].dynamicInputs.map(\.label)); var ordinal = 1
            let prefix = candidate.nodes[targetIndex].kind == .imageGenerator ? "Reference" : "Image"
            while used.contains("\(prefix) \(ordinal)") { ordinal += 1 }
            let dynamic = DynamicInputPort(label: "\(prefix) \(ordinal)", type: .image)
            candidate.nodes[targetIndex].dynamicInputs.append(dynamic); input = candidate.nodes[targetIndex].inputPorts.first { $0.id == dynamic.id }
        }
        if input == nil, candidate.nodes[targetIndex].kind == .shotSequence, output.type == .image, candidate.nodes[targetIndex].sequence.anchors.count < ShotSequenceSpec.maximumAnchors {
            let anchor = ShotAnchor(label: SequenceEditing.nextLabel(candidate.nodes[targetIndex].sequence.anchors))
            candidate.nodes[targetIndex].sequence.anchors.append(anchor); input = candidate.nodes[targetIndex].inputPorts.first { $0.id == anchor.id }
        }
        if input == nil, candidate.nodes[targetIndex].kind.supportsDynamicVideoInputs, output.type == .video, candidate.nodes[targetIndex].dynamicInputs.count < AssemblySettings.maximumClips {
            let slot = DynamicInputPort(label: SequenceEditing.nextClipLabel(candidate.nodes[targetIndex].dynamicInputs), type: .video)
            candidate.nodes[targetIndex].dynamicInputs.append(slot); input = candidate.nodes[targetIndex].inputPorts.first { $0.id == slot.id }
        }
        guard let input else { alertMessage = "No free compatible input is available on \(candidate.nodes[targetIndex].label)."; return }
        candidate.edges.append(.init(sourceID: sourceID, sourcePortID: sourcePortID, targetID: targetID, targetPortID: input.id, type: output.type))
        VideoDimensionSync.resyncNode(targetID, in: &candidate)
        do { _ = try GraphValidator().validateStructure(candidate); editGraph { $0 = candidate } } catch { alertMessage = error.localizedDescription }
    }
    func addAndConnect(_ kind: NodeKind, at position: CanvasPoint, endpointNodeID: UUID, endpointPort: PortDescriptor) {
        guard let project = currentProject else { return }; var candidate = project
        var node = configuredNode(kind, at: position)
        if kind == .shotSequence, endpointPort.direction == .output, endpointPort.type == .image { node.sequence.anchors = [ShotAnchor(label: "Frame 1")] }
        let sourceNode: UUID, sourcePort: PortDescriptor, targetNode: UUID, targetPort: PortDescriptor
        if endpointPort.direction == .output {
            guard let input = node.inputPorts.first(where: { $0.type == endpointPort.type }) else { return }
            sourceNode = endpointNodeID; sourcePort = endpointPort; targetNode = node.id; targetPort = input
        } else {
            guard let output = node.outputPorts.first(where: { $0.type == endpointPort.type }) else { return }
            sourceNode = node.id; sourcePort = output; targetNode = endpointNodeID; targetPort = endpointPort
        }
        candidate.nodes.append(node); candidate.edges.append(.init(sourceID: sourceNode, sourcePortID: sourcePort.id, targetID: targetNode, targetPortID: targetPort.id, type: sourcePort.type))
        VideoDimensionSync.resyncNode(targetNode, in: &candidate)
        do { _ = try GraphValidator().validateStructure(candidate); editGraph { $0 = candidate }; selectedNodeID = node.id } catch { alertMessage = error.localizedDescription }
    }
    func addDynamicInput(to nodeID: UUID, label: String? = nil) {
        guard let node = currentProject?.nodes.first(where: { $0.id == nodeID }) else { return }
        guard node.kind != .imageGenerator || canAddImageInput(to: node) else { return }
        editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            if project.nodes[index].kind == .imageGenerator {
                let ordinal = project.nodes[index].imageGeneratorReferencePortIDs.count + 1
                project.nodes[index].dynamicInputs.append(.init(label: label ?? "Reference \(ordinal)", type: .image))
                return
            }
            let image = project.nodes[index].kind.supportsDynamicImageInputs
            if project.nodes[index].kind.supportsDynamicVideoInputs {
                guard project.nodes[index].dynamicInputs.count < AssemblySettings.maximumClips else { return }
                project.nodes[index].dynamicInputs.append(.init(label: label ?? SequenceEditing.nextClipLabel(project.nodes[index].dynamicInputs), type: .video)); return
            }
            guard project.nodes[index].kind.supportsDynamicTextInputs || image else { return }
            let prefix = project.nodes[index].kind == .imageGenerator ? "Reference" : image ? "Image" : project.nodes[index].kind == .promptTemplate ? "Variable" : "Part"
            let used = Set(project.nodes[index].dynamicInputs.map(\.label)); var ordinal = 1
            while used.contains("\(prefix) \(ordinal)") { ordinal += 1 }
            project.nodes[index].dynamicInputs.append(.init(label: label ?? "\(prefix) \(ordinal)", type: image ? .image : .text))
        }
    }
    func removeDynamicInput(nodeID: UUID, portID: String) {
        editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            let minimumInputs = project.nodes[index].kind == .imageGenerator ? 0 : 1
            guard project.nodes[index].dynamicInputs.count > minimumInputs else { return }
            project.nodes[index].dynamicInputs.removeAll { $0.id == portID }
            if project.nodes[index].kind.supportsDynamicImageInputs && project.nodes[index].kind != .imageGenerator {
                let prefix = project.nodes[index].kind == .imageGenerator ? "Reference" : "Image"
                for slot in project.nodes[index].dynamicInputs.indices { project.nodes[index].dynamicInputs[slot].label = "\(prefix) \(slot + 1)" }
            }
            if project.nodes[index].kind == .imageGenerator { project.nodes[index].referenceRoles?.removeValue(forKey: portID) }
            // Combine Text order is the label order, so keep "Part n" honest. A Prompt Template's names are
            // referenced by {{ }} in its text and must never be renumbered.
            if project.nodes[index].kind == .combineText {
                for slot in project.nodes[index].dynamicInputs.indices where project.nodes[index].dynamicInputs[slot].isAutomaticallyNamed(prefix: "Part") {
                    project.nodes[index].dynamicInputs[slot].label = "Part \(slot + 1)"
                }
            }
            project.edges.removeAll { $0.targetID == nodeID && $0.targetPortID == portID }
        }
    }
    /// Reorders a text-joining node's inputs. For Combine Text the order is the order of the output.
    func moveDynamicInput(nodeID: UUID, portID: String, by offset: Int) {
        editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }), project.nodes[index].kind.supportsDynamicTextInputs,
                  let from = project.nodes[index].dynamicInputs.firstIndex(where: { $0.id == portID }) else { return }
            let to = from + offset
            guard project.nodes[index].dynamicInputs.indices.contains(to) else { return }
            project.nodes[index].dynamicInputs.swapAt(from, to)
            // Automatic "Part n" labels follow position so the list never reads out of order.
            if project.nodes[index].kind == .combineText {
                for slot in project.nodes[index].dynamicInputs.indices where project.nodes[index].dynamicInputs[slot].isAutomaticallyNamed(prefix: "Part") {
                    project.nodes[index].dynamicInputs[slot].label = "Part \(slot + 1)"
                }
            }
        }
    }
    /// Records what a Reference socket supplies. Clearing the last role drops the
    /// dictionary entirely, so a node the user has emptied encodes no
    /// `referenceRoles` key and is byte-identical to a pre-feature document.
    func setReferenceRole(nodeID: UUID, portID: String, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }), project.nodes[index].kind == .imageGenerator else { return }
            var roles = project.nodes[index].referenceRoles ?? [:]
            if trimmed.isEmpty { roles.removeValue(forKey: portID) } else { roles[portID] = trimmed }
            project.nodes[index].referenceRoles = roles.isEmpty ? nil : roles
        }
    }

    /// Names a text input. A Prompt Template's name is what `{{name}}` refers to, so its references follow the rename.
    func renameDynamicInput(nodeID: UUID, portID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("{"), !trimmed.contains("}") else { return }
        guard let node = currentProject?.nodes.first(where: { $0.id == nodeID }), node.kind.supportsDynamicTextInputs,
              let port = node.dynamicInputs.first(where: { $0.id == portID }), port.label != trimmed else { return }
        guard !node.dynamicInputs.contains(where: { $0.id != portID && $0.label == trimmed }) else {
            alertMessage = "Another input on \(node.label) is already named \(trimmed)."
            return
        }
        editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }),
                  let slot = project.nodes[index].dynamicInputs.firstIndex(where: { $0.id == portID }) else { return }
            let old = project.nodes[index].dynamicInputs[slot].label
            project.nodes[index].dynamicInputs[slot].label = trimmed
            if project.nodes[index].kind == .promptTemplate {
                project.nodes[index].prompt = PromptTemplateSyntax.renaming(old, to: trimmed, in: project.nodes[index].prompt)
            }
        }
    }
    func undo() {
        guard let current = currentProject, !deletingProjectIDs.contains(current.id), var stack = undoStacks[current.id], let previous = stack.popLast() else { return }
        undoStacks[current.id] = stack; redoStacks[current.id, default: []].append(current); replace(keepingFolder(of: current, in: previous))
    }
    func redo() {
        guard let current = currentProject, !deletingProjectIDs.contains(current.id), var stack = redoStacks[current.id], let next = stack.popLast() else { return }
        redoStacks[current.id] = stack; undoStacks[current.id, default: []].append(current); replace(keepingFolder(of: current, in: next))
    }
    /// The project folder is not an edit, so undo and redo never change it.
    private func keepingFolder(of current: WorkflowProject, in other: WorkflowProject) -> WorkflowProject {
        var kept = other; kept.homeFolder = current.homeFolder; return kept
    }
    var canUndo: Bool { currentProjectID.flatMap { undoStacks[$0] }?.isEmpty == false }
    var canRedo: Bool { currentProjectID.flatMap { redoStacks[$0] }?.isEmpty == false }
    func editGraph(_ mutation: (inout WorkflowProject) -> Void) {
        guard let before = currentProject, !deletingProjectIDs.contains(before.id) else { return }; var after = before; mutation(&after)
        after.normalizeDynamicTextSockets()
        guard after != before else { return }
        undoStacks[before.id, default: []].append(before); redoStacks[before.id] = []; after.updatedAt = Date(); replace(after)
    }

    // MARK: Model advice

    /// What each installed model is worth on this Mac, which workflow nodes use missing models, and what to add.
    var modelAdvice: ModelAdviceReport {
        ModelAdvisor.report(installed: libraryStore.installed, hardware: libraryStore.hardware, projects: projects, runs: runs)
    }

    /// Nodes, across every workflow, that could move from `modelID` to the installed `replacementID`.
    func switchableNodeCount(from modelID: String, to replacementID: String) -> Int {
        projects.reduce(0) { total, project in total + project.nodes.filter { $0.model == modelID && switched($0, to: replacementID) != nil }.count }
    }

    /// Moves every node that uses `modelID` to `replacementID` where the replacement can do that node's job, adopting
    /// its tuned settings while keeping each clip's length, shape and seed. Nodes it cannot run are left as they are.
    /// Each changed workflow gets one undo step. Returns how many nodes moved.
    @discardableResult
    func switchNodes(from modelID: String, to replacementID: String) -> Int {
        var moved = 0
        for before in projects where !deletingProjectIDs.contains(before.id) {
            var after = before
            for index in after.nodes.indices where after.nodes[index].model == modelID {
                guard let next = switched(after.nodes[index], to: replacementID) else { continue }
                after.nodes[index] = next
                if next.kind.videoTask != nil { VideoDimensionSync.resyncNode(next.id, in: &after) }
                moved += 1
            }
            guard after != before else { continue }
            undoStacks[before.id, default: []].append(before); redoStacks[before.id] = []
            after.updatedAt = Date()
            replace(after)
        }
        return moved
    }

    private func switched(_ node: StudioNode, to replacementID: String) -> StudioNode? {
        guard libraryStore.installed.contains(where: { $0.id == replacementID && $0.available }) else { return nil }
        var next = node
        next.model = replacementID
        if let task = node.kind.videoTask {
            guard let capability = VideoCapabilityRegistry.capability(recipeID: replacementID, task: task), capability.readiness.adapterAvailable else { return nil }
            next.video = capability.recommendedSettings(preservingDurationFrom: node.video)
            return next
        }
        guard NodeModelCompatibility.requiredKind(for: node.kind) != nil,
              NodeModelCompatibility.issue(for: next, installed: libraryStore.installed) == nil else { return nil }
        return next
    }

    func moveNode(_ nodeID: UUID, from origin: CanvasPoint, to position: CanvasPoint, ended: Bool) {
        moveNodes([nodeID], from: [nodeID: origin], to: [nodeID: position], ended: ended)
    }

    func moveNodes(_ nodeIDs: Set<UUID>, from origins: [UUID: CanvasPoint], to positions: [UUID: CanvasPoint], ended: Bool) {
        guard var after = currentProject, !deletingProjectIDs.contains(after.id) else { return }
        var movedIDs: Set<UUID> = []
        for index in after.nodes.indices {
            let nodeID = after.nodes[index].id
            guard nodeIDs.contains(nodeID), let position = positions[nodeID] else { continue }
            after.nodes[index].position = position
            movedIDs.insert(nodeID)
        }
        guard !movedIDs.isEmpty else { return }
        if ended {
            var before = after
            for index in before.nodes.indices {
                let nodeID = before.nodes[index].id
                if movedIDs.contains(nodeID), let origin = origins[nodeID] {
                    before.nodes[index].position = origin
                }
            }
            guard before != after else { return }
            undoStacks[after.id, default: []].append(before); redoStacks[after.id] = []; after.updatedAt = Date()
        }
        replace(after)
    }

    func nudgeNodes(_ nodeIDs: Set<UUID>, by delta: CanvasPoint) {
        guard !nodeIDs.isEmpty else { return }
        editGraph { project in
            for index in project.nodes.indices where nodeIDs.contains(project.nodes[index].id) {
                project.nodes[index].position.x += delta.x
                project.nodes[index].position.y += delta.y
            }
        }
    }

    /// The generations of the given nodes in the current workflow, oldest first, detached from it so they can
    /// be pasted here or into another workflow. Only nodes that actually generate are included; a Prompt has none.
    func generations(for nodeIDs: Set<UUID>) -> [NodeGeneration] {
        guard let project = currentProject else { return [] }
        let generating = project.nodes.filter { nodeIDs.contains($0.id) && ($0.supportsTakes || $0.kind.usesModel) }
        guard !generating.isEmpty else { return [] }
        return executionArtifacts.filter { $0.projectID == project.id }.sorted { $0.createdAt < $1.createdAt }.compactMap { artifact in
            let ids = Set(generating.filter { node in
                artifact.generatedNodeIDs?.contains(node.id) != false && artifact.values.keys.contains { $0.nodeID == node.id }
            }.map(\.id))
            guard !ids.isEmpty else { return nil }
            let names = artifact.mediaNames?.filter { key, _ in ids.contains { key.hasPrefix($0.uuidString) } }
            return NodeGeneration(
                createdAt: artifact.createdAt,
                nodes: ids.compactMap { id in artifact.graphSnapshot.nodes.first { $0.id == id } ?? generating.first { $0.id == id } },
                values: artifact.values.filter { ids.contains($0.key.nodeID) },
                generatedNodeIDs: ids,
                mediaProvenance: artifact.mediaProvenance?.filter { ids.contains($0.key) },
                mediaNames: names?.isEmpty == false ? names : nil,
                selectedForNodeIDs: ids.filter { id in project.nodes.first { $0.id == id }?.selectedTakeID == artifact.id })
        }
    }

    /// Re-creates copied generations under the copies' node ids, in the workflow they are pasted into.
    /// Each copy owns new records, so deleting a take from one node never removes it from the other;
    /// the media files stay shared and are only deleted once no record uses them.
    private func cloneGenerations(_ generations: [NodeGeneration], idMap: [UUID: UUID], into project: WorkflowProject) -> (artifacts: [ExecutionArtifact], selectedTakeIDs: [UUID: UUID]) {
        var artifacts: [ExecutionArtifact] = [], selected: [UUID: UUID] = [:]
        for generation in generations {
            let values = Dictionary(uniqueKeysWithValues: generation.values.compactMap { address, value -> (PortAddress, RuntimeValue)? in
                idMap[address.nodeID].map { (PortAddress(nodeID: $0, portID: address.portID), value) }
            })
            guard let target = values.keys.map(\.nodeID).min(by: { $0.uuidString < $1.uuidString }) else { continue }
            let snapshotNodes = generation.nodes.compactMap { node -> StudioNode? in
                guard let id = idMap[node.id] else { return nil }
                var copy = node; copy.id = id; copy.selectedTakeID = nil; return copy
            }
            var names: [String: String] = [:]
            for (key, name) in generation.mediaNames ?? [:] {
                guard let old = idMap.keys.first(where: { key.hasPrefix($0.uuidString) }), let new = idMap[old] else { continue }
                names[new.uuidString + key.dropFirst(old.uuidString.count)] = name
            }
            let provenance = generation.mediaProvenance?.reduce(into: [UUID: RenderedMediaProvenance]()) { result, entry in
                if let id = idMap[entry.key] { result[id] = entry.value }
            }
            let artifact = ExecutionArtifact(
                id: UUID(), projectID: project.id, targetID: target,
                graphSnapshot: WorkflowProject(id: project.id, name: project.name, nodes: snapshotNodes, edges: []),
                values: values, createdAt: generation.createdAt,
                mediaProvenance: provenance?.isEmpty == false ? provenance : nil,
                generatedNodeIDs: Set(generation.generatedNodeIDs.compactMap { idMap[$0] }),
                mediaNames: names.isEmpty ? nil : names)
            artifacts.append(artifact)
            for old in generation.selectedForNodeIDs { if let new = idMap[old] { selected[new] = artifact.id } }
        }
        return (artifacts, selected)
    }

    func persistArtifacts(_ artifacts: [ExecutionArtifact]) {
        guard !artifacts.isEmpty else { return }
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            for artifact in artifacts {
                do { try await persistence.saveExecutionArtifact(artifact) } catch { alertMessage = error.localizedDescription }
            }
        }
    }

    @discardableResult
    func pasteNodes(_ sourceNodes: [StudioNode], edges sourceEdges: [StudioEdge], generations: [NodeGeneration] = [], externalInputs: [StudioEdge] = [], centeredAt target: CanvasPoint, inPlace: Bool = false) -> Set<UUID> {
        guard let project = currentProject, !sourceNodes.isEmpty else { return [] }
        let minX = sourceNodes.map(\.position.x).min() ?? 0
        let minY = sourceNodes.map(\.position.y).min() ?? 0
        let maxX = sourceNodes.map { $0.position.x + NodeLayout.cardWidth($0) }.max() ?? minX
        let maxY = sourceNodes.map { $0.position.y + NodeLayout.cardHeight($0) }.max() ?? minY
        let delta = inPlace ? CanvasPoint(x: 0, y: 0) : CanvasPoint(x: target.x - (minX + maxX) / 2, y: target.y - (minY + maxY) / 2)
        var idMap: [UUID: UUID] = [:]
        var usedLabels = project.nodes.map(\.label)
        var nodes = sourceNodes.map { source -> StudioNode in
            var node = source
            let id = UUID()
            idMap[source.id] = id
            node.id = id
            node.position = .init(x: source.position.x + delta.x, y: source.position.y + delta.y)
            node.label = duplicateLabel(for: source.label, in: usedLabels)
            node.selectedTakeID = nil
            node.finalized = nil
            usedLabels.append(node.label)
            return node
        }
        var edges = sourceEdges.compactMap { source -> StudioEdge? in
            guard let sourceID = idMap[source.sourceID], let targetID = idMap[source.targetID] else { return nil }
            var edge = source
            edge.id = UUID()
            edge.sourceID = sourceID
            edge.targetID = targetID
            return edge
        }
        // Paste-and-reconnect: wires that fed the copied nodes from nodes that still exist here. Pasting into
        // another workflow finds no such source and simply skips them.
        let existing = Set(project.nodes.map(\.id))
        edges += externalInputs.compactMap { source -> StudioEdge? in
            guard existing.contains(source.sourceID), let targetID = idMap[source.targetID] else { return nil }
            var edge = source
            edge.id = UUID()
            edge.targetID = targetID
            return edge
        }
        let cloned = cloneGenerations(generations, idMap: idMap, into: project)
        for index in nodes.indices { nodes[index].selectedTakeID = cloned.selectedTakeIDs[nodes[index].id] }
        executionArtifacts.append(contentsOf: cloned.artifacts)
        persistArtifacts(cloned.artifacts)
        editGraph { project in
            project.nodes.append(contentsOf: nodes)
            project.edges.append(contentsOf: edges)
        }
        let ids = Set(nodes.map(\.id))
        selectedNodeID = nodes.first?.id
        return ids
    }

    func alignNodes(_ nodeIDs: Set<UUID>, _ alignment: NodeArrangement.Alignment) {
        guard let nodes = currentProject?.nodes else { return }
        applyPositions(NodeArrangement.align(nodes, ids: nodeIDs, alignment))
    }

    func distributeNodes(_ nodeIDs: Set<UUID>, _ axis: NodeArrangement.Axis) {
        guard let nodes = currentProject?.nodes else { return }
        applyPositions(NodeArrangement.distribute(nodes, ids: nodeIDs, axis))
    }

    private func applyPositions(_ positions: [UUID: CanvasPoint]) {
        guard !positions.isEmpty else { return }
        editGraph { project in
            for index in project.nodes.indices {
                if let position = positions[project.nodes[index].id] { project.nodes[index].position = position }
            }
        }
    }

    /// Tidies the workflow into flows and columns. Passing two or more ids
    /// tidies just those, in place, so one pocket can be cleaned up without
    /// disturbing the rest of the board.
    func organiseNodes(limitedTo scope: Set<UUID> = []) {
        guard currentProject?.nodes.isEmpty == false else { return }
        editGraph { project in
            let positions = WorkflowAutoLayout.positions(nodes: project.nodes, edges: project.edges, scope: scope.count > 1 ? scope : nil)
            for index in project.nodes.indices {
                if let position = positions[project.nodes[index].id] { project.nodes[index].position = position }
            }
        }
    }

    func fitView(canvasWidth: Double, canvasHeight: Double) {
        mutateProject { project in
            project.viewport = CanvasInteraction.fittedViewport(nodes: project.nodes, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        }
    }

    func runSelected() {
        guard let project = currentProject, !deletingProjectIDs.contains(project.id), let selectedNodeID else {
            alertMessage = "Select a node to generate or run."
            return
        }
        if let target = project.nodes.first(where: { $0.id == selectedNodeID }), target.isLockedFinal {
            alertMessage = "“\(target.label)” is locked as final. Unlock it to generate again."
            return
        }
        let request = PendingRun(project: project, targetID: selectedNodeID, plan: RunPlan.make(project: project, target: selectedNodeID))
        do { try preflight(request) }
        catch { alertMessage = error.localizedDescription; return }
        if request.plan.requiresConfirmation { pendingRun = request; return }
        enqueue(request)
    }

    /// Validate video-generation blockers before presenting a time/cost confirmation. This is
    /// intentionally scoped to video nodes: the confirmation's historical contract is to capture
    /// longer non-video graphs before execution validation, while missing video recipes must be
    /// explained before asking the user to approve a potentially hour-long run.
    private func preflight(_ request: PendingRun) throws {
        let snapshot = request.project
        try lockedFinalIssue(in: snapshot, target: request.targetID)
        let reachable = RunPlan.reachableNodes(project: snapshot, target: request.targetID)
        for node in reachable where node.kind.videoTask != nil {
            let connected = Set(snapshot.edges.filter { $0.targetID == node.id }.map(\.targetPortID))
            if let issue = VideoPreflight.generationIssue(
                node,
                connectedPorts: connected,
                installed: libraryStore.installed,
                registry: VideoCapabilityRegistry.shipped
            ) {
                throw StudioError.validation(issue)
            }
        }
    }

    func confirmPendingRun() {
        guard let request = pendingRun else { return }
        pendingRun = nil
        enqueue(request)
    }

    /// Queues every end point of the current workflow, in left-to-right, top-to-bottom order, so the
    /// whole graph generates unattended. Validates every target up front so the run doesn't stall
    /// partway through on a fixable problem, then asks once for the whole batch instead of once per node.
    func runWholeWorkflow() {
        guard let project = currentProject, !deletingProjectIDs.contains(project.id) else {
            alertMessage = "Open a workflow to run."
            return
        }
        let targets = RunPlan.wholeWorkflowTargets(project: project)
        guard !targets.isEmpty else {
            alertMessage = "Nothing to run — add or connect a node first."
            return
        }
        var requests: [PendingRun] = []
        for targetID in targets {
            let request = PendingRun(project: project, targetID: targetID, plan: RunPlan.make(project: project, target: targetID))
            do { try preflight(request) }
            catch {
                let label = project.nodes.first(where: { $0.id == targetID })?.label ?? "A node"
                alertMessage = "\(label): \(error.localizedDescription)"
                return
            }
            requests.append(request)
        }
        if RunPlan.make(project: project, targets: targets).requiresConfirmation {
            pendingWorkflowRun = requests
        } else {
            requests.forEach(enqueue)
        }
    }

    func confirmPendingWorkflowRun() {
        guard let requests = pendingWorkflowRun else { return }
        pendingWorkflowRun = nil
        requests.forEach(enqueue)
    }

    static let maximumTakeBatch = 24

    /// Queues `count` generations of one node for an unattended batch (for example overnight). Each take
    /// gets a fresh seed even when the node's seed is locked, because a batch of one repeated seed would
    /// be the same take N times; the node's own lock is left as it was. Asks once for the whole batch.
    func runTakes(of node: StudioNode, count: Int) {
        guard (1...Self.maximumTakeBatch).contains(count), let project = currentProject, !deletingProjectIDs.contains(project.id),
              let index = project.nodes.firstIndex(where: { $0.id == node.id }), project.nodes[index].supportsTakes else { return }
        if project.nodes[index].isLockedFinal {
            alertMessage = "“\(project.nodes[index].label)” is locked as final. Unlock it to generate more takes."
            return
        }
        var snapshot = project
        snapshot.nodes[index].seedLocked = false
        let plan = RunPlan.make(project: snapshot, target: node.id)
        let batch = (0..<count).map { _ in PendingRun(project: snapshot, targetID: node.id, plan: plan, isBatchTake: true) }
        do { try preflight(batch[0]) }
        catch { alertMessage = error.localizedDescription; return }
        pendingTakeBatch = batch
    }

    func confirmPendingTakeBatch() {
        guard let batch = pendingTakeBatch else { return }
        pendingTakeBatch = nil
        batch.forEach(enqueue)
    }

    /// Cancels a node's take in flight and every take of it still waiting.
    func cancelTakes(of nodeID: UUID) {
        queuedRuns.removeAll { $0.targetID == nodeID && $0.project.id == currentProjectID }
        if isRunning(nodeID) { runTask?.cancel() }
    }

    func queuedTakeCount(for nodeID: UUID) -> Int {
        queuedRuns.filter { $0.targetID == nodeID && $0.project.id == currentProjectID }.count
    }

    /// Stops the whole queued batch, not just the run in flight: clears anything still waiting so
    /// coming back to cancel a long walk-away run is one click, not one per queued node.
    func cancelWholeWorkflow() {
        queuedRuns.removeAll()
        runTask?.cancel()
    }

    private func enqueue(_ request: PendingRun) {
        guard !deletingProjectIDs.contains(request.project.id), projects.contains(where: { $0.id == request.project.id }) else {
            alertMessage = "This run cannot be queued because its workflow has been removed."
            return
        }
        guard request.isBatchTake || !isQueued(request.targetID, in: request.project.id) else { return }
        if isRunning { queuedRuns.append(request) } else { execute(request) }
    }

    private func execute(_ request: PendingRun) {
        guard !isRunning, !deletingProjectIDs.contains(request.project.id), projects.contains(where: { $0.id == request.project.id }) else { alertMessage = "This run cannot start while another generation is active or its workflow has been removed."; return }
        let project = request.project, selectedNodeID = request.targetID
        let selectedTakes = Dictionary(uniqueKeysWithValues: project.nodes.compactMap { node in
            self.selectedTake(for: node).map { (node.id, $0) }
        })
        var upstreamValues = runtimeValues.filter { $0.key.nodeID != selectedNodeID }
        for node in project.nodes where node.id != selectedNodeID {
            for port in node.outputPorts {
                let address = PortAddress(nodeID: node.id, portID: port.id)
                if upstreamValues[address] == nil,
                   let value = selectedTakes[node.id]?.values[address]
                    ?? executionArtifacts.first(where: { $0.projectID == project.id && $0.values[address] != nil })?.values[address] {
                    upstreamValues[address] = value
                }
            }
        }
        // A locked node stands as final: its saved file is the value downstream nodes receive, and it is never re-run.
        if let home = home(for: project) {
            for node in project.nodes where node.isLockedFinal && node.id != selectedNodeID {
                guard let record = node.finalized, !home.isMissing(record), let port = node.outputPorts.first else { continue }
                upstreamValues[PortAddress(nodeID: node.id, portID: port.id)] = home.value(of: record)
            }
        }
        isRunning = true
        wakeGuard.hold(reason: "GenStudio is generating locally")
        if batchRecord == nil { batchRecord = RunBatchRecord(startedAt: Date()) }
        let runLabel = project.nodes.first { $0.id == selectedNodeID }?.label ?? project.name
        workflowProgress = WorkflowProgress(runID: request.id, project: project, target: selectedNodeID)
        libraryStore.generationRunning = true
        runTask = Task { [self] in
            do {
                let result = try await queue.execute(project: project, targetID: selectedNodeID, installedModels: Set(models.map(\.name) + libraryStore.installed.filter(\.available).map(\.id)), installedGenerationModels: libraryStore.installed, selectedTakes: selectedTakes, upstreamValues: upstreamValues, cloudSignedIn: chatGPTSubscription.isSignedIn, onEvent: { [weak self] event in
                    await self?.receiveProgress(event, runID: request.id)
                })
                runtimeValues = result.values
                for id in Set(result.values.keys.map(\.nodeID)) { supersededAttempts[id] = nil }
                if let output = result.textOutput { outputs.insert(output, at: 0) }
                executionArtifacts = try await persistence.loadExecutionArtifacts()
                if currentProjectID == project.id {
                    mutateProject { current in
                        for index in current.nodes.indices where current.nodes[index].id == selectedNodeID || (selectedTakes[current.nodes[index].id] == nil && result.values.keys.contains(where: { $0.nodeID == current.nodes[index].id })) {
                            current.nodes[index].selectedTakeID = nil
                        }
                    }
                }
                runs = try await persistence.loadRuns(recoverInterrupted: false)
                batchRecord?.record(label: runLabel, outcome: .succeeded)
            } catch is CancellationError {
                batchRecord?.record(label: runLabel, outcome: .cancelled)
                workflowProgress?.failActive(error: CancellationError())
                invalidateUnfinished(reason: "Latest attempt was cancelled.")
                runs = (try? await persistence.loadRuns(recoverInterrupted: false)) ?? runs
            } catch {
                batchRecord?.record(label: runLabel, outcome: .failed)
                workflowProgress?.failActive(error: error)
                invalidateUnfinished(reason: "Latest attempt failed: \(error.localizedDescription)")
                alertMessage = error.localizedDescription
                runs = (try? await persistence.loadRuns(recoverInterrupted: false)) ?? runs
            }
            isRunning = false
            runTask = nil
            libraryStore.generationRunning = false
            await refreshModels()
            if !queuedRuns.isEmpty {
                execute(queuedRuns.removeFirst())
            } else {
                finishBatch()
            }
        }
    }

    /// The queue is empty: allow sleep again and, for long work finished in the background, say so.
    private func finishBatch() {
        wakeGuard.release()
        guard let record = batchRecord else { return }
        batchRecord = nil
        let finished = Date()
        guard RunBatchRecord.shouldNotify(elapsed: finished.timeIntervalSince(record.startedAt), appActive: NSApp?.isActive ?? true) else { return }
        let notice = record.notice(finishedAt: finished)
        RunFinishNotifier.post(title: notice.title, body: notice.body)
    }

    private func invalidateUnfinished(reason: String) {
        guard let progress = workflowProgress else { return }
        for id in StaleResultPolicy.unfinishedNodes(progress) {
            supersededAttempts[id] = reason
            if currentProject?.nodes.first(where: { $0.id == id })?.supportsTakes != true {
                runtimeValues = runtimeValues.filter { $0.key.nodeID != id }
            }
        }
    }

    private func receiveProgress(_ event: NodeExecutionEvent, runID: UUID) {
        guard workflowProgress?.runID == runID else { return }
        workflowProgress?.receive(event)
    }
    func displayedProgress(for node: StudioNode) -> NodeExecutionProgress? {
        guard workflowProgress?.project.id == currentProjectID else { return nil }
        return workflowProgress?.display(for: node)
    }
    func cancelRun() { runTask?.cancel() }
    /// Removes every waiting run of the node: a single queued run, or the rest of a batch of takes.
    func cancelQueuedRun(_ nodeID: UUID) {
        queuedRuns.removeAll { $0.targetID == nodeID && $0.project.id == currentProjectID }
    }
    func moveQueuedRuns(from offsets: IndexSet, to destination: Int) {
        queuedRuns.move(fromOffsets: offsets, toOffset: destination)
    }
    func isQueued(_ nodeID: UUID, in projectID: UUID? = nil) -> Bool {
        let projectID = projectID ?? currentProjectID
        return queuedRuns.contains { $0.targetID == nodeID && $0.project.id == projectID }
    }
    func isRunning(_ nodeID: UUID) -> Bool {
        isRunning && workflowProgress?.target == nodeID
    }

    func exportProject(_ id: UUID? = nil) {
        let target = id ?? currentProjectID
        guard let project = projects.first(where: { $0.id == target }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(project.name).genstudio.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { try await persistence.exportProject(project, to: url) } catch { alertMessage = error.localizedDescription } }
    }

    func exportOutput(_ output: TextOutput) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(output.model)-\(output.id.uuidString.prefix(8)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try output.text.write(to: url, atomically: true, encoding: .utf8) }
        catch { alertMessage = error.localizedDescription }
    }

    func exportRuntimeValue(_ value: RuntimeValue) {
        let panel = NSSavePanel()
        switch value {
        case .shotSequence(let sequence):
            panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "sequence.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { try encoder.encode(sequence).write(to: destination, options: .atomic) } catch { alertMessage = error.localizedDescription }
        case .image(let source), .video(let source):
            panel.nameFieldStringValue = source.lastPathComponent
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                try MediaExport.copy(source: source, destination: destination)
            } catch { alertMessage = "Could not export retained media: \(error.localizedDescription)" }
        case .text(let text):
            panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "result.txt"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do { try text.write(to: destination, atomically: true, encoding: .utf8) } catch { alertMessage = error.localizedDescription }
        case .textArray(let items):
            panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "items.json"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do { try JSONEncoder().encode(items).write(to: destination, options: .atomic) } catch { alertMessage = error.localizedDescription }
        case .number(let number):
            panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "number.txt"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do { try number.formatted().write(to: destination, atomically: true, encoding: .utf8) } catch { alertMessage = error.localizedDescription }
        }
    }
}

private extension GraphValidator {
    func validateStructure(_ project: WorkflowProject) throws -> [UUID] {
        try validate(project, installedModels: nil, requireRunnableInputs: false)
    }
}

/// Memoized per-redraw answers derived from `StudioModel.executionArtifacts`; reset whenever it changes.
struct CanvasLookupCache {
    struct Key: Hashable { let projectID: UUID?; let address: PortAddress }
    var takes: [Key: [ExecutionArtifact]] = [:]
    var latestValues: [Key: RuntimeValue?] = [:]

    mutating func reset() {
        takes.removeAll(keepingCapacity: true)
        latestValues.removeAll(keepingCapacity: true)
    }
}
