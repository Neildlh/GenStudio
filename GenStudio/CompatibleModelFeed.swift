import SwiftUI

struct ModelCompatibilityBadge: View {
    let assessment: ModelCompatibility.Assessment
    var body: some View {
        Label(assessment.label, systemImage: assessment.eligible ? "checkmark.circle.fill" : "info.circle")
            .font(.callout.weight(.semibold))
            .foregroundStyle(assessment.eligible ? Color.green : Color.orange)
    }
}

struct CompatibleModelFeed: View {
    @ObservedObject var store: ModelLibraryViewModel
    let query: String
    @State private var selectedRecipe: ModelRecipe?
    private var recipes: [ModelRecipe] { store.supportedRecipes(matching: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.hardware == nil {
                HStack(spacing: 8) { StudioSpinner(); Text("Reading this Mac’s hardware and storage…") }
            } else if recipes.isEmpty {
                Label(emptyMessage, systemImage: "info.circle").font(.callout)
                Text("You can turn off the installability filter to browse other Hub listings, but those models may not be installable in GenStudio.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(recipes.count) GenStudio-ready packages · checked against this Mac across every supported local runtime").font(.caption).foregroundStyle(.secondary)
                ForEach(recipes) { recipe in
                    CompatibleModelCard(store: store, recipe: recipe, selectedRecipe: $selectedRecipe)
                }
            }
        }
        .sheet(item: $selectedRecipe) { ModelInstallSheet(store: store, recipe: $0) }
    }

    private var emptyMessage: String {
        if store.discoveryCategory == .video { return "No adapter-backed video recipe matches this search and this Mac's checks. Unsupported or rejected routes stay out of this feed." }
        if store.discoveryCategory == .sound { return "GenStudio does not yet have a supported local sound-generation engine, so no sound models are offered for this Mac." }
        if store.discoveryCategory == .images && store.discoveryTask == .imageEditing { return "No adapter-backed image-to-image recipe matches this search and this Mac's checks. Unverified routes are labelled and require explicit first-run review." }
        return "No checked model packages match this search and the current memory/storage checks. Try another search or refresh your Mac’s information."
    }
}

private struct CompatibleModelCard: View {
    @ObservedObject var store: ModelLibraryViewModel
    let recipe: ModelRecipe
    @Binding var selectedRecipe: ModelRecipe?
    private var status: ModelCompatibility.Assessment { store.compatibility(recipe) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ModelRecipePresentation.title(recipe)).font(.title2.weight(.semibold))
                    Text(recipe.provider?.capitalized ?? "GenStudio catalog").font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: Space.md)
                ModelInstallControl(store: store, recipe: recipe) { selectedRecipe = recipe }
            }
            HStack(spacing: 7) { ModelPurposeTags(purposes: ModelRecipePresentation.purposeTags(recipe)); ModelCompatibilityBadge(assessment: status) }
            Divider().opacity(0.6)
            Text(ModelRecipePresentation.purpose(recipe)).font(.title2)
            HStack(spacing: 18) {
                ModelListingFact(label: "Download", value: ModelLibraryViewModel.bytes(recipe.totalBytes))
                ModelListingFact(label: "Runtime", value: recipe.engineID)
                ModelListingFact(label: "Limits", value: ModelRecipePresentation.limits(recipe))
            }
            Text(status.detail).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(.white.opacity(0.08)))
    }
}

private struct ModelListingFact: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            Text(value).font(.caption).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
