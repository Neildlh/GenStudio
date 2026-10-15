import Foundation
import SwiftUI

enum GenerationSeedPolicy {
    /// Resolve before recording the graph so history contains the actual seed used.
    static func resolved(_ project: WorkflowProject, random: () -> Int = { Int.random(in: 0...Int(UInt32.max)) }) -> WorkflowProject {
        var copy = project
        for index in copy.nodes.indices where copy.nodes[index].supportsTakes && (!copy.nodes[index].seedLocked || (copy.nodes[index].kind.videoTask != nil && copy.nodes[index].video.seed < 0)) {
            let seed = random()
            if copy.nodes[index].kind == .imageGenerator { copy.nodes[index].imageSeed = seed }
            else { copy.nodes[index].video.seed = seed }
            copy.nodes[index].seedLocked = true
        }
        return copy
    }
}

extension StudioModel {
    func takes(for node: StudioNode, inProject projectID: UUID? = nil) -> [ExecutionArtifact] {
        let scope = projectID ?? currentProjectID
        guard node.supportsTakes, let port = node.outputPorts.first else { return [] }
        let address = PortAddress(nodeID: node.id, portID: port.id)
        let key = CanvasLookupCache.Key(projectID: scope, address: address)
        if let cached = lookupCache.takes[key] { return cached }
        var seen = Set<RuntimeValue>()
        let history = executionArtifacts.sorted { $0.createdAt < $1.createdAt }.filter { artifact in
            guard artifact.projectID == scope,
                  artifact.generatedNodeIDs?.contains(node.id) != false,
                  let value = artifact.values[address] else { return false }
            return seen.insert(value).inserted
        }
        lookupCache.takes[key] = history
        return history
    }

    func selectedTake(for node: StudioNode) -> ExecutionArtifact? {
        let history = takes(for: node)
        return history.first { $0.id == node.selectedTakeID } ?? history.last
    }

    func takePosition(for node: StudioNode) -> Int {
        guard let selected = selectedTake(for: node) else { return 0 }
        return (takes(for: node).firstIndex { $0.id == selected.id } ?? 0) + 1
    }

    func stepTake(for node: StudioNode, by offset: Int) {
        let history = takes(for: node)
        let next = takePosition(for: node) - 1 + offset
        guard !isRunning, !node.isLockedFinal, history.indices.contains(next) else { return }
        updateNode(node.id) { $0.selectedTakeID = history[next].id }
    }

    func runNode(_ node: StudioNode) { selectedNodeID = node.id; runSelected() }

}

struct GenerationTakeControls: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode
    var compact = false
    var addReference: (() -> Void)? = nil
    @State private var confirmDeleteSelected = false
    @State private var confirmDeleteEarlier = false
    @State private var confirmClearAll = false

    var body: some View {
        let history = model.takes(for: node)
        let position = model.takePosition(for: node)
        let running = model.isRunning(node.id)
        let queued = model.isQueued(node.id)
        let waiting = model.queuedTakeCount(for: node.id)
        HStack(spacing: 8) {
            if let addReference {
                Button("Add Reference", action: addReference)
                    .buttonStyle(.borderless)
            }
            if !history.isEmpty {
                HStack(spacing: 8) {
                    Button { model.stepTake(for: node, by: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(position <= 1 || model.isRunning).accessibilityLabel("Previous take")
                    Text("\(position) / \(history.count)").monospacedDigit()
                    Button { model.stepTake(for: node, by: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(position >= history.count || model.isRunning).accessibilityLabel("Next take")
                }
                .buttonStyle(.borderless)

                Menu {
                    Button("Delete Selected Take", role: .destructive) {
                        confirmDeleteSelected = true
                    }
                    if position > 1 {
                        Button("Delete Earlier Takes", role: .destructive) {
                            confirmDeleteEarlier = true
                        }
                    }
                    Divider()
                    Button("Clear All Takes", role: .destructive) {
                        confirmClearAll = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Manage generation takes")
                .accessibilityLabel("Manage generation takes")
            }
            Spacer()
            if !compact, !running, !queued {
                Menu {
                    ForEach([4, 8, 12, 24], id: \.self) { count in
                        Button("Generate \(count) Takes") { model.runTakes(of: node, count: count) }
                    }
                } label: {
                    Image(systemName: "square.stack.3d.down.right")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Queue a batch of takes, each with a fresh seed — for example overnight. Every take is kept.")
                .accessibilityLabel("Generate a batch of takes")
            }
            Button {
                if running { model.cancelTakes(of: node.id) }
                else if queued { model.cancelQueuedRun(node.id) }
                else { model.runNode(node) }
            } label: {
                Label(running ? (waiting > 0 ? "Cancel (+\(waiting))" : "Cancel") : queued ? (waiting > 1 ? "Queued ×\(waiting)" : "Queued") : compact ? node.kind.canvasRunLabel : history.isEmpty ? "Generate" : "Generate again",
                      systemImage: running ? "stop.fill" : queued ? "hourglass" : compact ? "arrow.right" : "play.fill")
            }
            .help(running && waiting > 0 ? "Stop this take and the \(waiting) still waiting" : queued ? "Remove this node's waiting takes from the generation queue" : node.seedLocked ? "Generate again with the locked seed" : "Generate a new variation with a fresh seed")
            .accessibilityLabel("Generate \(node.label) again")
            .buttonStyle(.bordered)
            .tint(running ? Color.red : queued ? Color.orange : Color.accentColor)
        }
        .font(compact ? .caption : .body)
        .disabled(node.isLockedFinal)
        .help(node.isLockedFinal ? "Locked as final. Unlock it to generate again." : "")
        .confirmationDialog("Delete the selected generation?", isPresented: $confirmDeleteSelected, titleVisibility: .visible) {
            Button("Delete Take", role: .destructive) {
                guard let take = model.selectedTake(for: node) else { return }
                Task { await model.deleteTake(take, for: node) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the generation from this node's history. Shared media used by other results will be kept.")
        }
        .confirmationDialog("Clear every generation from this node?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear All Takes", role: .destructive) {
                Task { await model.clearTakes(for: node) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all of this node's takes and empties the node. Shared media used by other results will be kept.")
        }
        .confirmationDialog("Delete earlier generations?", isPresented: $confirmDeleteEarlier, titleVisibility: .visible) {
            Button("Delete Earlier Takes", role: .destructive) {
                Task { await model.deleteEarlierTakes(for: node) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected take will be kept, and all previous takes for this node will be removed.")
        }
    }
}

struct GenerationSeedControls: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode
    var body: some View {
        Toggle("Lock seed — repeat this variation", isOn: Binding(get: { node.seedLocked }, set: { locked in
            let takeNode = model.selectedTake(for: node)?.graphSnapshot.nodes.first { $0.id == node.id }
            model.updateNodeFromBinding(node.id) { current in
                if locked, !current.seedLocked, let takeNode {
                    if current.kind == .imageGenerator { current.imageSeed = takeNode.imageSeed }
                    else { current.video.seed = takeNode.video.seed }
                }
                current.seedLocked = locked
            }
        }))
        Text(node.seedLocked ? "The same seed and settings usually reproduce the same result." : "Each generation uses a fresh seed. Every successful take is kept.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
