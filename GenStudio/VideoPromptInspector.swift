import SwiftUI

struct VideoPromptInspector: View {
    @Binding var settings: VideoPromptSettings

    var body: some View {
        Section("Video route") {
            Picker("Use", selection: $settings.mode) { ForEach(VideoPromptMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            Text(settings.mode.help).font(.caption).foregroundStyle(.secondary)
        }
        Section("Shot recipe") {
            Menu("Start from a shot recipe…") {
                ForEach(VideoShotRecipe.all) { recipe in
                    Button { settings.apply(recipe) } label: { Text(recipe.title); Text(recipe.summary) }
                }
            }
            Text("Sets framing, camera move, focus, motion and look in one click. Your action, scene and sound stay as written.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Scene and action") {
            LongFormPromptEditor(
                text: $settings.action,
                placeholder: "Describe what happens in the shot, what changes over time, how the subject should move or react, and exactly what the model must do.",
                accessibilityLabel: "Video scene and action direction"
            )
            Text("This is the main shot direction. Camera, motion, continuity, look, timeline and sound below refine it.")
                .font(.caption).foregroundStyle(.secondary)
            TextField(settings.mode == .textToVideo ? "Who or what is in the scene, and where?" : "Extra subject / scene details (optional)", text: $settings.subjectScene, axis: .vertical).lineLimit(2...5)
        }
        Section("Camera") {
            Picker("Framing", selection: $settings.framing) { ForEach(VideoPromptSettings.framings, id: \.self) { Text($0).tag($0) } }
            Picker("Camera move", selection: $settings.cameraMovement) {
                if VideoCameraMove.named(settings.cameraMovement) == nil {
                    Text("Custom: \(settings.cameraMovement)").tag(settings.cameraMovement)
                }
                ForEach(VideoCameraMove.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(VideoCameraMove.all.filter { $0.group == group }) { Text($0.title).tag($0.title) }
                    }
                }
            }
            if let move = VideoCameraMove.named(settings.cameraMovement) {
                Text(move.direction).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if VideoCameraMove.named(settings.cameraMovement)?.takesPace ?? true {
                Picker("Camera pace", selection: $settings.cameraPace) { ForEach(VideoPromptSettings.cameraPaces, id: \.self) { Text($0).tag($0) } }
            }
            Picker("Focus", selection: $settings.focus) { ForEach(VideoPromptSettings.focusOptions, id: \.self) { Text($0).tag($0) } }
        }
        Section("Motion") { Picker("Movement style", selection: $settings.motionStyle) { ForEach(VideoPromptSettings.motionStyles, id: \.self) { Text($0).tag($0) } } }
        Section("Continuity") {
            TextField("What must remain consistent?", text: $settings.continuity, axis: .vertical).lineLimit(2...4)
            Text("Animate Start Image and Start/End already tie the shot to its pictures. Add only essential extra constraints here.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Look") {
            Picker("Lighting", selection: $settings.lighting) { ForEach(VideoPromptSettings.lightings, id: \.self) { Text($0).tag($0) } }
            Picker("Visual style", selection: $settings.visualLook) { ForEach(VideoPromptSettings.visualLooks, id: \.self) { Text($0).tag($0) } }
            Picker("Mood", selection: $settings.mood) { ForEach(VideoPromptSettings.moods, id: \.self) { Text($0).tag($0) } }
        }
        Section("Timeline") {
            TextField("Opening beat", text: $settings.openingBeat, axis: .vertical).lineLimit(1...3)
            TextField("Middle beat", text: $settings.middleBeat, axis: .vertical).lineLimit(1...3)
            TextField("Ending beat", text: $settings.endingBeat, axis: .vertical).lineLimit(1...3)
        }
        Section("Sound") {
            SuggestionField(title: "Ambience", text: $settings.ambience, placeholder: "e.g. Busy street outside", suggestions: VideoPromptSettings.ambienceSuggestions)
            SuggestionField(title: "Music", text: $settings.music, placeholder: "e.g. Upbeat acoustic guitar", suggestions: VideoPromptSettings.musicSuggestions)
            TextField("Who speaks (optional)", text: $settings.speaker, prompt: Text("e.g. The barber"))
            TextField("Spoken line (optional)", text: $settings.spokenLine, prompt: Text("e.g. Fresh cuts all weekend"), axis: .vertical).lineLimit(1...3)
            if settings.spokenLineIsLong {
                Label("About \(VideoPromptSettings.spokenWordLimit) words fit a five-second clip; a longer line gets rushed or cut off.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("LTX-2.3 makes this sound with the picture; the other video models stay silent. Each clip makes its own sound, so music changes at every cut: for a multi-shot ad describe the setting's sound here and add one music track after export. Generated speech is short and not always word-perfect; put prices and phone numbers on the End Card.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Section("Output") {
            Picker("Intent", selection: $settings.outputIntent) { ForEach(VideoPromptSettings.outputIntents, id: \.self) { Text($0).tag($0) } }
            TextField("Avoid (optional)", text: $settings.avoid, axis: .vertical).lineLimit(2...4)
            Text("Avoid is a separate optional output for Text to Video's Negative socket. Resolution, duration and frame rate remain controlled by the video-generation node.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Generated prompt") { Text(settings.compiledPrompt.isEmpty ? "Describe the action to create the video prompt." : settings.compiledPrompt).font(.caption).textSelection(.enabled) }
    }
}

/// A free-text field with a menu of common choices; picking one fills the field, and it stays editable.
private struct SuggestionField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let suggestions: [String]

    var body: some View {
        HStack(spacing: 6) {
            TextField(title, text: $text, prompt: Text(placeholder))
            Menu {
                Button("None") { text = "" }
                Divider()
                ForEach(suggestions, id: \.self) { suggestion in Button(suggestion) { text = suggestion } }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Common \(title.lowercased()) choices")
            .accessibilityLabel("\(title) suggestions")
        }
    }
}
