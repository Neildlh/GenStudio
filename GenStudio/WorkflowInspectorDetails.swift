import SwiftUI

struct WorkflowInspectorDetails: View {
    @ObservedObject var model: StudioModel
    let project: WorkflowProject
    @State private var draft: String
    @FocusState private var editingName: Bool

    init(model: StudioModel, project: WorkflowProject) {
        self.model = model; self.project = project
        _draft = State(initialValue: project.name)
    }
    var body: some View {
        Section("Workflow") {
            TextField("Name", text: $draft).focused($editingName).onSubmit(commit)
            LabeledContent("Nodes", value: "\(project.nodes.count)")
            LabeledContent("Connections", value: "\(project.edges.count)")
            Text("Select a node to edit its settings. Drag between sockets to connect nodes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: editingName) { _, focused in if !focused { commit() } }
        .onChange(of: project.name) { _, name in if !editingName { draft = name } }
        .onDisappear { if draft != project.name { commit() } }
    }
    private func commit() {
        guard draft != project.name else { return }
        do {
            try model.renameProject(project.id, to: draft)
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            draft = project.name
            model.alertMessage = error.localizedDescription
        }
    }
}
