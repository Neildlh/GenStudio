import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The round lock tab on a node's bottom edge. It takes the card's own colour so it reads as part of the card:
/// an open grey lock while the node is still being worked on, a closed green one once it is final.
struct FinalBadge: View {
    static let diameter: CGFloat = 34

    let state: FinalBadgeState
    /// The card's base colour, so the tab looks cut out of the card rather than laid on it.
    let base: Color
    let nodeName: String
    let action: () -> Void

    private var symbol: String { state == .open ? "lock.open.fill" : "lock.fill" }
    private var tint: Color {
        switch state {
        case .open: Color.white.opacity(0.42)
        case .locked: Color(red: 0.36, green: 0.80, blue: 0.47)
        case .missing: Color.red
        }
    }
    private var help: String {
        switch state {
        case .open: "Lock as final: saves this result to the project folder and stops this node generating"
        case .locked: "Locked as final. Click to unlock and keep generating"
        case .missing: "Locked, but its saved file is missing. Click to unlock"
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(base)
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(state == .open ? "Lock \(nodeName) as final" : "Unlock \(nodeName)")
        .accessibilityValue(state == .open ? "Open" : state == .locked ? "Locked" : "Locked, file missing")
    }
}

/// The inspector's "Final" section: what is saved, and the controls to lock, unlock and find it.
struct FinalInspectorSection: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode

    var body: some View {
        if let state = model.finalBadgeState(for: node) {
            Section("Final") {
                switch state {
                case .open:
                    Label("Open: still being worked on", systemImage: "lock.open").foregroundStyle(.secondary)
                    Text(node.finalized == nil
                         ? "Lock this node when you are happy with it. The result is saved to the project folder as “\(node.label)” and connected nodes use that file."
                         : "Locking again replaces the saved file “\((node.finalized?.path ?? "") as NSString).lastPathComponent”.")
                        .font(.caption).foregroundStyle(.secondary)
                case .locked, .missing:
                    Label(state == .locked ? "Locked as final" : "Locked, but the saved file is missing", systemImage: "lock.fill")
                        .foregroundStyle(state == .locked ? Color.green : Color.red)
                    if let path = node.finalized?.path { Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text("This node will not generate. Connected nodes use the saved file, so changes upstream do not reach them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(state == .open ? "Lock as Final" : "Unlock") { model.toggleFinal(node.id) }
                    if node.finalized != nil { Button("Show in Finder") { model.revealFinal(node.id) } }
                }
            }
        }
    }
}

extension StudioModel {
    /// Saves a prompt to a text file anywhere, so it can be reused in another project.
    func savePromptAs(_ nodeID: UUID) {
        guard let node = currentProject?.nodes.first(where: { $0.id == nodeID }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = ProjectPackager.split(node.label, fallbackExtension: "txt").stem + ".txt"
        if let home = currentHome { panel.directoryURL = home.folder(for: .text) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(node.prompt.utf8).write(to: url, options: .atomic) }
        catch { alertMessage = "Could not save the prompt: \(error.localizedDescription)" }
    }

    /// Replaces a prompt with the text of a file. The text is copied in, so the prompt stays with the project.
    func loadPrompt(_ nodeID: UUID) {
        guard let node = currentProject?.nodes.first(where: { $0.id == nodeID }), !node.isLockedFinal else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a text file to use as the prompt for “\(node.label)”."
        if let home = currentHome { panel.directoryURL = home.folder(for: .text) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            guard size <= 1_000_000 else { throw StudioError.validation("\(url.lastPathComponent) is larger than 1 MB, which is too long for a prompt.") }
            let text = try String(contentsOf: url, encoding: .utf8)
            updateNode(nodeID) { $0.prompt = text }
        } catch { alertMessage = "Could not load \(url.lastPathComponent): \(error.localizedDescription)" }
    }
}
