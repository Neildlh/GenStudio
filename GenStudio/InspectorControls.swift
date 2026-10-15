import SwiftUI

/// The row above Width: while on, changing either dimension moves the other to keep the ratio.
struct RatioLockToggle: View {
    let locked: Bool
    let set: (Bool) -> Void
    var body: some View {
        Toggle("Lock ratio — width and height move together", isOn: Binding(get: { locked }, set: { set($0) }))
        Text(locked ? "Drag or type either size and the other follows, so the ratio you picked is kept." : "Width and height change independently.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Fast, glanceable aspect-ratio selection for media inspectors. The adaptive
/// grid stays useful in the narrow inspector and expands naturally when the
/// user makes the column wider.
struct AspectRatioIconSelector: View {
    let selection: AspectRatioSelection
    var currentDimensions: String? = nil
    var guidance: String? = nil
    let apply: (AspectRatioPreset) -> Void

    private let columns = [GridItem(.adaptive(minimum: 58, maximum: 82), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                InspectorControlHeading("Aspect ratio")
                Spacer(minLength: 8)
                if let currentDimensions {
                    Text(currentDimensions)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(AspectRatioPreset.allCases) { preset in
                    ratioButton(preset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .custom = selection {
                Label("Custom ratio", systemImage: "slider.horizontal.2.square")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let guidance {
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ratioButton(_ preset: AspectRatioPreset) -> some View {
        let selected = selection == .preset(preset)
        return Button {
            apply(preset)
        } label: {
            VStack(spacing: 7) {
                AspectRatioGlyph(ratio: preset.ratio)
                    .frame(height: 30)
                Text(preset.title)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.sm)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: selected ? 2 : 1)
        }
        .accessibilityLabel("Aspect ratio \(preset.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AspectRatioGlyph: View {
    let ratio: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(lineWidth: 2)
            .frame(width: glyphSize.width, height: glyphSize.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var glyphSize: CGSize {
        let maximum = CGSize(width: 38, height: 28)
        if ratio >= 1 {
            return CGSize(width: maximum.width, height: max(12, maximum.width / ratio))
        }
        return CGSize(width: max(12, maximum.height * ratio), height: maximum.height)
    }
}

/// Standard inspector typography for a group of related controls.
struct InspectorControlHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// A slider whose track always receives the entire inspector content width.
/// Labels live above the track instead of consuming horizontal track space.
struct FullWidthInspectorSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
                    .labelsHidden()
            } else {
                Slider(value: $value, in: range)
                    .labelsHidden()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
    }
}

/// Names, orders and removes the inputs of a text-joining node (Combine Text, Prompt Template).
/// A free socket is always kept at the end of the node, so there is no "add input" button to look for.
struct TextInputSlotList: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode

    private var connected: Set<String> {
        Set(model.currentProject?.edges.filter { $0.targetID == node.id }.map(\.targetPortID) ?? [])
    }
    private var isTemplate: Bool { node.kind == .promptTemplate }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorControlHeading(isTemplate ? "Variables" : "Parts, in output order")
            ForEach(Array(node.dynamicInputs.enumerated()), id: \.element.id) { index, port in
                TextInputSlotRow(model: model, nodeID: node.id, port: port, isConnected: connected.contains(port.id),
                                 canReorder: !isTemplate, isFirst: index == 0, isLast: index == node.dynamicInputs.count - 1)
            }
            Text(isTemplate
                 ? "Each variable is the name a {{placeholder}} in the template refers to. Renaming one updates the template. A free socket is always available at the bottom."
                 : "Drag a wire onto the free socket at the bottom and another appears. Parts join top to bottom.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TextInputSlotRow: View {
    @ObservedObject var model: StudioModel
    let nodeID: UUID
    let port: DynamicInputPort
    let isConnected: Bool
    let canReorder: Bool
    let isFirst: Bool
    let isLast: Bool
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isConnected ? "circle.fill" : "circle")
                .foregroundStyle(DataTypeColor.forPort(.text))
                .accessibilityLabel(isConnected ? "Connected" : "Free")
            TextField("Name", text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.renameDynamicInput(nodeID: nodeID, portID: port.id, to: draft) }
            if canReorder {
                Button { model.moveDynamicInput(nodeID: nodeID, portID: port.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(isFirst).accessibilityLabel("Move \(port.label) earlier")
                Button { model.moveDynamicInput(nodeID: nodeID, portID: port.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(isLast).accessibilityLabel("Move \(port.label) later")
            }
            Button { model.removeDynamicInput(nodeID: nodeID, portID: port.id) } label: { Image(systemName: "minus.circle") }
                .disabled(!isConnected && isLast).accessibilityLabel("Remove \(port.label)")
        }
        .buttonStyle(.borderless)
        .onAppear { draft = port.label }
        .onChange(of: port.label) { _, label in draft = label }
    }
}

/// A whole-number field that clamps to its range. A stepper that moves one pixel at a time is unusable across 1–16,384.
struct ClampedIntField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number.grouping(.never))
                .multilineTextAlignment(.trailing).frame(width: 96)
        }
    }
}

/// Whether Combine Text's separator shows a real line break as `\n`, so the default is visible and editable.
enum SeparatorField {
    static func display(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
    }
    static let presets: [(title: String, value: String)] = [("New line", "\\n"), ("Blank line", "\\n\\n"), ("Space", " "), ("Comma", ", "), ("None", "")]
}
