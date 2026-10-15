import SwiftUI

/// Offers LTX-2.3's 365 MB sound decoder when the installed package predates it. Shown on LTX clip settings
/// and in the Models sidebar; it observes the library store so progress and completion update in place.
struct LTXSoundFilesRow: View {
    @ObservedObject var store: ModelLibraryViewModel

    var body: some View {
        let adding = store.activeRecipeID == MLXVideoModelCatalog.ltx23Q4RecipeID
        VStack(alignment: .leading, spacing: 4) {
            Text("LTX-2.3 can make sound with its clips, but the sound decoder isn't installed yet, so clips are silent.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if adding {
                ProgressView(value: store.progress)
                Text(store.progressText).font(.caption2).foregroundStyle(.secondary)
            } else {
                Button("Add Sound Files (\(ModelLibraryViewModel.bytes(ModelLibraryViewModel.ltxSoundFilesBytes)))") { store.addLTXSoundFiles() }
                    .font(.caption)
                    .disabled(store.busy)
                    .help("Downloads and verifies only the two sound files from the same pinned LTX-2.3 release. The video weights stay as they are.")
            }
        }
    }
}
