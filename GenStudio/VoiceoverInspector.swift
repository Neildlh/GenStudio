import SwiftUI

struct VoiceoverInspector: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var store: ModelLibraryViewModel
    let node: StudioNode
    @Binding var settings: VoiceoverSettings

    var body: some View {
        let voices = model.generationModels(.speech)
        Section("Voice model") {
            if voices.isEmpty {
                Text("Voiceover needs the local voice model (Qwen3-TTS Voice Design, about 3.1 GB, Apache-2.0).").font(.caption)
                if store.activeRecipeID == SpeechModelCatalog.qwen3VoiceDesignRecipeID {
                    ProgressView(value: store.progress); Text(store.progressText).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Install Voice Model") { store.install(SpeechModelCatalog.qwen3VoiceDesign) }
                        .disabled(store.busy)
                }
            } else {
                Picker("Model", selection: Binding(get: { node.model }, set: { id in model.updateNodeFromBinding(node.id) { $0.model = id } })) {
                    if !voices.contains(where: { $0.id == node.model }) { Text("Choose…").tag(node.model) }
                    ForEach(voices) { Text($0.name).tag($0.id) }
                }
            }
        }
        Section("Script") {
            TextEditor(text: $settings.script).frame(minHeight: 90).font(.body)
                .accessibilityLabel("Voiceover script")
            HStack {
                Text("About \(Int(settings.estimatedSeconds.rounded())) s spoken").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Fill from Brand Kit") { settings.script = VoiceoverSettings.starterScript(model.brandKit) }
                    .disabled(VoiceoverSettings.starterScript(model.brandKit).isEmpty)
            }
            Text("A connected Script input replaces this text. Amounts like R150 are read as \"150 rand\". Speech is not always word-perfect: listen before you publish, and keep phone numbers on screen too.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Voice") {
            Menu("Voice presets…") {
                ForEach(VoiceoverSettings.voicePresets, id: \.title) { preset in Button(preset.title) { settings.voice = preset.description } }
            }
            TextField("Describe the voice", text: $settings.voice, axis: .vertical).lineLimit(2...4)
            Text("Describe age, accent, warmth and pace in plain words. The accent follows the description approximately; each take sounds a little different, so generate a few and keep the best.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Mix") {
            Stepper("Starts at \(settings.startSeconds.formatted(.number.precision(.fractionLength(1)))) s", value: $settings.startSeconds, in: 0...600, step: 0.5)
            LabeledContent("Voice level") { Slider(value: $settings.voiceVolume, in: 0.2...1) }
            Toggle("Lower music and clip sound under the voice", isOn: $settings.duckOthers)
        }
    }
}
