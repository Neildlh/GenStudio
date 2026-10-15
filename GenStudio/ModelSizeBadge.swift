import SwiftUI

struct ModelSizeBadge: View {
    let value: String
    let label: String
    var detail: String = ""

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "internaldrive").font(.callout)
                .foregroundStyle(.secondary)
            Text(value).font(.body.weight(.semibold)).monospacedDigit()
            if !label.isEmpty { Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.sm))
        .help(detail)
        .accessibilityElement(children: .combine)
    }
}

struct DiscoveryModelSizeView: View {
    @ObservedObject var store: ModelLibraryViewModel
    let model: DiscoveryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let size = store.discoverySizes[ModelLibraryViewModel.sizeKey(model)] {
                ModelSizeBadge(value: size.title, label: size.minBytes == nil ? "" : size.label, detail: size.detail)
                Text(size.detail).font(.callout).foregroundStyle(.secondary)
            } else if store.discoverySizeFailures.contains(ModelLibraryViewModel.sizeKey(model)) {
                HStack {
                    ModelSizeBadge(value: "Size unavailable", label: "")
                    Button("Retry size") { Task { await store.fetchDiscoverySize(model) } }.font(.caption)
                }
            } else {
                HStack(spacing: Space.sm) {
                    StudioSpinner()
                    Text("Checking file size…").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }.padding(.vertical, Space.sm)
            }
        }
        .task(id: ModelLibraryViewModel.sizeKey(model)) { await store.fetchDiscoverySize(model) }
    }
}
