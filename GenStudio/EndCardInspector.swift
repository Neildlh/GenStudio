import AppKit
import SwiftUI

/// End Card settings with a live preview of the finished card (connected logo and background pictures are
/// added when the node runs).
struct EndCardInspector: View {
    @ObservedObject var model: StudioModel
    @Binding var settings: EndCardSettings

    var body: some View {
        Section("Brand Kit") {
            HStack {
                Button("Fill from Brand Kit") { model.brandKit.fill(&settings) }
                    .disabled(model.brandKit.isEmpty)
                Button("Save as Brand Kit") { model.brandKit.take(settings); model.saveBrandKit() }
            }
            HStack {
                Text(model.brandKit.logoURL(root: model.persistence.root) == nil ? "No brand logo yet" : "Brand logo saved")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.brandKit.logoFileName == nil ? "Choose Logo…" : "Change Logo…") { model.chooseBrandLogo() }
            }
            Text("Save your business details once; every new End Card and Start Video Ad starts from them, with the logo already connected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Card text") {
            TextField("Headline", text: $settings.headline, prompt: Text("e.g. Thabo's Barbershop"), axis: .vertical).lineLimit(1...3)
            TextField("Offer", text: $settings.offer, prompt: Text("e.g. Fresh cuts from R150"), axis: .vertical).lineLimit(1...2)
            TextField("Contact", text: $settings.contact, prompt: Text("e.g. WhatsApp 082 123 4567"))
            TextField("Web or social", text: $settings.website, prompt: Text("e.g. @thabosbarber · Soweto"))
            Text("Empty lines are left out. Long lines wrap and shrink to fit; everything stays clear of the Reels and Status buttons.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Look") {
            Menu("Colour palette…") {
                ForEach(EndCardSettings.palettes, id: \.title) { palette in
                    Button(palette.title) { settings.backgroundHex = palette.background; settings.textHex = palette.text; settings.accentHex = palette.accent }
                }
            }
            ColorPicker("Background", selection: color(\.backgroundHex), supportsOpacity: false)
            ColorPicker("Text", selection: color(\.textHex), supportsOpacity: false)
            ColorPicker("Accent (offer and rule)", selection: color(\.accentHex), supportsOpacity: false)
            LabeledContent("Darken background picture") {
                Slider(value: $settings.backgroundDim, in: 0...0.9)
            }
            Toggle("Animate text in", isOn: $settings.animate)
            Text("Connect a Logo (a PNG with transparency looks best) and optionally a Background picture, such as one of your ad's stills.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Format") {
            Picker("Size", selection: Binding(get: { "\(settings.width)x\(settings.height)" }, set: { value in
                guard let size = EndCardSettings.sizes.first(where: { "\($0.width)x\($0.height)" == value }) else { return }
                settings.width = size.width; settings.height = size.height
            })) {
                ForEach(EndCardSettings.sizes, id: \.title) { Text($0.title).tag("\($0.width)x\($0.height)") }
            }
            Stepper("Length: \(settings.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s", value: $settings.durationSeconds, in: EndCardSettings.durationRange, step: 0.5)
            Picker("Frame rate", selection: $settings.fps) { ForEach(EndCardSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) } }
            Text("Match your clips so the Stitcher needs no frame-rate change: LTX-2.3 and FastMetal make 24 fps.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Preview") {
            if let preview = EndCardRenderer.preview(settings, maxPixel: 480) {
                Image(decorative: preview, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("End card preview")
            }
        }
    }

    private func color(_ keyPath: WritableKeyPath<EndCardSettings, String>) -> Binding<Color> {
        Binding(get: { EndCardSettings.color(settings[keyPath: keyPath]).map { Color(cgColor: $0) } ?? .black }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            settings[keyPath: keyPath] = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }
}
