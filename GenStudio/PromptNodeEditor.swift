import SwiftUI

/// Edits the workflow's live prompt; generation previews never replace this text.
struct PromptNodeEditor: View {
    @Binding var text: String
    let nodeID: UUID
    var placeholder = "Write your prompt…"
    var accessibilityLabel = "Prompt text on canvas"
    var referenceMentions: [ReferenceMention] = []
    var beginEditing: () -> Void
    var finishEditing: (Bool) -> Void
    @FocusState private var editing: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius).fill(Surface.controlElevated)
            TextEditor(text: $text)
                .font(.system(size: CanvasType.prominent))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(12)
                .focused($editing)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("prompt-canvas-\(nodeID)")
            ReferenceMentionSuggestions(text: $text, mentions: referenceMentions)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: CanvasType.prominent)).foregroundStyle(.secondary)
                    .padding(.horizontal, 17).padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius))
        .onChange(of: editing) { wasFocused, focused in
            if focused { beginEditing() }
            else if wasFocused { finishEditing(false) }
        }
        .onExitCommand {
            editing = false
            finishEditing(true)
        }
    }
}

/// Compact completion menu shared by the canvas card and inspector. It appears
/// only while an unfinished @word is being typed, so ordinary prompt editing is
/// unaffected.
struct ReferenceMentionSuggestions: View {
    @Binding var text: String
    let mentions: [ReferenceMention]

    private var matches: [ReferenceMention] {
        guard let query = ReferenceMentionCatalog.query(in: text) else { return [] }
        return mentions.filter { ReferenceMentionCatalog.matches($0, query: query) }
    }

    var body: some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("References connected to this image generator")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 6)
                ForEach(matches) { mention in
                    Button {
                        text = ReferenceMentionCatalog.inserting(mention, into: text)
                    } label: {
                        HStack { Text(mention.token).fontWeight(.medium); Spacer(); Text(mention.detail).foregroundStyle(.secondary) }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 290, alignment: .leading)
            .padding(.bottom, 8).padding(.leading, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.16)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}
