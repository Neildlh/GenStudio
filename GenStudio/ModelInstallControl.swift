import SwiftUI

/// Where a package stands, from the owner's point of view. Pure so every branch is tested without a view.
enum ModelInstallState: Equatable {
    case installed
    case installing(fraction: Double)
    case queued(position: Int)
    /// It can't install on this Mac; the reason is a few plain words.
    case blocked(reason: String)
    case ready(downloadBytes: Int64, startsAfterCurrent: Bool)

    @MainActor
    static func resolve(_ recipe: ModelRecipe, in store: ModelLibraryViewModel) -> ModelInstallState {
        if store.isInstalled(recipe.id) { return .installed }
        if store.activeRecipeID == recipe.id { return .installing(fraction: store.progress) }
        if let position = store.queuePosition(recipe.id) { return .queued(position: position) }
        if let reason = store.installBlocker(recipe) { return .blocked(reason: reason) }
        return .ready(downloadBytes: store.downloadBytes(recipe), startsAfterCurrent: store.busy || store.bulkInstalling)
    }
}

/// The one install control every model listing uses, so getting a model always looks the same: a prominent
/// Install button with its download size on the trailing edge of the row, progress in place while it
/// downloads, a place in line when another download is running, and the reason when it can't install.
struct ModelInstallControl: View {
    enum Size { case regular, compact }

    @ObservedObject var store: ModelLibraryViewModel
    let recipe: ModelRecipe
    /// "Download & Test" for packages whose first run is their proof.
    var actionTitle = "Install"
    var size: Size = .regular
    /// Opens the review sheet (licences, files, import). Nil hides the Details button.
    var details: (() -> Void)? = nil

    static let regularWidth: CGFloat = 210

    var body: some View {
        let state = ModelInstallState.resolve(recipe, in: store)
        VStack(alignment: .trailing, spacing: Space.xs) {
            primary(state)
            if case .installed = state {} else if let details {
                Button("Details", action: details)
                    .buttonStyle(.link)
                    .font(size == .regular ? .callout : .caption)
            }
        }
        .frame(width: size == .regular ? Self.regularWidth : nil, alignment: .trailing)
    }

    @ViewBuilder private func primary(_ state: ModelInstallState) -> some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font((size == .regular ? Font.callout : .caption).weight(.semibold))
                .foregroundStyle(.green)
        case .installing(let fraction):
            VStack(alignment: .trailing, spacing: Space.xs) {
                StudioLinearProgress(value: fraction > 0 ? fraction : nil)
                    .frame(width: size == .regular ? 160 : 90)
                HStack(spacing: Space.sm) {
                    let percent = "\(Int((fraction * 100).rounded(.down)))%"
                    Text(fraction > 0 ? (size == .regular ? "Downloading \(percent)" : percent) : "Starting…")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Cancel") { store.cancel() }
                        .controlSize(.small)
                }
            }
        case .queued(let position):
            VStack(alignment: .trailing, spacing: 2) {
                Label(position == 1 ? "Next in line" : "Queued · \(position) in line", systemImage: "clock")
                    .font((size == .regular ? Font.callout : .caption).weight(.semibold))
                    .foregroundStyle(.blue)
                Button("Remove from queue") { store.removeFromQueue(recipe.id) }
                    .buttonStyle(.link).font(.caption)
            }
        case .blocked(let reason):
            VStack(alignment: .trailing, spacing: 2) {
                installButton(title: actionTitle).disabled(true)
                Text(reason)
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready(let bytes, let startsAfterCurrent):
            VStack(alignment: .trailing, spacing: 2) {
                installButton(title: "\(actionTitle) · \(ModelLibraryViewModel.bytes(bytes))")
                if startsAfterCurrent {
                    Text(size == .regular ? "Starts after the current download" : "Queues after current")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func installButton(title: String) -> some View {
        Button { store.requestInstall(recipe) } label: {
            Label(title, systemImage: "arrow.down.circle.fill")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(size == .regular ? .large : .small)
        .help("Downloads the pinned files, checks every checksum and adds the model to this Mac's library.")
        .accessibilityLabel("\(actionTitle) \(ModelRecipePresentation.title(recipe))")
    }
}
