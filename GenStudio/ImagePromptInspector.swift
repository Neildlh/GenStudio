import SwiftUI

struct ImagePromptInspector: View {
    @Binding var settings: ImagePromptSettings

    var body: some View {
        Section("Scene direction") {
            LongFormPromptEditor(
                text: $settings.subject,
                placeholder: "Describe the full image in your own words: who or what is present, what is happening, the setting, relationships, props, and any details that must be preserved.",
                accessibilityLabel: "Image scene direction"
            )
            Text("This is the main creative brief. The controls below add precise composition, lighting, style, mood, and output guidance without replacing your description.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Subject type", selection: $settings.subjectCategory) { ForEach(ImagePromptSettings.subjectCategories, id: \.self) { Text($0).tag($0) } }
        }
        Section("Composition") {
            Picker("Framing", selection: $settings.composition) { ForEach(ImagePromptSettings.compositions, id: \.self) { Text($0).tag($0) } }
            Picker("Camera angle", selection: $settings.cameraAngle) { ForEach(ImagePromptSettings.cameraAngles, id: \.self) { Text($0).tag($0) } }
            TextField("Extra composition direction", text: $settings.compositionNotes, axis: .vertical).lineLimit(2...4)
        }
        Section("Light") {
            Picker("Lighting", selection: $settings.lighting) { ForEach(ImagePromptSettings.lightings, id: \.self) { Text($0).tag($0) } }
            Picker("Colour", selection: $settings.colourTreatment) { ForEach(ImagePromptSettings.colourTreatments, id: \.self) { Text($0).tag($0) } }
            TextField("Extra lighting direction", text: $settings.lightNotes, axis: .vertical).lineLimit(2...4)
        }
        Section("Look") {
            Picker("Visual style", selection: $settings.visualLook) { ForEach(ImagePromptSettings.visualLooks, id: \.self) { Text($0).tag($0) } }
            TextField("Style, material or reference", text: $settings.lookNotes, axis: .vertical).lineLimit(2...4)
        }
        Section("Mood") {
            Picker("Atmosphere", selection: $settings.mood) { ForEach(ImagePromptSettings.moods, id: \.self) { Text($0).tag($0) } }
            TextField("Extra mood direction", text: $settings.moodNotes, axis: .vertical).lineLimit(2...4)
        }
        Section("Output") {
            AspectRatioIconSelector(
                selection: settings.aspectRatioPreset.map(AspectRatioSelection.preset) ?? .custom,
                guidance: "This direction travels with the prompt. Set the final pixel dimensions on the Image Generator.",
                apply: { settings.aspectRatio = ImagePromptSettings.aspectRatioDescription($0) }
            )
            Picker("Use", selection: $settings.outputIntent) { ForEach(ImagePromptSettings.outputIntents, id: \.self) { Text($0).tag($0) } }
            TextField("Final requirements", text: $settings.outputNotes, axis: .vertical).lineLimit(2...4)
        }
        Section("Generated prompt") {
            Text(settings.compiledPrompt.isEmpty ? "Describe the subject to create the prompt." : settings.compiledPrompt)
                .font(.caption).textSelection(.enabled)
        }
    }
}
