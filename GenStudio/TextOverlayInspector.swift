import SwiftUI

struct TextOverlayInspector: View {
    @ObservedObject var model: StudioModel
    @Binding var settings: TextOverlaySettings

    var body: some View {
        Section("Caption") {
            TextField("Caption", text: $settings.text, prompt: Text("e.g. From R150"), axis: .vertical).lineLimit(1...2)
            TextField("Second line (optional)", text: $settings.subtext, prompt: Text("e.g. This weekend only"))
            Picker("Position", selection: $settings.position) { ForEach(TextOverlaySettings.Position.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker("Style", selection: $settings.style) { ForEach(TextOverlaySettings.Style.allCases, id: \.self) { Text($0.title).tag($0) } }
            ColorPicker("Accent", selection: color(\.accentHex), supportsOpacity: false)
            if settings.style == .plain { ColorPicker("Text", selection: color(\.textHex), supportsOpacity: false) }
            Button("Use Brand Kit colours") { model.brandKit.fill(&settings) }
        }
        Section("Timing") {
            Stepper("Appears at \(settings.startSeconds.formatted(.number.precision(.fractionLength(1)))) s", value: $settings.startSeconds, in: 0...600, step: 0.5)
            Stepper(settings.durationSeconds == 0 ? "Stays until the clip ends" : "Stays for \(settings.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s",
                    value: $settings.durationSeconds, in: 0...600, step: 0.5)
            Toggle("Fade in and out", isOn: $settings.fade)
            Text("Put prices and phone numbers here or on the End Card rather than in a spoken line: text is always exact.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func color(_ keyPath: WritableKeyPath<TextOverlaySettings, String>) -> Binding<Color> {
        Binding(get: { EndCardSettings.color(settings[keyPath: keyPath]).map { Color(cgColor: $0) } ?? .white }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            settings[keyPath: keyPath] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }
}
