import AppKit
import AVKit
import SwiftUI

struct RuntimeValueView: View {
    let value: RuntimeValue
    var compact = false
    var expanded = false
    /// Show every line of text and every list item. The inspector is already scrollable, and a preview
    /// that cuts a result off after four lines cannot be used to read it.
    var fullText = false

    var body: some View {
        switch value {
        case .text(let text):
            Text(text).lineLimit(compact && !fullText ? 4 : nil).textSelection(.enabled)
        case .textArray(let items):
            let truncated = compact && !fullText
            VStack(alignment: .leading, spacing: 4) {
                Text("\(items.count) items").font(.caption.bold())
                ForEach(Array(items.prefix(truncated ? 5 : 256).enumerated()), id: \.offset) { index, text in Text("\(index + 1). \(text)").lineLimit(truncated ? 1 : nil).textSelection(.enabled) }
            }
        case .number(let number):
            Text(number.formatted()).textSelection(.enabled)
        case .image(let url):
            LocalImageThumbnail(url: url)
                .frame(maxWidth: .infinity, maxHeight: expanded ? .infinity : compact ? 150 : 320)
        case .shotSequence(let sequence):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(sequence.anchors.count) frames · \(sequence.timing.duration.formatted()) s at \(sequence.timing.fps) fps").font(.caption.bold())
                ScrollView(.horizontal) { HStack(spacing: 4) { ForEach(sequence.anchors, id: \.anchorID) { LocalImageThumbnail(url: $0.image).frame(width: 56, height: 42) } } }
            }
        case .video(let url):
            if FileManager.default.isReadableFile(atPath: url.path) {
                RuntimeVideoView(url: url, compact: compact, expanded: expanded)
                    .id(url)
            } else {
                Label("Video is missing or unreadable: \(url.lastPathComponent)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct RuntimeVideoView: View {
    let url: URL
    let compact: Bool
    let expanded: Bool

    var body: some View {
        RetainedVideoPlayer(url: url)
            .frame(minHeight: expanded ? 480 : compact ? 110 : 220, maxHeight: expanded ? .infinity : compact ? 150 : 320)
            .accessibilityLabel("Retained video player")
    }
}

/// One player per file: it survives redraws (so playback and sound do not restart), is replaced when the
/// file changes (a new take), and pauses when the view goes away.
struct RetainedVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: url) {
                player?.pause()
                player = AVPlayer(url: url)
            }
            .onDisappear { player?.pause() }
    }
}

struct GeneratedMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let value: RuntimeValue
    var rename: ((String) -> Void)? = nil
    let export: () -> Void
    @State private var displayTitle: String
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFieldFocused: Bool

    init(title: String, value: RuntimeValue, rename: ((String) -> Void)? = nil, export: @escaping () -> Void) {
        self.value = value
        self.rename = rename
        self.export = export
        _displayTitle = State(initialValue: title)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                titleView
                Spacer()
                Button("Download", systemImage: "square.and.arrow.down", action: export)
                Button("Done", action: { dismiss() }).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            RuntimeValueView(value: value, expanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
        }
        .frame(minWidth: 760, idealWidth: 1040, minHeight: 560, idealHeight: 760)
    }

    @ViewBuilder private var titleView: some View {
        if isEditingTitle {
            TextField("Name", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(.headline)
                .frame(maxWidth: 360)
                .focused($titleFieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { isEditingTitle = false }
                .onChange(of: titleFieldFocused) { _, focused in
                    if !focused { commitRename() }
                }
                .task { titleFieldFocused = true }
        } else {
            Text(displayTitle)
                .font(.headline)
                .lineLimit(1)
                .help(rename != nil ? "Double-click to rename" : "")
                .onTapGesture(count: 2) { beginEditing() }
        }
    }

    private func beginEditing() {
        guard rename != nil else { return }
        editedTitle = displayTitle
        isEditingTitle = true
    }
    private func commitRename() {
        let cleaned = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingTitle = false
        guard !cleaned.isEmpty, cleaned != displayTitle else { return }
        displayTitle = cleaned
        rename?(cleaned)
    }
}
