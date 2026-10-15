import SwiftUI

/// A prominent multiline field for the authored idea that structured prompt
/// controls refine. This remains ordinary bound text, so edits made on the
/// canvas and in the inspector always address the same persisted value.
struct LongFormPromptEditor: View {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(.quaternary.opacity(0.35))
            TextEditor(text: $text)
                .font(.body)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(8)
                .accessibilityLabel(accessibilityLabel)
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 130)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.sm)
                .stroke(.separator.opacity(0.7))
        }
    }
}
