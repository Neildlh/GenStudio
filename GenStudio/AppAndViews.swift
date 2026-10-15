import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct WorkflowNodeClipboard: Codable {
    let nodes: [StudioNode]
    let edges: [StudioEdge]
    /// Absent in payloads copied by older builds.
    var generations: [NodeGeneration]? = nil
    /// Wires that fed the copied nodes from nodes outside the copy, for Paste and Reconnect.
    var externalInputs: [StudioEdge]? = nil
}

private struct CanvasCommandActions {
    let acceptsCanvasKeys: Bool
    let hasNodes: Bool
    let hasSelection: Bool
    let canPaste: Bool
    let frameSelection: () -> Void
    let fitWorkflow: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let searchNodes: () -> Void
    let selectAll: () -> Void
    let renameSelection: () -> Void
    let duplicateSelection: () -> Void
    let deleteSelection: () -> Void
    let copySelection: () -> Void
    let cutSelection: () -> Void
    let pasteSelection: () -> Void
    let pasteInPlace: () -> Void
    let pasteAndReconnect: () -> Void
    let deselectAll: () -> Void
    let invertSelection: () -> Void
    let selectUpstream: () -> Void
    let selectDownstream: () -> Void
    let selectConnected: () -> Void
    let selectSameKind: () -> Void
    let align: (NodeArrangement.Alignment) -> Void
    let distribute: (NodeArrangement.Axis) -> Void
    let selectionCount: Int
}

private struct CanvasCommandActionsKey: FocusedValueKey {
    typealias Value = CanvasCommandActions
}

private extension FocusedValues {
    var canvasCommandActions: CanvasCommandActions? {
        get { self[CanvasCommandActionsKey.self] }
        set { self[CanvasCommandActionsKey.self] = newValue }
    }
}

/// Before quitting, offers to lock generations that are only drafts, so the artwork is saved in its project folder.
@MainActor
final class GenStudioAppDelegate: NSObject, NSApplicationDelegate {
    var model: StudioModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.unlockedGenerationCount > 0 else { return .terminateNow }
        let count = model.unlockedGenerationCount
        let alert = NSAlert()
        alert.messageText = "Lock \(count) generation\(count == 1 ? "" : "s") before quitting?"
        alert.informativeText = "Unlocked generations are kept only as drafts inside GenStudio. Locking saves each one to its project folder under its node's heading, so the artwork is safe and ready to hand over."
        alert.addButton(withTitle: "Lock All and Quit")
        alert.addButton(withTitle: "Quit, Keep as Drafts")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let problems = model.lockAllGenerations()
            if !problems.isEmpty {
                let failure = NSAlert()
                failure.messageText = "Some generations could not be saved"
                failure.informativeText = problems.prefix(6).joined(separator: "\n")
                failure.addButton(withTitle: "Quit Anyway")
                failure.addButton(withTitle: "Cancel")
                guard failure.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            }
        case .alertSecondButtonReturn:
            break
        default:
            return .terminateCancel
        }
        // Let the queued saves (the project file in each folder included) finish before the app goes.
        Task { await model.flushProjectWrites(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct GenStudioApp: App {
    @NSApplicationDelegateAdaptor(GenStudioAppDelegate.self) private var appDelegate
    @StateObject private var model = StudioModel()
    @FocusedValue(\.canvasCommandActions) private var canvasCommands

    var body: some Scene {
        WindowGroup(id: "main") {
            StudioView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .task { appDelegate.model = model; await model.start() }
                .onOpenURL { url in if url.pathExtension == ProjectPackage.fileExtension { model.openPackage(url) } }
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { performUndo(model) }
                    .keyboardShortcut("z")
                    .disabled(!canPerformUndo(model))
                Button("Redo") { performRedo(model) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!canPerformRedo(model))
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Workflow") { model.saveNow() }.keyboardShortcut("s")
                Divider()
                Button("New Project in Folder…") { model.newProjectInFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project File…") { model.openPackage() }.keyboardShortcut("o")
                Button("Save Workflow As…") { if let id = model.currentProjectID { model.chooseProjectFolder(for: id) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.currentProject == nil)
                Button("Show Project Folder in Finder") { if let home = model.currentHome { model.revealInFinder(home.root) } }
                    .disabled(model.currentHome == nil)
                Button("Lock All Generations") {
                    let problems = model.lockAllGenerations()
                    if !problems.isEmpty { model.alertMessage = "Some generations could not be saved:\n" + problems.joined(separator: "\n") }
                }.disabled(model.unlockedGenerationCount == 0)
                Button("Package Project…") { model.packageProject() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(model.currentProject == nil || model.isPackaging)
                Divider()
                Button("Import Flow…") { model.importFlowFile() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Paste Flow from Clipboard") { model.importFlowFromClipboard() }
                Divider()
                Button("Export Shareable Flow…") { model.exportFlow() }.keyboardShortcut("e", modifiers: [.command, .option])
                Button("Export Workflow Backup…") { model.exportProject() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Copy AI Briefing") { model.copyAIBriefing() }
                Button("Save AI Briefing…") { model.saveAIBriefing() }
            }
            CommandMenu("Workflow") {
                Button("Run Selected Node") { model.runSelected() }.keyboardShortcut(.return, modifiers: [.command])
                Button("Cancel Run") { model.cancelRun() }.keyboardShortcut(".", modifiers: [.command])
                Divider()
                Button("Search Nodes…") { canvasCommands?.searchNodes() }
                    .keyboardShortcut("k")
                    .disabled(canvasCommands?.acceptsCanvasKeys != true)
                Button("Rename Selected Node") { canvasCommands?.renameSelection() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasSelection != true)
                Button("Duplicate Selected Nodes") { canvasCommands?.duplicateSelection() }
                    .keyboardShortcut("d", modifiers: [.command])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasSelection != true)
                Button("Delete Selection") { canvasCommands?.deleteSelection() }
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasSelection != true)
                Divider()
                ForEach(NodeKind.allCases, id: \.self) { kind in Button("Add \(kind.title)") { model.addNode(kind) } }
            }
            CommandMenu("Canvas") {
                Button("Frame Selection") { canvasCommands?.frameSelection() }
                    .keyboardShortcut("f", modifiers: [])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasNodes != true)
                Button("Fit Workflow") { canvasCommands?.fitWorkflow() }
                    .keyboardShortcut("f", modifiers: [.shift])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasNodes != true)
                Divider()
                Button("Zoom In") { canvasCommands?.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(canvasCommands?.acceptsCanvasKeys != true)
                Button("Zoom Out") { canvasCommands?.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(canvasCommands?.acceptsCanvasKeys != true)
                Button("Actual Size") { canvasCommands?.actualSize() }
                    .keyboardShortcut("0")
                    .disabled(canvasCommands?.acceptsCanvasKeys != true)
                Divider()
                Button("Select All Nodes") { canvasCommands?.selectAll() }
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasNodes != true)
                Button("Deselect All") { canvasCommands?.deselectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasSelection != true)
                Button("Invert Selection") { canvasCommands?.invertSelection() }
                    .keyboardShortcut("i", modifiers: [.command, .control])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasNodes != true)
                Menu("Select Related") {
                    Button("Upstream Nodes") { canvasCommands?.selectUpstream() }.keyboardShortcut("[", modifiers: [.command, .option])
                    Button("Downstream Nodes") { canvasCommands?.selectDownstream() }.keyboardShortcut("]", modifiers: [.command, .option])
                    Button("Whole Connected Flow") { canvasCommands?.selectConnected() }.keyboardShortcut("a", modifiers: [.command, .option])
                    Button("Nodes of the Same Type") { canvasCommands?.selectSameKind() }
                }
                .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasSelection != true)
                Divider()
                Button("Cut Selected Nodes") { canvasCommands?.cutSelection() }
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasSelection != true)
                Button("Copy Selected Nodes") { canvasCommands?.copySelection() }
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.hasSelection != true)
                Button("Paste Nodes") { canvasCommands?.pasteSelection() }
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.canPaste != true)
                Button("Paste in Place") { canvasCommands?.pasteInPlace() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.canPaste != true)
                Button("Paste and Reconnect Inputs") { canvasCommands?.pasteAndReconnect() }
                    .keyboardShortcut("v", modifiers: [.command, .option, .shift])
                    .disabled(canvasCommands?.acceptsCanvasKeys != true || canvasCommands?.canPaste != true)
                Divider()
                Menu("Align") {
                    Button("Left") { canvasCommands?.align(.left) }
                    Button("Centre Horizontally") { canvasCommands?.align(.centerHorizontally) }
                    Button("Right") { canvasCommands?.align(.right) }
                    Divider()
                    Button("Top") { canvasCommands?.align(.top) }
                    Button("Centre Vertically") { canvasCommands?.align(.centerVertically) }
                    Button("Bottom") { canvasCommands?.align(.bottom) }
                }
                .disabled(canvasCommands?.acceptsCanvasKeys != true || (canvasCommands?.selectionCount ?? 0) < 2)
                Menu("Distribute") {
                    Button("Horizontally") { canvasCommands?.distribute(.horizontal) }
                    Button("Vertically") { canvasCommands?.distribute(.vertical) }
                }
                .disabled(canvasCommands?.acceptsCanvasKeys != true || (canvasCommands?.selectionCount ?? 0) < 3)
            }
        }
        Settings {
            ChatGPTSubscriptionSettingsView(session: model.chatGPTSubscription)
        }
    }
}

@MainActor private func performUndo(_ model: StudioModel) {
    if let textView = focusedEditableTextView() {
        textView.undoManager?.undo()
    } else {
        model.undo()
    }
}

@MainActor private func performRedo(_ model: StudioModel) {
    if let textView = focusedEditableTextView() {
        textView.undoManager?.redo()
    } else {
        model.redo()
    }
}

@MainActor private func canPerformUndo(_ model: StudioModel) -> Bool {
    focusedEditableTextView().map { $0.undoManager?.canUndo == true } ?? model.canUndo
}

@MainActor private func canPerformRedo(_ model: StudioModel) -> Bool {
    focusedEditableTextView().map { $0.undoManager?.canRedo == true } ?? model.canRedo
}

@MainActor private func focusedEditableTextView() -> NSTextView? {
    guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable else { return nil }
    return textView
}

/// Keep window geometry as an app UI preference, separate from workflow
/// documents and their schema compatibility. Split-view column widths are
/// persisted separately by StudioView (see sidebarWidth/detailWidth): a prior
/// version of this bridge tried to save/restore NSSplitView divider positions
/// by walking the window's view tree for "the widest vertical NSSplitView
/// with 3+ subviews", but NavigationSplitView's internal AppKit hierarchy on
/// macOS contains other split views that heuristic can match instead (proven
/// by reproduction: it found a 10-subview split view with non-monotonic
/// divider positions, unrelated to the sidebar/content/detail columns), so it
/// silently saved and restored the wrong split view's geometry.
private struct StudioWindowStatePersistence: NSViewRepresentable {
    func makeNSView(context: Context) -> StateView { StateView() }
    func updateNSView(_ nsView: StateView, context: Context) {}

    @MainActor final class StateView: NSView {
        private static let frameName = "GenStudio.main.window"
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            guard let window else { return }

            window.setFrameAutosaveName(Self.frameName)
            window.isRestorable = true
            _ = window.setFrameUsingName(Self.frameName)

            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.saveWindowFrame() }
            })
            observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.saveWindowFrame() }
            })
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.saveWindowFrame() }
            })
        }

        private func saveWindowFrame() {
            window?.saveFrame(usingName: Self.frameName)
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }

    }
}

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @State private var showingNodePicker = false
    @State private var showingQueue = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// The sidebar shows icons only until it is dragged wide enough for icon + name.
    private static let sidebarLabelsMinWidth: CGFloat = 600
    private static let sidebarWidthKey = "studio.sidebarColumnWidth"
    private static let detailWidthKey = "studio.detailColumnWidth"
    @State private var sidebarWidth: CGFloat = StudioView.storedColumnWidth(forKey: StudioView.sidebarWidthKey, default: 72)
    @State private var detailWidth: CGFloat = StudioView.storedColumnWidth(forKey: StudioView.detailWidthKey, default: 300)
    private var sidebarIsCompact: Bool { sidebarWidth < Self.sidebarLabelsMinWidth }

    /// NavigationSplitView column widths a user drags are not persisted by
    /// SwiftUI itself; `ideal:` only sets the width used the first time a
    /// column is laid out. Reading the last-observed width back in here
    /// restores it across launches without touching AppKit's private
    /// NSSplitView hierarchy (see StudioWindowStatePersistence's history).
    private static func storedColumnWidth(forKey key: String, default fallback: CGFloat) -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? CGFloat(stored) : fallback
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            StudioSidebar(model: model, isCompact: sidebarIsCompact)
                .background(GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                        sidebarWidth = width
                        UserDefaults.standard.set(Double(width), forKey: Self.sidebarWidthKey)
                    }
                })
                .navigationSplitViewColumnWidth(min: 64, ideal: sidebarWidth, max: 640)
        } content: {
            if model.sidebarSection == .models {
                ModelLibraryView(store: model.libraryStore, generationRunning: model.isRunning)
            } else if let project = model.currentProject {
                CanvasView(model: model, project: project)
                    .disabled(model.deletingProjectIDs.contains(project.id))
            } else {
                ContentUnavailableView { Label("No workflow selected", systemImage: "point.3.connected.trianglepath.dotted") } description: { Text("Create a workflow to begin.") } actions: { Button("New Workflow") { model.createProject() } }
            }
        } detail: {
            Group {
                if model.sidebarSection == .models {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local Generation").font(.headline)
                        Text("Choose an installed model in each generation node's inspector. Each node stores its own selection.").font(.callout)
                        Text("Engine: \(model.nativeRuntimeState)").font(.caption)
                        Text("Model weights stay on disk. The bundled process loads them for one run and releases memory when it exits.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(20)
                } else {
                    InspectorView(model: model)
                        .disabled(model.currentProjectID.map { model.deletingProjectIDs.contains($0) } ?? false)
                }
            }
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    detailWidth = width
                    UserDefaults.standard.set(Double(width), forKey: Self.detailWidthKey)
                }
            })
            .navigationSplitViewColumnWidth(min: 260, ideal: detailWidth, max: 720)
        }
        .background(StudioWindowStatePersistence())
        .onReceive(NotificationCenter.default.publisher(for: .nativeGenerationState).receive(on: RunLoop.main)) { notification in
            if let state = notification.userInfo?["state"] as? String { model.nativeRuntimeState = state.capitalized; if let id = notification.userInfo?["modelID"] as? String { model.libraryStore.runtimeStates[id] = state.capitalized } }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Add Node", systemImage: "plus") { showingNodePicker.toggle() }
                    .popover(isPresented: $showingNodePicker) { AddNodePicker(model: model) { showingNodePicker = false } }
                if model.isRunning {
                    Button("Cancel", systemImage: "stop.fill") { model.cancelRun() }
                } else {
                    Button("Run", systemImage: "play.fill") { model.runSelected() }
                    Button("Run All", systemImage: "play.square.stack") { model.runWholeWorkflow() }
                        .help("Run every node in the workflow, left to right, skipping anything locked as final.")
                }
                if model.libraryStore.busy {
                    Label("Downloading in background", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.queuedRuns.isEmpty {
                    Button {
                        showingQueue = true
                    } label: {
                        Label("Queue · \(model.queuedRuns.count)", systemImage: "list.number")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help("Reorder queued runs")
                    .popover(isPresented: $showingQueue, arrowEdge: .top) {
                        QueuePopover(model: model)
                    }
                    Button("Stop All", systemImage: "stop.circle") { model.cancelWholeWorkflow() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Cancel the current run and clear the rest of the queue.")
                }
                Button("Save", systemImage: "square.and.arrow.down") { model.saveNow() }
            }
        }
        .alert("Start this longer workflow?", isPresented: Binding(get: { model.pendingRun != nil }, set: { if !$0 { model.pendingRun = nil } })) {
            Button("Cancel", role: .cancel) { model.pendingRun = nil }
            Button("Run Anyway") { model.confirmPendingRun() }
        } message: {
            if let request = model.pendingRun {
                Text("\(request.project.name) → \(request.project.nodes.first(where: { $0.id == request.targetID })?.label ?? "Selected node")\n\(request.plan.summary)\nThis runs the captured graph and settings, even if the editor selection changes.")
            }
        }
        .alert("Run the whole workflow?", isPresented: Binding(get: { model.pendingWorkflowRun != nil }, set: { if !$0 { model.pendingWorkflowRun = nil } })) {
            Button("Cancel", role: .cancel) { model.pendingWorkflowRun = nil }
            Button("Run Anyway") { model.confirmPendingWorkflowRun() }
        } message: {
            if let requests = model.pendingWorkflowRun, let project = requests.first?.project {
                Text("Queues \(requests.count) node(s) across the whole workflow. \(RunPlan.make(project: project, targets: requests.map(\.targetID)).summary)\nThis runs the captured graph and settings, even if the editor selection changes.")
            }
        }
        .alert("Queue a batch of takes?", isPresented: Binding(get: { model.pendingTakeBatch != nil }, set: { if !$0 { model.pendingTakeBatch = nil } })) {
            Button("Cancel", role: .cancel) { model.pendingTakeBatch = nil }
            Button("Queue Takes") { model.confirmPendingTakeBatch() }
        } message: {
            if let batch = model.pendingTakeBatch, let first = batch.first {
                let target = first.project.nodes.first(where: { $0.id == first.targetID })
                let perTake = target.flatMap { node in
                    node.kind.videoTask.flatMap { VideoCapabilityRegistry.capability(recipeID: node.model, task: $0) }
                        .flatMap { VideoTimeEstimate.seconds(node.video, capability: $0) }
                }
                let total = perTake.map { " Estimated on this Mac: \(VideoTimeEstimate.label($0 * Double(batch.count))) in total." } ?? ""
                Text("\(batch.count) takes of “\(target?.label ?? "this node")”, each with a fresh seed. Every take is kept.\(total) Per take: \(first.plan.summary)\nStop All in the toolbar cancels the rest.")
            }
        }
        .alert("GenStudio", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
        .alert("Project packaged", isPresented: Binding(get: { model.packageOffer != nil }, set: { if !$0 { model.packageOffer = nil } }), presenting: model.packageOffer) { offer in
            Button("Show in Finder") { model.revealInFinder(offer.packageFile) }
            Button("Keep in Library", role: .cancel) {}
            Button("Remove from Library", role: .destructive) { Task { await model.removeFromLibrary(offer.projectID) } }
        } message: { offer in Text(offer.summary) }
    }
}

private struct QueuePopover: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Generation Queue").font(.headline)
                Spacer()
                Text("Drag to reorder").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(Array(model.queuedRuns.enumerated()), id: \.element.id) { index, request in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.project.nodes.first(where: { $0.id == request.targetID })?.label ?? "Selected node")
                                .lineLimit(1)
                            Text(request.project.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(request.plan.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .onMove(perform: model.moveQueuedRuns)
            }
            .listStyle(.inset)
            Text("Queued runs use the workflow snapshot captured when they were added.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 360, height: min(CGFloat(180 + model.queuedRuns.count * 72), 480))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Generation queue. Drag queued runs to reorder them.")
    }
}

struct AddNodePicker: View {
    @ObservedObject var model: StudioModel
    var position: CanvasPoint? = nil
    var addNode: ((NodeKind) -> Void)? = nil
    let dismiss: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    var matches: [NodeKind] { NodeKind.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.category.localizedCaseInsensitiveContains(search) } }
    private func availability(_ kind: NodeKind) -> VideoPreflight.Availability { VideoPreflight.availability(kind, installed: model.libraryStore.installed) }
    /// Runnable and model-dependent kinds by category, then a separate section for modes with no adapter.
    private var sections: [(String, [NodeKind])] {
        let available = NodeKind.categoryOrder.map { category in (category, matches.filter { $0.category == category && availability($0) != .unavailable }) }
        return (available + [("Unavailable adapters (authoring only)", matches.filter { availability($0) == .unavailable })]).filter { !$0.1.isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading) {
            TextField("Search nodes", text: $search)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onSubmit { if let kind = matches.first { add(kind) } }
            if matches.isEmpty {
                ContentUnavailableView.search(text: search).frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections, id: \.0) { section in
                        Section(section.0) {
                            ForEach(section.1, id: \.self) { kind in
                                Button { add(kind) } label: {
                                    HStack {
                                        Text(kind.title)
                                        Spacer()
                                        NodeAvailabilityBadge(status: availability(kind))
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(12).frame(width: 300, height: 420)
        .accessibilityLabel("Searchable node picker")
        .task { searchFocused = true }
        .onExitCommand(perform: dismiss)
    }
    private func add(_ kind: NodeKind) {
        if let addNode { addNode(kind) } else { model.addNode(kind, at: position) }
        dismiss()
    }
}

struct CompatibleNodePicker: View {
    let endpoint: WireEndpoint; let choose: (NodeKind) -> Void; @State private var search = ""
    var matches: [NodeKind] { NodeKind.allCases.filter { kind in let node = StudioNode(kind: kind, label: "", position: .init(x: 0, y: 0)); let ports = endpoint.port.direction == .output ? node.inputPorts : node.outputPorts; return ports.contains(where: { $0.type == endpoint.port.type }) && (search.isEmpty || kind.title.localizedCaseInsensitiveContains(search) || kind.category.localizedCaseInsensitiveContains(search)) } }
    var body: some View { VStack { TextField("Search compatible nodes", text: $search).textFieldStyle(.roundedBorder); List(matches, id: \.self) { kind in Button("\(kind.category) · \(kind.title)") { choose(kind) }.buttonStyle(.plain) } }.padding(12).frame(width: 320, height: 360) }
}

struct StudioSidebar: View {
    @ObservedObject var model: StudioModel
    let isCompact: Bool
    @State private var renameTarget: WorkflowProject?
    @State private var renameText = ""
    @State private var deleteTarget: WorkflowProject?
    @State private var selectingGalleryItems = false
    @State private var selectedOutputIDs: Set<UUID> = []
    @State private var selectedArtifactIDs: Set<UUID> = []
    @State private var confirmingGalleryDeletion = false
    @State private var selectingHistoryItems = false
    @State private var selectedRunIDs: Set<UUID> = []
    @State private var confirmingHistoryDeletion = false
    @State private var confirmingClearHistory = false
    @State private var selectingGalleryMedia = false
    @State private var selectedGalleryMediaIDs: Set<String> = []
    @State private var previewingGalleryMedia: StudioModel.GalleryMediaItem?
    @State private var editingGalleryNameID: String?
    @State private var editingGalleryNameText = ""
    @FocusState private var galleryNameFieldFocused: Bool
    private let galleryColumns = [GridItem(.adaptive(minimum: 96, maximum: 150), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if !isCompact {
                    Text("Library")
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, isCompact ? 8 : 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            libraryTabs

            if model.sidebarSection == .gallery, !model.galleryMediaItems.isEmpty { galleryMediaControls }
            if model.sidebarSection == .history, model.runs.contains(where: { $0.status == .failed || $0.status == .interrupted }) { historyDeleteControls }

            if isCompact {
                compactSidebarContent
            } else {
                expandedSidebarContent
            }
        }
        .alert("Rename Workflow", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Workflow name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let target = renameTarget {
                    do { try model.renameProject(target.id, to: renameText) }
                    catch { model.alertMessage = error.localizedDescription }
                }
                renameTarget = nil
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("Delete “\(deleteTarget?.name ?? "Workflow")”?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete Workflow", role: .destructive) {
                if let target = deleteTarget { Task { await model.deleteProject(target.id) } }
                deleteTarget = nil
            }
        } message: { Text("This removes the workflow document. Generated media and run history will be kept.") }
        .alert("Delete \(gallerySelectionCount) selected item\(gallerySelectionCount == 1 ? "" : "s")?", isPresented: $confirmingGalleryDeletion) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                let outputIDs = selectedOutputIDs
                let artifactIDs = selectedArtifactIDs
                Task {
                    await model.deleteGalleryItems(outputIDs: outputIDs, artifactIDs: artifactIDs)
                    endGallerySelection()
                }
            }
        } message: { Text("This permanently removes the selected content from the gallery. Retained media used by another result is kept, and run history is unchanged.") }
        .sheet(item: $previewingGalleryMedia) { item in
            GeneratedMediaViewer(title: item.name, value: item.value, rename: { newName in
                Task { await model.renameGalleryMedia(item, to: newName) }
            }) { model.exportGalleryMedia([item]) }
        }
        .alert("Delete \(selectedRunIDs.count) selected run\(selectedRunIDs.count == 1 ? "" : "s")?", isPresented: $confirmingHistoryDeletion) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                let ids = selectedRunIDs
                Task {
                    await model.deleteHistoryItems(ids)
                    endHistorySelection()
                }
            }
        } message: { Text("This permanently removes the selected run history. Gallery content and retained media are kept.") }
        .alert("Clear all run history?", isPresented: $confirmingClearHistory) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                let ids = Set(model.runs.map(\.id))
                Task { await model.deleteHistoryItems(ids) }
            }
        } message: { Text("This permanently removes every run-journal entry. Gallery content and retained media are kept.") }
        .onChange(of: model.sidebarSection) { _, section in
            if section != .gallery { endGallerySelection(); endGalleryMediaSelection() }
            if section != .history { endHistorySelection() }
        }
    }

    private var libraryTabs: some View {
        HStack(spacing: isCompact ? 2 : 0) {
            ForEach(StudioModel.SidebarSection.allCases, id: \.self) { section in
                Button {
                    model.sidebarSection = section
                } label: {
                    Group {
                        if isCompact {
                            Image(systemName: section.systemImage)
                        } else {
                            Text(section.rawValue)
                        }
                    }
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background {
                    if model.sidebarSection == section {
                        RoundedRectangle(cornerRadius: Radius.xs).fill(.tint.opacity(0.18))
                    }
                }
                .help(section.rawValue)
                .accessibilityLabel(section.rawValue)
            }
        }
        .padding(4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.sm))
        .padding(.horizontal, isCompact ? 8 : 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var compactSidebarContent: some View {
        // Compact mode keeps the icon-only tab strip, but must not replace the
        // selected tab's content with a placeholder. Users still need to see
        // workspaces, installed models, generated media, and failures here.
        expandedSidebarContent
    }

    @ViewBuilder private var expandedSidebarContent: some View {
        List {
                switch model.sidebarSection {
                case .projects:
                    Section("Workflows") {
                        ForEach(model.projects) { project in
                            Button { model.selectProject(project.id) } label: {
                                Label(project.name, systemImage: project.id == model.currentProjectID ? "point.3.connected.trianglepath.dotted" : "square.grid.2x2")
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Open") { model.selectProject(project.id) }
                                Button("Rename…") { renameText = project.name; renameTarget = project }
                                Button("Duplicate") { model.duplicateProject(project.id) }
                                Button("Export Shareable Flow…") { model.exportFlow(project.id) }
                                Button("Export Backup…") { model.exportProject(project.id) }
                                Button("Package Project…") { model.packageProject(project.id) }
                                    .disabled(model.isPackaging)
                                Button("Set Project Folder…") { model.chooseProjectFolder(for: project.id) }
                                if let folder = project.homeFolder { Button("Show Project Folder in Finder") { model.revealInFinder(URL(fileURLWithPath: folder)) } }
                                Divider()
                                Button("Delete…", role: .destructive) { deleteTarget = project }
                                    .disabled(model.isRunning)
                            }
                            .disabled(model.deletingProjectIDs.contains(project.id))
                        }
                    }
                case .models:
                    Section("This Mac") {
                        ThisMacCard(store: model.libraryStore)
                    }
                    Section("Model Storage") {
                        HStack(spacing: 10) {
                            Image(systemName: "internaldrive.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ModelLibraryViewModel.bytes(model.libraryStore.modelStorageBytes))
                                    .font(.headline.monospacedDigit())
                                Text("Used by GenStudio models")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Installed: \(ModelLibraryViewModel.bytes(model.libraryStore.installedStorageBytes))")
                            if model.libraryStore.partialDownloadBytes > 0 {
                                Text("Unfinished downloads: \(ModelLibraryViewModel.bytes(model.libraryStore.partialDownloadBytes))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ModelAdviceSection(model: model)
                case .gallery:
                    Section("Generated images and videos") {
                        if model.galleryMediaItems.isEmpty {
                            Text("No retained generated media yet").foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: galleryColumns, alignment: .leading, spacing: 16) {
                                ForEach(model.galleryMediaItems) { item in galleryTile(item) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    Section("Generated text") {
                        if model.outputs.isEmpty { Text("No text generations yet").foregroundStyle(.secondary) }
                        ForEach(model.outputs) { output in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(output.text).lineLimit(4).textSelection(.enabled)
                                Text("\(output.model) · \(output.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                                Button("Download text…") { model.exportOutput(output) }.font(.caption)
                            }.padding(.vertical, 4)
                        }
                    }
                case .history:
                    Section("Failed generations") {
                        let failures = model.runs.filter { $0.status == .failed || $0.status == .interrupted }
                        if failures.isEmpty { Text("No failed generations").foregroundStyle(.secondary) }
                        ForEach(failures) { run in
                            if selectingHistoryItems {
                                Button { toggleRun(run.id) } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        selectionIndicator(selectedRunIDs.contains(run.id))
                                        runSummary(run)
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 3)
                            } else {
                                HStack(spacing: 8) {
                                    Button { model.openRun(run) } label: { runSummary(run) }
                                        .buttonStyle(.plain)
                                    Spacer()
                                    Button("Retry", systemImage: "arrow.clockwise") { model.retryRuns([run.id]) }
                                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Retry this generation")
                                }
                            }
                        }
                    }
                }
            }
        .listStyle(.sidebar)
        HStack {
            Button("New Workflow", systemImage: "plus") { model.createProject() }
            Button("New Video Ad", systemImage: "film.stack") { model.createLocalVideoAdWorkflow() }
                .help("A 15-second vertical video ad: three stills, each animated, joined and exported at 1080×1920.")
            Menu("Import", systemImage: "square.and.arrow.down") {
                Button("Import Flow…") { model.importFlowFile() }
                Button("Paste Flow from Clipboard") { model.importFlowFromClipboard() }
                Divider()
                Button("Copy AI Briefing") { model.copyAIBriefing() }
            }.menuStyle(.borderlessButton).fixedSize()
        }.padding(10)
    }

    @ViewBuilder private var galleryDeleteControls: some View {
        HStack(spacing: 8) {
            if selectingGalleryItems {
                Button(allGalleryItemsSelected ? "Deselect All" : "Select All") { toggleAllGalleryItems() }
                    .disabled(!model.deletingGalleryItemIDs.isEmpty)
                Spacer()
                Text("\(gallerySelectionCount) selected").font(.caption).foregroundStyle(.secondary)
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingGalleryDeletion = true }
                    .disabled(gallerySelectionCount == 0 || !model.deletingGalleryItemIDs.isEmpty)
                Button("Cancel") { endGallerySelection() }
            } else {
                Spacer()
                Button("Delete…", systemImage: "trash") { selectingGalleryItems = true }
                    .disabled(!model.deletingGalleryItemIDs.isEmpty)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var galleryMediaControls: some View {
        HStack(spacing: 8) {
            if selectingGalleryMedia {
                Button(selectedGalleryMediaIDs.count == model.galleryMediaItems.count ? "Deselect All" : "Select All") {
                    selectedGalleryMediaIDs = selectedGalleryMediaIDs.count == model.galleryMediaItems.count ? [] : Set(model.galleryMediaItems.map(\.id))
                }
                Spacer()
                Text("\(selectedGalleryMediaIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                Button("Download", systemImage: "square.and.arrow.down") {
                    model.exportGalleryMedia(model.galleryMediaItems.filter { selectedGalleryMediaIDs.contains($0.id) })
                }.disabled(selectedGalleryMediaIDs.isEmpty)
                Button("Cancel") { endGalleryMediaSelection() }
            } else {
                Spacer()
                Button("Download…", systemImage: "square.and.arrow.down") { selectingGalleryMedia = true }
            }
        }
        .buttonStyle(.borderless).padding(.horizontal, 10).padding(.bottom, 6)
    }

    @ViewBuilder private var historyDeleteControls: some View {
        HStack(spacing: 8) {
            if selectingHistoryItems {
                Button(allHistoryItemsSelected ? "Deselect All" : "Select All") { toggleAllHistoryItems() }
                    .disabled(model.isRunning || !model.deletingRunIDs.isEmpty)
                Spacer()
                Text("\(selectedRunIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingHistoryDeletion = true }
                    .disabled(selectedRunIDs.isEmpty || model.isRunning || !model.deletingRunIDs.isEmpty)
                Button("Cancel") { endHistorySelection() }
            } else {
                Spacer()
                Button("Retry All", systemImage: "arrow.clockwise") { model.retryRuns(Set(model.runs.filter { $0.status == .failed || $0.status == .interrupted }.map(\.id))) }
                Button("Select…", systemImage: "checkmark.circle") { selectingHistoryItems = true }
                Button("Clear All…", systemImage: "trash", role: .destructive) { confirmingClearHistory = true }
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.isRunning || !model.deletingRunIDs.isEmpty)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func runSummary(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(run.status.rawValue.capitalized)
            Text("\(run.snapshot.model) · \(run.queuedAt.formatted())").font(.caption).foregroundStyle(.secondary)
            if let error = run.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var gallerySelectionCount: Int { selectedOutputIDs.count + selectedArtifactIDs.count }
    private var allGalleryItemsSelected: Bool {
        gallerySelectionCount == model.outputs.count + model.executionArtifacts.count
    }
    private func selectionIndicator(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
    }
    private func toggleOutput(_ id: UUID) {
        if !selectedOutputIDs.insert(id).inserted { selectedOutputIDs.remove(id) }
    }
    private func toggleArtifact(_ id: UUID) {
        if !selectedArtifactIDs.insert(id).inserted { selectedArtifactIDs.remove(id) }
    }
    private func toggleAllGalleryItems() {
        if allGalleryItemsSelected {
            selectedOutputIDs.removeAll(); selectedArtifactIDs.removeAll()
        } else {
            selectedOutputIDs = Set(model.outputs.map(\.id)); selectedArtifactIDs = Set(model.executionArtifacts.map(\.id))
        }
    }
    private func endGallerySelection() {
        selectingGalleryItems = false; selectedOutputIDs.removeAll(); selectedArtifactIDs.removeAll()
    }
    private func endGalleryMediaSelection() { selectingGalleryMedia = false; selectedGalleryMediaIDs.removeAll() }
    private var allHistoryItemsSelected: Bool { selectedRunIDs.count == model.runs.filter { $0.status == .failed || $0.status == .interrupted }.count }
    private func toggleRun(_ id: UUID) {
        if !selectedRunIDs.insert(id).inserted { selectedRunIDs.remove(id) }
    }
    private func toggleAllHistoryItems() {
        selectedRunIDs = allHistoryItemsSelected ? [] : Set(model.runs.filter { $0.status == .failed || $0.status == .interrupted }.map(\.id))
    }
    private func endHistorySelection() {
        selectingHistoryItems = false; selectedRunIDs.removeAll()
    }
    private func toggleGalleryMedia(_ id: String) {
        if !selectedGalleryMediaIDs.insert(id).inserted { selectedGalleryMediaIDs.remove(id) }
    }
    @ViewBuilder private func galleryTile(_ item: StudioModel.GalleryMediaItem) -> some View {
        let selected = selectedGalleryMediaIDs.contains(item.id)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RuntimeValueView(value: item.value, compact: true)
                    .frame(width: 108, height: 108)
                    .clipped()
                    .background(Color.black.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                if selectingGalleryMedia {
                    selectionIndicator(selected)
                        .padding(3)
                        .background(.regularMaterial, in: Circle())
                        .padding(6)
                }
            }
            .contentShape(.rect)
            .onTapGesture {
                if selectingGalleryMedia { toggleGalleryMedia(item.id) }
                else { previewingGalleryMedia = item }
            }
            if editingGalleryNameID == item.id {
                TextField("Name", text: $editingGalleryNameText)
                    .textFieldStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .focused($galleryNameFieldFocused)
                    .onSubmit { commitGalleryRename(item) }
                    .onExitCommand { editingGalleryNameID = nil }
                    .onChange(of: galleryNameFieldFocused) { _, focused in
                        if !focused { commitGalleryRename(item) }
                    }
                    .task { galleryNameFieldFocused = true }
            } else {
                Text(item.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .help("Double-click to rename")
                    .onTapGesture(count: 2) { beginGalleryRename(item) }
            }
            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 108, alignment: .leading)
        .contextMenu {
            Button("Rename…") { beginGalleryRename(item) }
            Button("Download…") { model.exportGalleryMedia([item]) }
        }
    }
    private func beginGalleryRename(_ item: StudioModel.GalleryMediaItem) {
        editingGalleryNameText = item.name
        editingGalleryNameID = item.id
    }
    private func commitGalleryRename(_ item: StudioModel.GalleryMediaItem) {
        guard editingGalleryNameID == item.id else { return }
        let cleaned = editingGalleryNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingGalleryNameID = nil
        guard !cleaned.isEmpty, cleaned != item.name else { return }
        Task { await model.renameGalleryMedia(item, to: cleaned) }
    }
    private func runtimeSummary(_ value: RuntimeValue) -> String { switch value { case .text(let text): text; case .textArray(let items): "\(items.count) text items"; case .number(let number): number.formatted(); case .image(let url): "Image · \(url.lastPathComponent)"; case .video(let url): "Video · \(url.lastPathComponent)"; case .shotSequence(let sequence): "Sequence · \(sequence.anchors.count) frames" } }
}

private extension StudioModel.SidebarSection {
    var systemImage: String {
        switch self {
        case .projects: "square.grid.2x2"
        case .models: "cube"
        case .gallery: "photo.on.rectangle"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct WireEndpoint: Equatable { let nodeID: UUID; let port: PortDescriptor }

/// Lets a trackpad's two-finger scroll pan the stage without competing with
/// node dragging or marquee selection.
private struct CanvasScrollMonitor: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView(onScroll: onScroll) }
    func updateNSView(_ nsView: MonitorView, context: Context) { nsView.onScroll = onScroll }

    final class MonitorView: NSView {
        var onScroll: (CGFloat, CGFloat, Bool) -> Void
        nonisolated(unsafe) private var monitor: Any?
        private var pendingHorizontal: CGFloat = 0
        private var pendingVertical: CGFloat = 0
        private var pendingEnded = false
        private var scrollUpdateScheduled = false

        init(onScroll: @escaping (CGFloat, CGFloat, Bool) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil, window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window,
                          event.window === window,
                          self.convert(event.locationInWindow, from: nil).x >= 0,
                          self.convert(event.locationInWindow, from: nil).y >= 0 else { return event }
                    let point = self.convert(event.locationInWindow, from: nil)
                    guard point.x <= bounds.width, point.y <= bounds.height else { return event }
                    enqueueScroll(horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY,
                                  ended: event.phase == .ended || event.momentumPhase == .ended)
                    return event
                }
            }
        }

        private func enqueueScroll(horizontal: CGFloat, vertical: CGFloat, ended: Bool) {
            pendingHorizontal += horizontal
            pendingVertical += vertical
            pendingEnded = pendingEnded || ended
            guard !scrollUpdateScheduled else { return }
            scrollUpdateScheduled = true

            // A local AppKit event monitor can run while SwiftUI is committing
            // its current view transaction. Publish the accumulated viewport
            // change on the next main-loop turn instead.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let horizontal = pendingHorizontal
                let vertical = pendingVertical
                let ended = pendingEnded
                pendingHorizontal = 0
                pendingVertical = 0
                pendingEnded = false
                scrollUpdateScheduled = false
                guard horizontal != 0 || vertical != 0 || ended else { return }
                onScroll(horizontal, vertical, ended)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// In-flight pan/zoom. It lives outside `CanvasView`'s own state so a gesture
/// sample invalidates only the views that call `ViewportReader`, not the
/// whole stage. Reading `transient` inside `CanvasView.body` would defeat that.
@MainActor @Observable
final class CanvasViewportState {
    var transient: CanvasViewport?
}

/// Reads the live viewport in its own body, so navigation redraws the wire
/// layer and re-transforms the node layer without rebuilding node cards.
private struct ViewportReader<Content: View>: View {
    let state: CanvasViewportState
    let committed: CanvasViewport
    @ViewBuilder let content: (CanvasViewport) -> Content
    var body: some View { content(state.transient ?? committed) }
}

/// Applies the viewport as one transform. Unlike wrapping the node layer in a
/// `ViewportReader`, a modifier's `content` is not re-evaluated when its own
/// body re-runs, so node cards (whose closures SwiftUI cannot compare) are
/// not rebuilt per pan sample.
private struct ViewportTransform: ViewModifier {
    let state: CanvasViewportState
    let committed: CanvasViewport
    func body(content: Content) -> some View {
        let viewport = state.transient ?? committed
        content
            .scaleEffect(viewport.zoom, anchor: .topLeading)
            .offset(x: viewport.offset.x, y: viewport.offset.y)
    }
}

private struct ZoomPercentLabel: View {
    let state: CanvasViewportState
    let committed: CanvasViewport
    var body: some View { Text("⌥-drag: duplicate · ⌘D: duplicate selection · F: frame selection · ⇧F: fit workflow · Space-drag: pan · ⌘K: add node · \(Int((state.transient ?? committed).zoom * 100))%").foregroundStyle(.secondary) }
}

struct CanvasView: View {
    @ObservedObject var model: StudioModel; let project: WorkflowProject
    @FocusState private var canvasFocused: Bool
    @State private var nodeDragStarts: [UUID: CanvasPoint] = [:]; @State private var panStart: CanvasPoint?; @State private var magnifyStart: CanvasViewport?
    @State private var wireStart: WireEndpoint?; @State private var wireEnd: CGPoint?
    @State private var dropRequest: WireEndpoint?; @State private var dropPoint = CGPoint.zero; @State private var showingDropPicker = false
    @State private var selectedEdgeID: UUID?
    @State private var fileDropTargeted = false
    @State private var contextPoint = CGPoint.zero
    @State private var insertionPosition = CanvasPoint(x: 0, y: 0)
    @State private var showingContextPicker = false
    @State private var selectedNodeIDs: Set<UUID> = []
    /// Maps the originally grabbed cards to their Option-drag copies until the
    /// gesture ends. SwiftUI can deliver its final event before rebuilding the
    /// card closures, so both IDs must remain valid for one gesture.
    @State private var dragSourceToCopyIDs: [UUID: UUID] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var marqueeIsAdditive = false
    @State private var spacePressed = false
    @State private var editingNodeText = false
    @State private var renameTargetID: UUID?
    @State private var renameRequest = 0
    @State private var pasteGeneration = 0
    @State private var clipboardRevision = 0
    /// Keep high-frequency viewport motion out of project persistence until
    /// the gesture ends. This avoids a save and full workflow publication per
    /// trackpad sample.
    @State private var viewportState: CanvasViewportState

    init(model: StudioModel, project: WorkflowProject, viewportState: CanvasViewportState = CanvasViewportState()) {
        self.model = model
        self.project = project
        _viewportState = State(initialValue: viewportState)
    }

    /// For event-time use only. `body` must go through `ViewportReader`.
    private var canvasViewport: CanvasViewport { viewportState.transient ?? project.viewport }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75)).contentShape(Rectangle())
                    .onTapGesture { selectedNodeIDs.removeAll(); marqueeStart = nil; marqueeEnd = nil; model.selectedNodeID = nil; selectedEdgeID = nil; canvasFocused = true }
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas")).onChanged { value in
                        guard wireStart == nil, !spacePressed else { return }
                        if marqueeStart == nil {
                            marqueeStart = value.startLocation
                            marqueeIsAdditive = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
                        }
                        marqueeEnd = value.location
                    }.onEnded { value in
                        guard !spacePressed else { return }
                        let rect = selectionRect(from: value.startLocation, to: value.location)
                        let hit = Set(project.nodes.filter { screenRect($0).intersects(rect) }.map(\.id))
                        selectedNodeIDs = marqueeIsAdditive ? selectedNodeIDs.union(hit) : hit
                        model.selectedNodeID = selectedNodeIDs.first
                        marqueeStart = nil; marqueeEnd = nil
                    })
                ViewportReader(state: viewportState, committed: project.viewport) { viewport in
                    Canvas { context, size in
                        drawGrid(context: context, size: size, viewport: viewport)
                        let canvasRect = CGRect(origin: .zero, size: size)
                        let nodesByID = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
                        for edge in project.edges {
                            guard let source = nodesByID[edge.sourceID], let target = nodesByID[edge.targetID],
                                  let a = portPoint(node: source, portID: edge.sourcePortID, direction: .output, viewport: viewport),
                                  let b = portPoint(node: target, portID: edge.targetPortID, direction: .input, viewport: viewport) else { continue }
                            guard wireBounds(from: a, to: b).intersects(canvasRect) else { continue }
                            drawWire(context: context, from: a, to: b, color: wireColor(edge.color, fallback: edge.type), selected: edge.id == selectedEdgeID)
                        }
                        if let start = wireStart, let node = nodesByID[start.nodeID], let a = portPoint(node: node, portID: start.port.id, direction: start.port.direction, viewport: viewport), let b = wireEnd {
                            if start.port.direction == .output { drawWire(context: context, from: a, to: b, color: portColor(start.port.type), selected: false) }
                            else { drawWire(context: context, from: b, to: a, color: portColor(start.port.type), selected: false) }
                        }
                    }
                }.allowsHitTesting(false)
                CanvasScrollMonitor { horizontal, vertical, ended in
                    panCanvasBy(horizontal: horizontal, vertical: vertical, ended: ended)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                if let marqueeStart, let marqueeEnd {
                    let rect = selectionRect(from: marqueeStart, to: marqueeEnd)
                    Rectangle().stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .background(Color.accentColor.opacity(0.12))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                let connectedInputPortIDsByNode = Dictionary(grouping: project.edges, by: \.targetID)
                    .mapValues { Set($0.map(\.targetPortID)) }
                // Cards sit at world positions inside one group; the viewport is a
                // single transform on that group, so a pan never rebuilds a card.
                let nodeLayer = ZStack(alignment: .topLeading) {
                    ForEach(project.nodes) { node in
                        let output = model.displayedValue(for: node)
                        NodeCard(
                            node: node, output: output, progress: model.displayedProgress(for: node),
                            referenceImages: model.referenceImages(for: node),
                            referenceMentions: model.referenceMentions(forPromptNodeID: node.id),
                            modelName: model.modelName(node.model),
                            caption: node.kind == .promptEnhancer ? model.currentProject.map { PromptEnhancer.summary(for: node, in: $0, modelName: model.modelName) } : nil,
                            videoStatus: node.kind.videoTask == nil ? nil : VideoPreflight.availability(node, installed: model.libraryStore.installed),
                            addFrame: node.kind == .shotSequence ? { model.selectedNodeID = node.id; model.addSequenceFrames(nodeID: node.id, imagePaths: [nil]) } : nil,
                            addImageInput: (node.kind == .imageGenerator ? model.canAddImageInput(to: node) : node.kind.supportsDynamicImageInputs || node.kind.supportsDynamicVideoInputs) ? { model.addDynamicInput(to: node.id) } : nil,
                            imageInputHint: model.imageReferenceInputHint(for: node),
                            runModel: node.kind.hidesCanvasRunControl ? nil : { model.selectedNodeID = node.id; model.runSelected() },
                            cancelModel: model.cancelRun, cancelQueuedModel: { model.cancelQueuedRun(node.id) },
                            modelRunning: model.isRunning(node.id), modelQueued: model.isQueued(node.id),
                            exportMedia: model.exportRuntimeValue, takeModel: node.supportsTakes ? model : nil,
                            finalBadge: model.finalBadgeState(for: node),
                            toggleFinal: node.canBeFinalized ? { model.toggleFinal(node.id) } : nil,
                            revealFinal: node.finalized == nil ? nil : { model.revealFinal(node.id) },
                            importImage: node.kind == .imageInput ? { @MainActor [model, nodeID = node.id] url in model.setInputImage(url, for: nodeID) } : node.kind == .videoInput ? { @MainActor [model, nodeID = node.id] url in model.setInputVideo(url, for: nodeID) } : nil,
                            importType: node.kind == .videoInput ? .movie : .image,
                            selected: selectedNodeIDs.contains(node.id) || node.id == model.selectedNodeID,
                            activeWire: wireStart, connectedInputPortIDs: connectedInputPortIDsByNode[node.id] ?? [],
                            promptText: model.promptBinding(for: node), renameRequest: renameTargetID == node.id ? renameRequest : 0,
                            select: { selectNode(node.id) }, rename: { model.renameNode(node.id, to: $0) },
                            duplicate: { model.duplicateNode(node.id); selectedNodeIDs.removeAll(); canvasFocused = true },
                            delete: { model.selectedNodeID = node.id; model.deleteSelected() },
                            beginEditing: { editingNodeText = true; model.selectedNodeID = node.id; selectedEdgeID = nil; wireStart = nil; wireEnd = nil },
                            finishEditing: { returnFocus in editingNodeText = false; if returnFocus { DispatchQueue.main.async { canvasFocused = true } } },
                            move: { translation, ended in move(node, translation: translation, ended: ended) },
                            wire: { port, location, ended, dragged in self.wire(node, port: port, location: location, ended: ended, dragged: dragged) }
                        )
                            .frame(width: NodeLayout.cardWidth(node), height: cardHeight(node, output: output))
                            .offset(x: node.position.x, y: node.position.y)
                            .onTapGesture { if node.kind != .prompt { selectNode(node.id) } }
                    }
                }
                nodeLayer.modifier(ViewportTransform(state: viewportState, committed: project.viewport))
                if let request = dropRequest {
                    Color.clear.frame(width: 1, height: 1).offset(x: dropPoint.x, y: dropPoint.y).popover(isPresented: $showingDropPicker, arrowEdge: .top) {
                        CompatibleNodePicker(endpoint: request) { kind in
                            let position = CanvasPoint(x: (dropPoint.x - canvasViewport.offset.x) / canvasViewport.zoom, y: (dropPoint.y - canvasViewport.offset.y) / canvasViewport.zoom)
                            model.addAndConnect(kind, at: position, endpointNodeID: request.nodeID, endpointPort: request.port); showingDropPicker = false; dropRequest = nil
                        }
                    }
                }
                Color.clear.frame(width: 1, height: 1)
                    .offset(x: contextPoint.x, y: contextPoint.y)
                    .popover(isPresented: $showingContextPicker, arrowEdge: .top) {
                        AddNodePicker(model: model, position: insertionPosition, addNode: { kind in
                            addContextNode(kind, fallbackPosition: insertionPosition, projectID: project.id)
                        }) { showingContextPicker = false }
                    }
                if project.nodes.isEmpty { VStack(spacing: 12) { Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 38)).foregroundStyle(.mint); Text("Build your first local workflow").font(.title2.bold()); Text("Add a node, then drag between labelled typed sockets.").foregroundStyle(.secondary); HStack { Button("Start with Prompt") { model.addNode(.prompt) }; Button("Start Video Ad") { model.createLocalVideoAdWorkflow() }.buttonStyle(.borderedProminent).help("A 15-second vertical video ad: three FLUX.2 Klein 9B stills, each animated by your chosen video model, joined and exported at 1080×1920."); Button("Advert Animatic") { model.createShortAdvertWorkflow() }.help("Creates a local-first advert scaffold with character, portrait, scene, reference briefing, hero still and deterministic animatic nodes.") } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                if spacePressed {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { value in
                            panCanvas(translation: value.translation, ended: false)
                        }.onEnded { value in
                            panCanvas(translation: value.translation, ended: true)
                        })
                        .accessibilityHidden(true)
                }
            }.frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .clipped()
                .overlay {
                    if fileDropTargeted {
                        Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                            .background(Color.accentColor.opacity(0.06))
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "canvas")
                // Files dragged from Finder become Image/Video Input nodes where
                // they land. Input cards handle their own drops to replace media.
                .onDrop(of: [.fileURL], isTargeted: $fileDropTargeted) { providers, location in
                    let viewport = canvasViewport
                    let position = CanvasPoint(x: (location.x - viewport.offset.x) / viewport.zoom, y: (location.y - viewport.offset.y) / viewport.zoom)
                    DroppedMedia.loadFileURLs(from: providers) { urls in
                        let ids = model.importDroppedMedia(urls, at: position)
                        if !ids.isEmpty { selectedNodeIDs = Set(ids); selectedEdgeID = nil; canvasFocused = true }
                    }
                    return true
                }
                .focusable()
                .focusEffectDisabled()
                .focused($canvasFocused)
                .focusedValue(\.canvasCommandActions, commandActions(canvasSize: proxy.size))
                .onKeyPress("f", phases: .down) { press in
                    guard canvasAcceptsKeys,
                          press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                    if press.modifiers.contains(.shift) {
                        fitWorkflow(canvasSize: proxy.size)
                    } else {
                        frameSelection(canvasSize: proxy.size)
                    }
                    return .handled
                }
                .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { press in
                    guard canvasAcceptsKeys, press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                    return deleteSelection() ? .handled : .ignored
                }
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    guard canvasAcceptsKeys, press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                    selectAdjacentNode(backwards: press.modifiers.contains(.shift), canvasSize: proxy.size)
                    return .handled
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    guard canvasAcceptsKeys, press.modifiers.intersection([.command, .control, .option]).isEmpty, !activeSelectedNodeIDs.isEmpty else { return .ignored }
                    let distance = press.modifiers.contains(.shift) ? 10.0 : 1.0
                    let delta: CanvasPoint = switch press.key {
                    case .leftArrow: .init(x: -distance, y: 0)
                    case .rightArrow: .init(x: distance, y: 0)
                    case .upArrow: .init(x: 0, y: -distance)
                    case .downArrow: .init(x: 0, y: distance)
                    default: .init(x: 0, y: 0)
                    }
                    model.nudgeNodes(activeSelectedNodeIDs, by: delta)
                    return .handled
                }
                .onKeyPress(keys: [.space], phases: [.down, .up]) { press in
                    guard canvasAcceptsKeys else { return .ignored }
                    spacePressed = press.phase != .up
                    if press.phase == .up { panStart = nil }
                    return .handled
                }
                .onDeleteCommand {
                    guard canvasAcceptsKeys else { return }
                    _ = deleteSelection()
                }
                .onCommand(#selector(NSText.selectAll(_:)), perform: canvasAcceptsKeys && !project.nodes.isEmpty ? { selectAllNodes() } : nil)
                .onCommand(#selector(NSText.copy(_:)), perform: canvasAcceptsKeys && !activeSelectedNodeIDs.isEmpty ? { copySelection() } : nil)
                .onCommand(#selector(NSText.cut(_:)), perform: canvasAcceptsKeys && !activeSelectedNodeIDs.isEmpty ? { cutSelection() } : nil)
                .onCommand(#selector(NSText.paste(_:)), perform: canvasAcceptsKeys ? { pasteSelection(canvasSize: proxy.size) } : nil)
                .onExitCommand { handleEscape() }
                .overlay(CanvasContextMenu(makeMenu: { contextMenu(at: $0) }, deleteSelectedNode: {
                    guard canvasAcceptsKeys else { return false }
                    return deleteSelection()
                }, excludedRects: { promptEditorRects }).frame(width: proxy.size.width, height: proxy.size.height))
                .onChange(of: showingDropPicker) { _, shown in if !shown { dropRequest = nil } }
                .onChange(of: selectedNodeIDs) { _, ids in model.multiSelectedNodeIDs = ids }
                .onChange(of: model.selectedNodeID) { _, selected in
                    if let selected, !selectedNodeIDs.contains(selected) { selectedNodeIDs = [selected] }
                    else if selected == nil, selectedEdgeID == nil { selectedNodeIDs.removeAll() }
                }
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("canvas")).onEnded { handleCanvasTap(at: $0.location) })
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    let start = magnifyStart ?? canvasViewport
                    if magnifyStart == nil { magnifyStart = start }
                    let anchor = CanvasPoint(x: value.startAnchor.x * proxy.size.width, y: value.startAnchor.y * proxy.size.height)
                    let viewport = CanvasInteraction.zoomedViewport(start, to: start.zoom * value.magnification, anchor: anchor)
                    viewportState.transient = viewport
                }.onEnded { _ in
                    magnifyStart = nil
                    commitTransientViewport()
                })
                .onDisappear { commitTransientViewport(); spacePressed = false; panStart = nil; magnifyStart = nil }
                .overlay(alignment: .bottomLeading) { HStack { Button("Fit View", systemImage: "arrow.up.left.and.arrow.down.right") { fitWorkflow(canvasSize: proxy.size) }.help("Fit the entire workflow (⇧F)"); Button("Organise Nodes", systemImage: "rectangle.3.group") { organiseNodes() }.disabled(project.nodes.isEmpty).help("Tidy flows into rows and columns. Select nodes first to tidy only those. Undo restores the previous layout.").keyboardShortcut("l", modifiers: [.command, .shift]); if let selectedEdgeID { Button("Disconnect Wire", systemImage: "link.badge.plus") { model.disconnect(edgeID: selectedEdgeID); self.selectedEdgeID = nil } }; ZoomPercentLabel(state: viewportState, committed: project.viewport) }.font(.caption).padding(10) }
                .overlay(alignment: .topTrailing) {
                    if wireStart != nil {
                        Label("Wire active · choose a compatible port · Esc to cancel", systemImage: "link")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.accentColor.opacity(0.65), lineWidth: 1))
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
    private var canvasAcceptsKeys: Bool {
        !editingNodeText && !showingContextPicker && !showingDropPicker && focusedEditableTextView() == nil
    }
    private var activeSelectedNodeIDs: Set<UUID> {
        let existing = Set(project.nodes.map(\.id))
        let local = selectedNodeIDs.intersection(existing)
        if !local.isEmpty { return local }
        if let selected = model.selectedNodeID, existing.contains(selected) { return [selected] }
        return []
    }
    private var nodePasteboardType: NSPasteboard.PasteboardType { .init("studio.gen.GenStudio.workflow-nodes") }
    private var canPasteNodes: Bool {
        _ = clipboardRevision
        // Evaluated for every menu-command refresh, so avoid decoding the payload.
        return NSPasteboard.general.types?.contains(nodePasteboardType) == true
    }
    private func commandActions(canvasSize: CGSize) -> CanvasCommandActions {
        CanvasCommandActions(
            acceptsCanvasKeys: canvasAcceptsKeys,
            hasNodes: !project.nodes.isEmpty,
            hasSelection: !activeSelectedNodeIDs.isEmpty || selectedEdgeID != nil,
            canPaste: canPasteNodes,
            frameSelection: { frameSelection(canvasSize: canvasSize) },
            fitWorkflow: { fitWorkflow(canvasSize: canvasSize) },
            zoomIn: { zoom(by: 1.2, canvasSize: canvasSize) },
            zoomOut: { zoom(by: 1 / 1.2, canvasSize: canvasSize) },
            actualSize: { setZoom(1, canvasSize: canvasSize) },
            searchNodes: { showNodeSearch(canvasSize: canvasSize) },
            selectAll: selectAllNodes,
            renameSelection: requestRename,
            duplicateSelection: duplicateSelection,
            deleteSelection: { _ = deleteSelection() },
            copySelection: copySelection,
            cutSelection: cutSelection,
            pasteSelection: { pasteSelection(canvasSize: canvasSize) },
            pasteInPlace: { pasteSelection(canvasSize: canvasSize, inPlace: true) },
            pasteAndReconnect: { pasteSelection(canvasSize: canvasSize, reconnect: true) },
            deselectAll: deselectAll,
            invertSelection: invertSelection,
            selectUpstream: { selectRelated { CanvasSelection.upstream(of: $0, edges: $1.edges) } },
            selectDownstream: { selectRelated { CanvasSelection.downstream(of: $0, edges: $1.edges) } },
            selectConnected: { selectRelated { CanvasSelection.connected(to: $0, edges: $1.edges) } },
            selectSameKind: { selectRelated { CanvasSelection.sameKind(as: $0, nodes: $1.nodes) } },
            align: { alignment in model.alignNodes(activeSelectedNodeIDs, alignment) },
            distribute: { axis in model.distributeNodes(activeSelectedNodeIDs, axis) },
            selectionCount: activeSelectedNodeIDs.count
        )
    }
    private func worldRect(_ node: StudioNode) -> CGRect {
        CGRect(
            x: node.position.x - NodeLayout.leadingOverflow(node),
            y: node.position.y,
            width: NodeLayout.leadingOverflow(node) + NodeLayout.cardWidth(node) + NodeLayout.trailingOverflow(node),
            height: cardHeight(node, output: model.displayedValue(for: node))
        )
    }
    private func frameSelection(canvasSize: CGSize) {
        let ids = activeSelectedNodeIDs
        guard !ids.isEmpty else { fitWorkflow(canvasSize: canvasSize); return }
        let nodes = project.nodes.filter { ids.contains($0.id) }
        let viewport = CanvasInteraction.fittedViewport(
            bounds: nodes.map(worldRect),
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            padding: 48,
            maximumZoom: CanvasInteraction.maximumZoom
        )
        setViewport(viewport)
    }
    private func fitWorkflow(canvasSize: CGSize) {
        guard !project.nodes.isEmpty else { return }
        let viewport = CanvasInteraction.fittedViewport(
            bounds: project.nodes.map(worldRect),
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            padding: 48,
            minimumZoom: CanvasInteraction.fitMinimumZoom
        )
        setViewport(viewport)
    }
    private func setViewport(_ viewport: CanvasViewport) {
        viewportState.transient = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            model.mutateProject { $0.viewport = viewport }
        }
    }
    private func zoomAnchor(canvasSize: CGSize) -> CanvasPoint {
        if let node = project.nodes.first(where: { activeSelectedNodeIDs.contains($0.id) }) {
            let rect = screenRect(node)
            let canvas = CGRect(origin: .zero, size: canvasSize)
            if rect.intersects(canvas) { return .init(x: rect.midX, y: rect.midY) }
        }
        return .init(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }
    private func zoom(by factor: Double, canvasSize: CGSize) {
        setZoom(canvasViewport.zoom * factor, canvasSize: canvasSize)
    }
    private func setZoom(_ zoom: Double, canvasSize: CGSize) {
        setViewport(CanvasInteraction.zoomedViewport(canvasViewport, to: zoom, anchor: zoomAnchor(canvasSize: canvasSize)))
    }
    private func commitTransientViewport() {
        guard let viewport = viewportState.transient else { return }
        viewportState.transient = nil
        model.mutateProject { $0.viewport = viewport }
    }
    private func panCanvas(translation: CGSize, ended: Bool) {
        let origin = panStart ?? canvasViewport.offset
        if panStart == nil { panStart = origin }
        viewportState.transient = .init(offset: .init(x: origin.x + translation.width, y: origin.y + translation.height), zoom: canvasViewport.zoom)
        if ended { panStart = nil; commitTransientViewport() }
    }
    private func panCanvasBy(horizontal: CGFloat, vertical: CGFloat, ended: Bool) {
        viewportState.transient = .init(
            offset: .init(x: canvasViewport.offset.x + horizontal, y: canvasViewport.offset.y + vertical),
            zoom: canvasViewport.zoom
        )
        if ended { commitTransientViewport() }
    }
    private func showNodeSearch(canvasSize: CGSize) {
        guard canvasAcceptsKeys else { return }
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        contextPoint = center
        insertionPosition = .init(
            x: (center.x - canvasViewport.offset.x) / canvasViewport.zoom,
            y: (center.y - canvasViewport.offset.y) / canvasViewport.zoom
        )
        wireStart = nil; wireEnd = nil; dropRequest = nil; showingDropPicker = false
        showingContextPicker = true
    }
    private func selectAllNodes() {
        guard canvasAcceptsKeys, let first = project.nodes.first else { return }
        selectedNodeIDs = Set(project.nodes.map(\.id))
        model.selectedNodeID = first.id
        selectedEdgeID = nil
    }
    private func selectAdjacentNode(backwards: Bool, canvasSize: CGSize) {
        let order = CanvasInteraction.navigationOrder(nodes: project.nodes, edges: project.edges)
        guard !order.isEmpty else { return }
        let selected = model.selectedNodeID.flatMap { order.firstIndex(of: $0) }
        let index: Int
        if let selected {
            index = backwards ? (selected - 1 + order.count) % order.count : (selected + 1) % order.count
        } else {
            index = backwards ? order.count - 1 : 0
        }
        let id = order[index]
        selectedNodeIDs = [id]
        model.selectedNodeID = id
        selectedEdgeID = nil
        revealNode(id, canvasSize: canvasSize)
    }
    private func revealNode(_ id: UUID, canvasSize: CGSize) {
        guard let node = project.nodes.first(where: { $0.id == id }) else { return }
        let rect = screenRect(node)
        let margin = 32.0
        var horizontal = 0.0, vertical = 0.0
        if rect.minX < margin { horizontal = margin - rect.minX }
        else if rect.maxX > canvasSize.width - margin { horizontal = canvasSize.width - margin - rect.maxX }
        if rect.minY < margin { vertical = margin - rect.minY }
        else if rect.maxY > canvasSize.height - margin { vertical = canvasSize.height - margin - rect.maxY }
        guard horizontal != 0 || vertical != 0 else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            setViewport(.init(offset: .init(x: canvasViewport.offset.x + horizontal, y: canvasViewport.offset.y + vertical), zoom: canvasViewport.zoom))
        }
    }
    private func requestRename() {
        guard canvasAcceptsKeys, let id = model.selectedNodeID else { return }
        renameTargetID = id
        renameRequest += 1
    }
    private func duplicateSelection() {
        guard canvasAcceptsKeys, !activeSelectedNodeIDs.isEmpty else { return }
        selectedNodeIDs = model.duplicateNodes(activeSelectedNodeIDs)
        selectedEdgeID = nil
        canvasFocused = true
    }
    @discardableResult private func deleteSelection() -> Bool {
        if let edgeID = selectedEdgeID {
            model.disconnect(edgeID: edgeID)
            selectedEdgeID = nil
            return true
        }
        let ids = activeSelectedNodeIDs
        guard !ids.isEmpty else { return false }
        model.deleteNodes(ids)
        selectedNodeIDs.removeAll()
        wireStart = nil; wireEnd = nil
        return true
    }
    private func copySelection() {
        let ids = activeSelectedNodeIDs
        guard !ids.isEmpty else { return }
        let payload = WorkflowNodeClipboard(
            nodes: project.nodes.filter { ids.contains($0.id) },
            edges: project.edges.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) },
            generations: model.generations(for: ids),
            externalInputs: project.edges.filter { ids.contains($0.targetID) && !ids.contains($0.sourceID) }
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: nodePasteboardType)
        pasteGeneration = 0
        clipboardRevision += 1
    }
    private func cutSelection() {
        guard canvasAcceptsKeys, !activeSelectedNodeIDs.isEmpty else { return }
        copySelection()
        // Cutting then pasting should land where the nodes were, so the first paste is not cascaded.
        _ = deleteSelection()
    }
    private func deselectAll() {
        guard canvasAcceptsKeys else { return }
        selectedNodeIDs.removeAll(); selectedEdgeID = nil; model.selectedNodeID = nil
    }
    private func invertSelection() {
        guard canvasAcceptsKeys else { return }
        let inverted = CanvasSelection.inverted(activeSelectedNodeIDs, nodes: project.nodes)
        selectedNodeIDs = inverted; selectedEdgeID = nil
        model.selectedNodeID = project.nodes.first { inverted.contains($0.id) }?.id
    }
    private func selectRelated(_ expand: (Set<UUID>, WorkflowProject) -> Set<UUID>) {
        guard canvasAcceptsKeys, !activeSelectedNodeIDs.isEmpty else { return }
        selectedNodeIDs = expand(activeSelectedNodeIDs, project); selectedEdgeID = nil
    }
    private func pasteSelection(canvasSize: CGSize, inPlace: Bool = false, reconnect: Bool = false, at point: CanvasPoint? = nil) {
        guard let data = NSPasteboard.general.data(forType: nodePasteboardType),
              let payload = try? JSONDecoder().decode(WorkflowNodeClipboard.self, from: data),
              !payload.nodes.isEmpty else { return }
        pasteGeneration += 1
        let cascade = Double((pasteGeneration - 1) * 24)
        let center = point ?? CanvasPoint(
            x: (canvasSize.width / 2 - canvasViewport.offset.x) / canvasViewport.zoom + cascade,
            y: (canvasSize.height / 2 - canvasViewport.offset.y) / canvasViewport.zoom + cascade
        )
        // Paste in Place keeps the original coordinates; repeated pastes cascade so copies never hide each other.
        let shifted = payload.nodes.map { node -> StudioNode in
            var copy = node; copy.position.x += inPlace ? cascade : 0; copy.position.y += inPlace ? cascade : 0; return copy
        }
        selectedNodeIDs = model.pasteNodes(shifted, edges: payload.edges, generations: payload.generations ?? [], externalInputs: reconnect ? payload.externalInputs ?? [] : [], centeredAt: center, inPlace: inPlace)
        selectedEdgeID = nil
        canvasFocused = true
    }
    private func handleEscape() {
        if wireStart != nil || showingDropPicker || showingContextPicker {
            wireStart = nil; wireEnd = nil; dropRequest = nil
            showingDropPicker = false; showingContextPicker = false
            return
        }
        if selectedEdgeID != nil || !activeSelectedNodeIDs.isEmpty {
            selectedEdgeID = nil
            selectedNodeIDs.removeAll()
            model.selectedNodeID = nil
        }
    }
    private var promptEditorRects: [CGRect] {
        project.nodes.filter { $0.kind == .prompt || $0.kind == .imagePrompt || $0.kind == .videoPrompt }.map { node in
            CGRect(x: canvasViewport.offset.x + (node.position.x + 12) * canvasViewport.zoom,
                   y: canvasViewport.offset.y + (node.position.y + NodeLayout.previewTop(node)) * canvasViewport.zoom,
                   width: (NodeLayout.cardWidth(node) - 24) * canvasViewport.zoom,
                   height: NodeLayout.previewHeight(node) * canvasViewport.zoom)
        }
    }
    private func organiseNodes() {
        wireStart = nil; wireEnd = nil; dropRequest = nil
        showingDropPicker = false; showingContextPicker = false; selectedEdgeID = nil
        nodeDragStarts = [:]; panStart = nil; magnifyStart = nil
        canvasFocused = true
        model.organiseNodes(limitedTo: selectedNodeIDs)
    }
    private func contextMenu(at point: CGPoint) -> NSMenu {
        let position = CanvasPoint(x: (point.x - canvasViewport.offset.x) / canvasViewport.zoom, y: (point.y - canvasViewport.offset.y) / canvasViewport.zoom)
        let projectID = project.id
        if let hit = portHit(at: point) {
            return portMenu(node: hit.node, port: hit.port, projectID: projectID)
        }
        if let edge = wireHit(at: point) {
            selectedEdgeID = edge.id
            selectedNodeIDs.removeAll()
            model.selectedNodeID = nil
            return wireColorMenu(edge: edge, projectID: projectID)
        }
        let menu = NSMenu()
        let hasSelection = !activeSelectedNodeIDs.isEmpty
        for (title, enabled, action) in [
            ("Cut", hasSelection, { cutSelection() }),
            ("Copy", hasSelection, { copySelection() }),
            ("Paste Here", canPasteNodes, { pasteSelection(canvasSize: .zero, at: position) }),
            ("Duplicate", hasSelection, { duplicateSelection() }),
            ("Delete", hasSelection, { _ = deleteSelection() })
        ] as [(String, Bool, () -> Void)] {
            let item = CanvasMenuAction(title) {
                guard model.currentProjectID == projectID else { return }
                action()
            }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(CanvasMenuAction("Search Nodes…") {
            guard model.currentProjectID == projectID else { return }
            wireStart = nil; wireEnd = nil; showingDropPicker = false; dropRequest = nil
            contextPoint = point; insertionPosition = position; showingContextPicker = true
        })
        let organise = CanvasMenuAction("Organise Nodes") {
            guard model.currentProjectID == projectID else { return }
            organiseNodes()
        }
        organise.isEnabled = !project.nodes.isEmpty
        menu.addItem(organise)
        menu.addItem(.separator())
        for kind in NodeKind.quickAddOrder {
            menu.addItem(CanvasMenuAction(kind.title) {
                guard model.currentProjectID == projectID else { return }
                wireStart = nil; wireEnd = nil
                addContextNode(kind, fallbackPosition: position, projectID: projectID)
            })
        }
        menu.addItem(.separator())
        for category in NodeKind.categoryOrder {
            let item = NSMenuItem(title: category, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: category)
            for kind in NodeKind.allCases.filter({ $0.category == category }) {
                submenu.addItem(CanvasMenuAction(kind.title) {
                    guard model.currentProjectID == projectID else { return }
                    wireStart = nil; wireEnd = nil
                    addContextNode(kind, fallbackPosition: position, projectID: projectID)
                })
            }
            item.submenu = submenu; menu.addItem(item)
        }
        return menu
    }

    /// Uses the single selected node as an attachment point for context-menu
    /// additions. Multiple selections and incompatible kinds retain the
    /// original free-placement behavior at the right-click location.
    private func addContextNode(_ kind: NodeKind, fallbackPosition: CanvasPoint, projectID: UUID) {
        guard model.currentProjectID == projectID else { return }
        if activeSelectedNodeIDs.count == 1,
           let selected = activeSelectedNodeIDs.first,
           let newID = model.addNodeConnectedToSelection(kind, selectedNodeID: selected) {
            selectedNodeIDs = [newID]
        } else {
            model.addNode(kind, at: fallbackPosition)
            if let newID = model.selectedNodeID { selectedNodeIDs = [newID] }
        }
        selectedEdgeID = nil
        canvasFocused = true
    }
    private func wireColorMenu(edge: StudioEdge, projectID: UUID) -> NSMenu {
        let menu = NSMenu(title: "Wire Colour")
        let automatic = CanvasMenuAction("Automatic (\(edge.type.rawValue.capitalized))") {
            guard model.currentProjectID == projectID else { return }
            model.setWireColor(edgeID: edge.id, color: nil)
        }
        automatic.state = edge.color == nil ? .on : .off
        automatic.image = wireSwatch(portColor(edge.type))
        menu.addItem(automatic)
        menu.addItem(.separator())
        for color in WireColor.allCases {
            let item = CanvasMenuAction(color.title) {
                guard model.currentProjectID == projectID else { return }
                model.setWireColor(edgeID: edge.id, color: color)
            }
            item.state = edge.color == color ? .on : .off
            item.image = wireSwatch(wireColor(color, fallback: edge.type))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(CanvasMenuAction("Disconnect Wire") {
            guard model.currentProjectID == projectID else { return }
            model.disconnect(edgeID: edge.id)
            selectedEdgeID = nil
        })
        return menu
    }
    private func cardHeight(_ node: StudioNode, output: RuntimeValue? = nil) -> Double { NodeLayout.cardHeight(node, output: output) }
    private func selectNode(_ nodeID: UUID) {
        let additive = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
        if additive {
            if !selectedNodeIDs.insert(nodeID).inserted { selectedNodeIDs.remove(nodeID) }
        } else {
            selectedNodeIDs = [nodeID]
        }
        model.selectedNodeID = selectedNodeIDs.contains(nodeID) ? nodeID : selectedNodeIDs.first
        selectedEdgeID = nil
        canvasFocused = true
    }
    private func selectionRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    private func portPoint(node: StudioNode, portID: String, direction: PortDirection, viewport: CanvasViewport? = nil) -> CGPoint? {
        let viewport = viewport ?? canvasViewport
        let ports = direction == .input ? node.inputPorts : node.outputPorts; guard let index = ports.firstIndex(where: { $0.id == portID }) else { return nil }
        return .init(x: viewport.offset.x + (node.position.x + NodeLayout.socketX(node, direction: direction)) * viewport.zoom, y: viewport.offset.y + (node.position.y + NodeLayout.socketY(node, index: index)) * viewport.zoom)
    }
    private func drawGrid(context: GraphicsContext, size: CGSize, viewport: CanvasViewport) {
        var spacing = 28 * viewport.zoom
        // Zoomed far out, a 28pt grid becomes thousands of strokes that read as noise.
        while spacing < 8 { spacing *= 2 }
        var grid = Path()
        stride(from: viewport.offset.x.truncatingRemainder(dividingBy: spacing), through: size.width, by: spacing).forEach { grid.move(to: .init(x: $0, y: 0)); grid.addLine(to: .init(x: $0, y: size.height)) }
        stride(from: viewport.offset.y.truncatingRemainder(dividingBy: spacing), through: size.height, by: spacing).forEach { grid.move(to: .init(x: 0, y: $0)); grid.addLine(to: .init(x: size.width, y: $0)) }
        context.stroke(grid, with: .color(.white.opacity(0.045)))
    }
    /// The route's control polygon bounds the curve, so it is a safe cull test.
    private func wireBounds(from: CGPoint, to: CGPoint) -> CGRect {
        let route = CanvasInteraction.wireRoute(from: from, to: to)
        let xs = [route.source.x, route.sourceStub.x, route.control1.x, route.control2.x, route.targetStub.x, route.target.x]
        let ys = [route.source.y, route.target.y, route.control1.y, route.control2.y]
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -8, dy: -8)
    }
    private func drawWire(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color, selected: Bool) {
        let route = CanvasInteraction.wireRoute(from: from, to: to)
        var path = Path()
        path.move(to: route.source)
        path.addLine(to: route.sourceStub)
        path.addCurve(to: route.targetStub, control1: route.control1, control2: route.control2)
        path.addLine(to: route.target)
        if selected { context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 6) }
        context.stroke(path, with: .color(color.opacity(0.95)), lineWidth: selected ? 3 : 2.5)
    }
    private func handleCanvasTap(at location: CGPoint) {
        // Node cards are scaled with the viewport, so their SwiftUI gesture
        // targets become too small to reach in an overview. A tap outside the
        // normal, card-local target is resolved here in screen coordinates.
        // Keeping ordinary socket taps with the card avoids double-delivering
        // the gesture to its DragGesture.
        if let hit = portHit(at: location),
           portHit(at: location, radius: normalSocketHitRadius) == nil {
            wire(hit.node, port: hit.port, location: location, ended: true, dragged: false)
            return
        }
        selectWire(at: location)
    }
    private var normalSocketHitRadius: Double { max(14, 22 * canvasViewport.zoom) }
    private func selectWire(at location: CGPoint) {
        if let edge = wireHit(at: location) {
            selectedEdgeID = edge.id
            selectedNodeIDs.removeAll()
            model.selectedNodeID = nil
            canvasFocused = true
        }
    }
    private func wireHit(at location: CGPoint) -> StudioEdge? {
        guard !project.nodes.contains(where: { screenRect($0).contains(location) }) else { return nil }
        let hits = project.edges.compactMap { edge -> (StudioEdge, Double)? in
            guard let source = project.nodes.first(where: { $0.id == edge.sourceID }), let target = project.nodes.first(where: { $0.id == edge.targetID }), let a = portPoint(node: source, portID: edge.sourcePortID, direction: .output), let b = portPoint(node: target, portID: edge.targetPortID, direction: .input) else { return nil }
            let route = CanvasInteraction.wireRoute(from: a, to: b)
            let curveDistance = (0...24).map { step -> Double in
                let t = Double(step) / 24, u = 1 - t
                let point = CGPoint(
                    x: u*u*u*route.sourceStub.x + 3*u*u*t*route.control1.x + 3*u*t*t*route.control2.x + t*t*t*route.targetStub.x,
                    y: u*u*u*route.sourceStub.y + 3*u*u*t*route.control1.y + 3*u*t*t*route.control2.y + t*t*t*route.targetStub.y
                )
                return distance(point, location)
            }.min() ?? .greatestFiniteMagnitude
            let nearest = min(curveDistance, distanceToSegment(location, route.source, route.sourceStub), distanceToSegment(location, route.targetStub, route.target))
            return (edge, nearest)
        }
        guard let hit = hits.min(by: { $0.1 < $1.1 }), hit.1 <= 12 else { return nil }
        return hit.0
    }
    /// Nearest-socket hit testing is in screen space so it remains usable after
    /// the node layer has been scaled down. The nearest socket wins where
    /// neighbouring enlarged targets overlap.
    private func portHit(at location: CGPoint, radius: Double? = nil) -> (node: StudioNode, port: PortDescriptor)? {
        let sockets = project.nodes.flatMap { candidate in (candidate.inputPorts + candidate.outputPorts).map { (candidate, $0) } }
        guard let hit = sockets.min(by: { distance(portPoint(node: $0.0, portID: $0.1.id, direction: $0.1.direction), location) < distance(portPoint(node: $1.0, portID: $1.1.id, direction: $1.1.direction), location) }),
              distance(portPoint(node: hit.0, portID: hit.1.id, direction: hit.1.direction), location) <= (radius ?? CanvasInteraction.socketHitRadius(for: canvasViewport.zoom)) else { return nil }
        return hit
    }
    private func portMenu(node: StudioNode, port: PortDescriptor, projectID: UUID) -> NSMenu {
        let menu = NSMenu(title: port.label)
        let address = PortAddress(nodeID: node.id, portID: port.id)
        let copy = CanvasMenuAction("Copy Connections") {
            guard model.currentProjectID == projectID else { return }
            model.copyConnections(from: address, direction: port.direction)
        }
        copy.isEnabled = model.hasConnections(at: address, direction: port.direction)
        menu.addItem(copy)
        let paste = CanvasMenuAction("Paste Connections") {
            guard model.currentProjectID == projectID else { return }
            model.pasteConnections(onto: address)
        }
        paste.isEnabled = model.canPasteConnections(onto: address, portType: port.type, direction: port.direction)
        menu.addItem(paste)
        return menu
    }
    private func distanceToSegment(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> Double {
        let dx = end.x - start.x, dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, start) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return distance(point, .init(x: start.x + projection * dx, y: start.y + projection * dy))
    }
    private func move(_ node: StudioNode, translation: CGSize, ended: Bool) {
        canvasFocused = true
        if selectedNodeIDs.isEmpty || !selectedNodeIDs.contains(node.id) { selectedNodeIDs = [node.id] }
        if nodeDragStarts.isEmpty, NSEvent.modifierFlags.contains(.option) {
            let copies = model.duplicateNodesForDrag(selectedNodeIDs)
            guard !copies.isEmpty else { return }
            dragSourceToCopyIDs = copies
            selectedNodeIDs = Set(copies.values)
            for source in project.nodes {
                if let copyID = copies[source.id] { nodeDragStarts[copyID] = source.position }
            }
        }
        let draggedNodeID = dragSourceToCopyIDs[node.id] ?? node.id
        let movingIDs = selectedNodeIDs
        let currentNodes = Dictionary(uniqueKeysWithValues: (model.currentProject?.nodes ?? []).map { ($0.id, $0) })
        var origins: [UUID: CanvasPoint] = [:]
        var positions: [UUID: CanvasPoint] = [:]
        for nodeID in movingIDs {
            guard let current = currentNodes[nodeID] else { continue }
            let origin = nodeDragStarts[nodeID] ?? current.position
            nodeDragStarts[nodeID] = origin
            origins[nodeID] = origin
            positions[nodeID] = CanvasInteraction.translated(origin: origin, horizontal: translation.width, vertical: translation.height, scale: canvasViewport.zoom)
        }
        model.selectedNodeID = draggedNodeID
        model.moveNodes(movingIDs, from: origins, to: positions, ended: ended)
        if ended {
            nodeDragStarts.removeAll()
            dragSourceToCopyIDs.removeAll()
        }
    }
    private func wire(_ node: StudioNode, port: PortDescriptor, location: CGPoint, ended: Bool, dragged: Bool) {
        // A selected wire supplies the opposite endpoint. Selecting an input
        // fans its existing output into that input; selecting an output
        // replaces the selected wire's input source. This is equivalent to
        // arming that endpoint first, but avoids making users re-find it.
        if ended, !dragged, wireStart == nil, let edgeID = selectedEdgeID,
           let selectedEdge = project.edges.first(where: { $0.id == edgeID }),
           connectSelectedWire(selectedEdge, to: (node, port)) {
            return
        }
        if wireStart == nil {
            selectNode(node.id)
            wireStart = .init(nodeID: node.id, port: port)
            canvasFocused = true
        }
        wireEnd = dragged ? location : wireEnd
        guard ended, let start = wireStart else { return }
        // A click on the starting socket arms persistent wiring. Escape is the
        // intentional cancellation gesture; scrolling and unrelated clicks do
        // not discard the endpoint.
        if start.nodeID == node.id && start.port.id == port.id && !dragged {
            wireEnd = nil
            return
        }

        // A destination click names the exact socket, so it does not have to
        // land within a small geometric radius of the visible dot. Drag-release
        // continues to use nearest-socket hit testing below.
        if !dragged, start.nodeID != node.id, start.port.direction != port.direction, start.port.type == port.type {
            let output = start.port.direction == .output ? (start.nodeID, start.port) : (node.id, port)
            let input = start.port.direction == .input ? (start.nodeID, start.port) : (node.id, port)
            model.connect(sourceID: output.0, sourcePortID: output.1.id, targetID: input.0, targetPortID: input.1.id, replacing: true)
            wireStart = nil; wireEnd = nil
            return
        }
        // A click on any other socket is still just a choice attempt. Keep the
        // armed endpoint visible until the user chooses a compatible port or
        // presses Escape; only drag-release follows geometric hit testing.
        if !dragged { return }

        let sockets = project.nodes.flatMap { candidate in (candidate.inputPorts + candidate.outputPorts).map { (candidate, $0) } }
        if let hit = sockets.min(by: { distance(portPoint(node: $0.0, portID: $0.1.id, direction: $0.1.direction), location) < distance(portPoint(node: $1.0, portID: $1.1.id, direction: $1.1.direction), location) }), distance(portPoint(node: hit.0, portID: hit.1.id, direction: hit.1.direction), location) <= max(14, 22 * canvasViewport.zoom) {
            guard hit.0.id != start.nodeID, hit.1.direction != start.port.direction, hit.1.type == start.port.type else { return }
            let output = start.port.direction == .output ? (start.nodeID, start.port) : (hit.0.id, hit.1)
            let input = start.port.direction == .input ? (start.nodeID, start.port) : (hit.0.id, hit.1)
            model.connect(sourceID: output.0, sourcePortID: output.1.id, targetID: input.0, targetPortID: input.1.id, replacing: true)
            wireStart = nil; wireEnd = nil
        } else if let body = project.nodes.first(where: { $0.id != start.nodeID && screenRect($0).contains(location) }) {
            if start.port.direction == .output {
                model.connectToBody(sourceID: start.nodeID, sourcePortID: start.port.id, targetID: body.id)
                wireStart = nil; wireEnd = nil
            } else if let output = body.outputPorts.first(where: { $0.type == start.port.type }) {
                model.connect(sourceID: body.id, sourcePortID: output.id, targetID: start.nodeID, targetPortID: start.port.id)
                wireStart = nil; wireEnd = nil
            }
        } else if !project.nodes.contains(where: { screenRect($0).contains(location) }) {
            dropRequest = start; dropPoint = location; showingDropPicker = true
            wireStart = nil; wireEnd = nil
        }
    }
    @discardableResult
    private func connectSelectedWire(_ edge: StudioEdge, to endpoint: (node: StudioNode, port: PortDescriptor)) -> Bool {
        let node = endpoint.node
        let port = endpoint.port
        guard edge.type == port.type else { return false }
        switch port.direction {
        case .input:
            guard edge.targetID != node.id || edge.targetPortID != port.id else { return false }
            model.connect(sourceID: edge.sourceID, sourcePortID: edge.sourcePortID, targetID: node.id, targetPortID: port.id, replacing: true)
        case .output:
            guard edge.sourceID != node.id || edge.sourcePortID != port.id else { return false }
            model.connect(sourceID: node.id, sourcePortID: port.id, targetID: edge.targetID, targetPortID: edge.targetPortID, replacing: true)
        }
        selectedEdgeID = nil
        wireEnd = nil
        canvasFocused = true
        return true
    }
    private func screenRect(_ node: StudioNode) -> CGRect { .init(x: canvasViewport.offset.x + node.position.x * canvasViewport.zoom, y: canvasViewport.offset.y + node.position.y * canvasViewport.zoom, width: NodeLayout.cardWidth(node) * canvasViewport.zoom, height: cardHeight(node, output: model.displayedValue(for: node)) * canvasViewport.zoom) }
    private func distance(_ point: CGPoint?, _ other: CGPoint) -> Double { guard let point else { return .greatestFiniteMagnitude }; return hypot(point.x - other.x, point.y - other.y) }
}

struct NodeCard: View {
    let node: StudioNode; let output: RuntimeValue?; var progress: NodeExecutionProgress? = nil; var referenceImages: [URL] = []; var referenceMentions: [ReferenceMention] = []; var modelName: String = ""; var caption: String? = nil; var videoStatus: VideoPreflight.Availability? = nil; var addFrame: (() -> Void)? = nil; var addImageInput: (() -> Void)? = nil; var imageInputHint: String? = nil; var addReference: (() -> Void)? = nil; var runModel: (() -> Void)? = nil; var cancelModel: (() -> Void)? = nil; var cancelQueuedModel: (() -> Void)? = nil; var modelRunning = false; var modelQueued = false; var exportMedia: ((RuntimeValue) -> Void)? = nil; var takeModel: StudioModel? = nil; var finalBadge: FinalBadgeState? = nil; var toggleFinal: (() -> Void)? = nil; var revealFinal: (() -> Void)? = nil; var importImage: (@MainActor (URL) -> Void)? = nil; var importType: UTType = .image; let selected: Bool; let activeWire: WireEndpoint?; var connectedInputPortIDs: Set<String> = []; var promptText: Binding<String>? = nil; var renameRequest = 0; var select: () -> Void = {}; var rename: (String) -> Void = { _ in }; var duplicate: () -> Void = {}; var delete: () -> Void = {}; var beginEditing: () -> Void = {}; var finishEditing: (Bool) -> Void = { _ in }; let move: (CGSize, Bool) -> Void; let wire: (PortDescriptor, CGPoint, Bool, Bool) -> Void
    @State private var editingLabel = false
    @State private var labelDraft = ""
    @State private var showingMediaViewer = false
    @State private var dropTargeted = false
    @FocusState private var labelFocused: Bool
    static func chooseImageFile(_ type: UTType = .image, _ importImage: @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(url)
    }
    private func handleImageDrop(_ providers: [NSItemProvider], _ importImage: @escaping @MainActor (URL) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        let type = importType
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL, UTType(filenameExtension: url.pathExtension)?.conforms(to: type) == true else { return }
            Task { @MainActor in importImage(url); select() }
        }
        return true
    }
    private var imageCard: Bool { NodeLayout.isImage(node) }
    private var promptCard: Bool { node.kind == .prompt }
    private var imagePromptCard: Bool { node.kind == .imagePrompt }
    private var videoPromptCard: Bool { node.kind == .videoPrompt }
    private var editablePromptCard: Bool { promptCard || imagePromptCard || videoPromptCard }
    private var promptStyledCard: Bool { promptCard || imagePromptCard || videoPromptCard || node.kind == .promptEnhancer || node.kind == .imageDescriber || node.kind == .characterSheet }
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: promptStyledCard ? NodeLayout.prominentCardCornerRadius : NodeLayout.cardCornerRadius)
                .fill(promptStyledCard ? Surface.cardProminent : imageCard ? Surface.cardImage : Surface.card)
                .overlay(RoundedRectangle(cornerRadius: promptStyledCard ? NodeLayout.prominentCardCornerRadius : NodeLayout.cardCornerRadius).stroke(selected ? Color.white.opacity(0.8) : Color.white.opacity(0.14), lineWidth: selected ? 1.5 : 1))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .onTapGesture { select() }
            HStack(spacing: 7) {
                Image(systemName: promptCard ? "textformat" : imagePromptCard ? "slider.horizontal.3" : videoPromptCard ? "video.and.waveform" : node.kind == .promptEnhancer ? "wand.and.sparkles" : node.kind == .imageDescriber ? "eye" : node.kind == .characterSheet ? "person.crop.rectangle.stack" : imageCard ? "photo" : VideoNodeCardContent.icon(node.kind) ?? "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                if editingLabel {
                    TextField("Node name", text: $labelDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: promptStyledCard ? CanvasType.prominent : CanvasType.body, weight: .medium))
                        .focused($labelFocused)
                        .onSubmit { commitLabel(returnFocus: true) }
                        .onExitCommand { cancelLabel(returnFocus: true) }
                        .onChange(of: labelFocused) { wasFocused, isFocused in
                            if wasFocused && !isFocused && editingLabel { commitLabel(returnFocus: false) }
                        }
                        .accessibilityLabel("Node name")
                } else {
                    Text(node.label)
                        .font(.system(size: promptStyledCard ? CanvasType.prominent : CanvasType.body, weight: .medium))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { startEditingLabel() }
                        .help("Click to rename")
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Show in Inspector") { select() }
                    Button("Duplicate", systemImage: "plus.square.on.square") { duplicate() }
                    if let finalBadge, let toggleFinal {
                        Button(finalBadge == .open ? "Lock as Final" : "Unlock", systemImage: finalBadge == .open ? "lock.fill" : "lock.open.fill", action: toggleFinal)
                        if let revealFinal { Button("Show Saved File in Finder", systemImage: "folder", action: revealFinal) }
                    }
                    if promptCard || imagePromptCard || videoPromptCard {
                        Button("Copy Prompt") {
                            NSPasteboard.general.clearContents()
                            let text = imagePromptCard ? (node.imagePromptSettings?.compiledPrompt ?? "") : videoPromptCard ? (node.videoPromptSettings?.compiledPrompt ?? "") : (promptText?.wrappedValue ?? node.prompt)
                            NSPasteboard.general.setString(text, forType: .string)
                        }.disabled((imagePromptCard ? (node.imagePromptSettings?.compiledPrompt ?? "") : videoPromptCard ? (node.videoPromptSettings?.compiledPrompt ?? "") : (promptText?.wrappedValue ?? node.prompt)).isEmpty)
                    }
                    Divider()
                    Button("Delete Node", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Actions for \(node.label)")
            }.padding(.horizontal, promptStyledCard ? NodeLayout.promptInset : NodeLayout.bodyInset).frame(height: promptStyledCard ? NodeLayout.prominentHeaderHeight : NodeLayout.compactHeaderHeight)
                .contentShape(Rectangle())
                .onTapGesture { select() }
                .gesture(DragGesture(coordinateSpace: .named("canvas")).onChanged { value in
                    if !editingLabel { move(value.translation, false) }
                }.onEnded { value in
                    if !editingLabel { move(value.translation, true) }
                })
                .accessibilityLabel("Move \(node.label)")
            if editablePromptCard {
                PromptNodeEditor(
                    text: promptText ?? .constant(node.prompt),
                    nodeID: node.id,
                    placeholder: editorPlaceholder,
                    accessibilityLabel: editorAccessibilityLabel,
                    referenceMentions: referenceMentions,
                    beginEditing: beginEditing,
                    finishEditing: finishEditing
                )
                    .disabled(node.isLockedFinal)
                    .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, height: NodeLayout.previewHeight(node, output: output))
                    .offset(x: NodeLayout.bodyInset, y: NodeLayout.previewTop(node))
                HStack {
                    Text(promptEditorFooter)
                        .font(.system(size: CanvasType.label)).foregroundStyle(.secondary)
                        .contentShape(Rectangle()).onTapGesture { select() }
                    Spacer()
                    if let runModel {
                        modelButton(runModel)
                            .buttonStyle(.bordered)
                            .font(.system(size: CanvasType.label))
                    }
                }
                    .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, height: NodeLayout.actionRowHeight, alignment: .leading)
                    .offset(x: NodeLayout.bodyInset, y: NodeLayout.cardHeight(node) - NodeLayout.footerOffset)
            } else {
                // The import target sits under the preview: the preview passes clicks
                // through, except on a clip's play button.
                if let importImage {
                    Color.clear.contentShape(Rectangle())
                        .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, height: NodeLayout.previewHeight(node, output: output))
                        .offset(x: NodeLayout.bodyInset, y: NodeLayout.previewTop(node))
                        .onTapGesture { select(); Self.chooseImageFile(importType, importImage) }
                        .help(importType == .movie ? "Click to choose a video, or drop one here" : "Click to choose an image, or drop one here")
                        .accessibilityLabel("Choose \(importType == .movie ? "video" : "image") for \(node.label)")
                        .accessibilityAddTraits(.isButton)
                }
                NodeCardPreview(node: node, output: output, referenceImages: referenceImages, modelName: modelName, caption: caption, videoStatus: videoStatus)
                    .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, height: NodeLayout.previewHeight(node, output: output), alignment: .topLeading)
                    .clipped().offset(x: NodeLayout.bodyInset, y: NodeLayout.previewTop(node))
                    .allowsHitTesting(node.kind == .promptEnhancer || node.kind == .imageDescriber || NodeCardPreview.videoURL(node: node, output: output) != nil)
                if selected, let mediaOutput {
                    HStack(spacing: 5) {
                        Button { showingMediaViewer = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .help("Expand generation")
                            .accessibilityLabel("Expand \(node.label) generation")
                        Button { exportMedia?(mediaOutput) } label: { Image(systemName: "square.and.arrow.down") }
                            .help("Download generation")
                            .accessibilityLabel("Download \(node.label) generation")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .padding(6)
                    .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, alignment: .trailing)
                    .offset(x: NodeLayout.bodyInset, y: NodeLayout.previewTop(node))
                }
            }
            if let takeModel {
                GenerationTakeControls(model: takeModel, node: node, compact: true, addReference: addReference)
                    .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, height: NodeLayout.actionRowHeight, alignment: .leading)
                    .offset(x: NodeLayout.bodyInset, y: NodeLayout.cardHeight(node, output: output) - NodeLayout.footerOffset)
            } else if let runModel, !editablePromptCard {
                runModelRow(runModel)
                    .offset(x: NodeLayout.bodyInset, y: NodeLayout.cardHeight(node, output: output) - NodeLayout.footerOffset)
            }
            if let finalBadge, let toggleFinal {
                FinalBadge(state: finalBadge, base: promptStyledCard ? Surface.cardProminent : imageCard ? Surface.cardImage : Surface.card, nodeName: node.label, action: toggleFinal)
                    .offset(x: NodeLayout.cardWidth(node) / 2 - FinalBadge.diameter / 2,
                            y: NodeLayout.previewTop(node) + NodeLayout.previewHeight(node, output: output) - FinalBadge.diameter / 2)
            }
            if let addFrame {
                Button("Add Frame", systemImage: "plus", action: addFrame).font(.caption).buttonStyle(.borderless)
                    .offset(x: NodeLayout.cardWidth(node) - 100, y: 46)
            }
            if let progress, node.kind == .textModel || node.kind == .promptEnhancer || node.kind == .imageDescriber || node.kind == .imageGenerator || node.kind == .textPreview || node.kind == .imagePreview || node.kind == .videoPreview || VideoNodeCardContent.handles(node.kind) {
                // Over finished media the bar would cover the result: a completed run
                // becomes a small pill in the corner, and a live or failed one moves to
                // the bottom edge.
                let overMedia = showsMediaResult
                let compact = overMedia && progress.status == .completed
                NodeProgressBar(progress: progress, compact: compact)
                    .padding(overMedia ? 6 : 0)
                    .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, height: NodeLayout.previewHeight(node, output: output), alignment: compact ? .topLeading : overMedia ? .bottom : .center)
                    .offset(x: NodeLayout.bodyInset, y: NodeLayout.previewTop(node))
                    .allowsHitTesting(false)
            }
            ForEach(Array(node.inputPorts.enumerated()), id: \.element.id) { index, port in socket(port, index: index) }
            ForEach(Array(node.outputPorts.enumerated()), id: \.element.id) { index, port in socket(port, index: index) }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("\(node.kind.title) node, \(node.label)")
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: NodeLayout.cardCornerRadius).stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: NodeLayout.cardCornerRadius))
                    .allowsHitTesting(false)
            }
        }
        // Cards without an import target accept no types, so a Finder drop on
        // them falls through to the canvas and creates new input nodes.
        .onDrop(of: importImage == nil ? [] : [.fileURL], isTargeted: importImage == nil ? nil : $dropTargeted) { providers in
            guard let importImage else { return false }
            return handleImageDrop(providers, importImage)
        }
        .onChange(of: renameRequest) { _, request in if request > 0 { startEditingLabel() } }
        .sheet(isPresented: $showingMediaViewer) {
            if let mediaOutput {
                GeneratedMediaViewer(title: node.label, value: mediaOutput) { exportMedia?(mediaOutput) }
            }
        }
    }
    private var editorPlaceholder: String {
        if imagePromptCard { return "Describe the full image: who or what is present, what is happening, the setting, and important details…" }
        if videoPromptCard { return "Describe what happens in the shot, how the scene changes, and what the model must do…" }
        return "Write your prompt…"
    }
    private var editorAccessibilityLabel: String {
        if imagePromptCard { return "Image scene direction on canvas" }
        if videoPromptCard { return "Video action direction on canvas" }
        return "Prompt text on canvas"
    }
    private var promptEditorFooter: String {
        promptCard ? "Edit here or in the inspector" : "Refine details in the inspector"
    }
    private var showsMediaResult: Bool {
        if case .image = output { return imageCard }
        return NodeCardPreview.videoURL(node: node, output: output) != nil
    }
    private var mediaOutput: RuntimeValue? {
        guard node.supportsTakes else { return nil }
        switch output {
        case .image, .video: return output
        default: return nil
        }
    }
    @ViewBuilder private func runModelRow(_ action: @escaping () -> Void) -> some View {
        HStack {
            if let addImageInput {
                Button(node.kind.supportsDynamicVideoInputs ? "Add clip slot" : "Add another image input", systemImage: "plus", action: addImageInput)
                    .buttonStyle(.borderless)
            } else if let imageInputHint {
                Text(imageInputHint)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if imageCard {
                Text(ImageCardContent.footer(node: node, output: output))
                    .font(.system(size: CanvasType.label)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            modelButton(action)
        }
        .font(.system(size: CanvasType.label))
        .frame(width: NodeLayout.cardWidth(node) - NodeLayout.bodyInset * 2, height: NodeLayout.actionRowHeight)
    }
    @ViewBuilder private func modelButton(_ run: @escaping () -> Void) -> some View {
        if modelRunning, let cancelModel {
            Button("Cancel", systemImage: "stop.fill", action: cancelModel)
                .buttonStyle(.borderedProminent).tint(.red)
        } else if modelQueued, let cancelQueuedModel {
            Button("Queued", systemImage: "hourglass", action: cancelQueuedModel)
                .buttonStyle(.bordered).tint(.orange)
        } else {
            Button(node.kind.canvasRunLabel, systemImage: "arrow.right", action: run)
                .buttonStyle(.bordered)
                .disabled(node.isLockedFinal)
                .help(node.isLockedFinal ? "Locked as final. Unlock it to run again." : "")
        }
    }
    private func socket(_ port: PortDescriptor, index: Int) -> some View {
        let right = port.direction == .output
        let expansion = (NodeLayout.socketHitTargetWidth - NodeLayout.socketRailWidth) / 2
        // Center the larger transparent target around the existing rail so the
        // visible dot and the wire geometry stay on the exact card edge.
        let rowX = right ? NodeLayout.cardWidth(node) - expansion : -NodeLayout.socketRailWidth - expansion
        return PortSocket(node: node, port: port, dotAtRight: !right, connected: PortPresentation.socketIsFilled(port, connectedInputPortIDs: connectedInputPortIDs), active: isActive(port), compatible: isCompatible(port), action: wire)
            .offset(x: rowX, y: NodeLayout.socketY(node, index: index) - NodeLayout.socketHitTargetHeight / 2)
    }
    private func isActive(_ port: PortDescriptor) -> Bool {
        guard let activeWire else { return false }
        return activeWire.nodeID == node.id && activeWire.port.id == port.id && activeWire.port.direction == port.direction
    }
    private func isCompatible(_ port: PortDescriptor) -> Bool { guard let activeWire else { return false }; return activeWire.nodeID != node.id && activeWire.port.direction != port.direction && activeWire.port.type == port.type }
    private func startEditingLabel() {
        select()
        beginEditing()
        labelDraft = node.label
        editingLabel = true
        DispatchQueue.main.async { labelFocused = true }
    }
    private func commitLabel(returnFocus: Bool) {
        let trimmed = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingLabel = false
        labelFocused = false
        if !trimmed.isEmpty { rename(trimmed) }
        finishEditing(returnFocus)
    }
    private func cancelLabel(returnFocus: Bool) {
        editingLabel = false
        labelFocused = false
        labelDraft = node.label
        finishEditing(returnFocus)
    }
}

private struct PortSocket: View {
    let node: StudioNode; let port: PortDescriptor; let dotAtRight: Bool; let connected: Bool; let active: Bool; let compatible: Bool; let action: (PortDescriptor, CGPoint, Bool, Bool) -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(port.label).font(.system(size: CanvasType.label)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: NodeLayout.socketLabelWidth, height: NodeLayout.socketRowHeight, alignment: dotAtRight ? .trailing : .leading)
                .offset(x: dotAtRight ? 5 : 17)
            Circle().fill(connected ? portColor(port.type) : Surface.cardImage)
                .overlay(Circle().stroke(portColor(port.type), lineWidth: connected ? 0 : 2))
                .overlay(Circle().stroke(.white.opacity(compatible ? 0.9 : 0), lineWidth: 3).padding(-3))
                .overlay(Circle().stroke(active ? Color.accentColor : .clear, lineWidth: active ? 3 : 0).padding(-5))
                .scaleEffect(active ? 1.18 : 1)
                .frame(width: 12, height: 12)
                .position(x: dotAtRight ? NodeLayout.socketRailWidth : 0, y: NodeLayout.socketRowHeight / 2)
        }
        .frame(width: NodeLayout.socketRailWidth, height: NodeLayout.socketRowHeight)
        // Keep the visual rail compact but give the pointer a forgiving target.
        .frame(width: NodeLayout.socketHitTargetWidth, height: NodeLayout.socketHitTargetHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { action(port, $0.location, false, hypot($0.translation.width, $0.translation.height) > 3) }.onEnded { action(port, $0.location, true, hypot($0.translation.width, $0.translation.height) > 3) })
        .accessibilityLabel("\(node.label) \(port.direction.rawValue) \(port.label), \(port.type.rawValue). Click to arm or drag to connect")
    }
}

private func portColor(_ type: PortDataType) -> Color { DataTypeColor.forPort(type) }
private func wireColor(_ choice: WireColor?, fallback: PortDataType) -> Color {
    guard let choice else { return portColor(fallback) }
    return switch choice { case .red: .red; case .orange: .orange; case .yellow: .yellow; case .green: .green; case .mint: .mint; case .cyan: .cyan; case .blue: .blue; case .indigo: .indigo; case .purple: .purple; case .pink: .pink; case .gray: .gray }
}
private func wireSwatch(_ color: Color) -> NSImage {
    NSImage(size: .init(width: 16, height: 16), flipped: false) { rect in
        NSColor(color).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        return true
    }
}
