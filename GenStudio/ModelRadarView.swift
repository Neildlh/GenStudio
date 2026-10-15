import SwiftUI

/// "What to try next": sits under Start Here. Everything shown as a fact (tier, fit, size, links)
/// is computed by code; the sentences may come from a local model, and the view says which.
struct ModelRadarSection: View {
    @ObservedObject var store: ModelLibraryViewModel
    @ObservedObject private var radar: ModelRadarStore
    let review: (ModelRecipe) -> Void

    init(store: ModelLibraryViewModel, review: @escaping (ModelRecipe) -> Void) {
        self.store = store
        self.radar = store.radar
        self.review = review
    }

    var body: some View {
        let presentation = radar.presentation
        VStack(alignment: .leading, spacing: Space.md) {
            header
            if let summary = radar.notes?.summary { summaryCard(summary) }
            if radar.checking {
                HStack(spacing: 8) {
                    StudioSpinner()
                    Text(radar.phase).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { radar.cancel() }
                }
            }
            if let failure = radar.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(RadarCategory.allCases, id: \.self) { category in
                let families = presentation.families.filter { $0.category == category }
                if !families.isEmpty {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Label(category.title, systemImage: category.systemImage)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(families) { familyBlock($0) }
                    }
                }
            }
            if presentation.unassessedNewerReleases > 0 {
                Label("\(presentation.unassessedNewerReleases) newer release\(presentation.unassessedNewerReleases == 1 ? "" : "s") found but not shown: not yet assessed against the bar below.",
                      systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
            if let writer = radar.notes?.writer {
                Text(writer).font(.caption2).foregroundStyle(.secondary)
            }
            Text(MacFitStandard.barSummary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.lg)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
        .task { await radar.loadCached(); radar.checkIfDue() }
    }

    // MARK: header and summary

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What to try next").font(.title2.bold())
                    Text(checkedLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(radar.checking ? "Checking…" : "Check for new models") { radar.check() }
                    .buttonStyle(.borderedProminent)
                    .disabled(radar.checking)
            }
            Text("Only models that are both fast and high quality on this Mac. Each one shows its evidence, and says whether the speed was measured here or estimated. Models GenStudio can't run yet are listed separately and can't be installed from here.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(radar.wordingSource).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checkedLine: String {
        guard let date = radar.snapshot?.fetchedAt else { return "Not checked yet. Below is what GenStudio can already run." }
        return "Last checked " + date.formatted(date: .abbreviated, time: .shortened)
    }

    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Top pick for this Mac", systemImage: "sparkles").font(.subheadline.weight(.semibold))
            Text(summary).font(.callout).textSelection(.enabled)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    // MARK: families and entries

    private func familyBlock(_ family: RadarFamilyReport) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(family.title).font(.headline)
                if !family.status.isEmpty { Text(family.status).font(.caption).foregroundStyle(.secondary) }
                if let failure = family.failure {
                    Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            ForEach(family.entries.filter { $0.tier != .watch }) { routeRow($0) }
            ForEach(family.entries.filter { $0.tier == .watch }) { watchRow($0) }
        }
    }

    private func routeRow(_ entry: RadarEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TierChip(tier: entry.tier)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                Text(sentence(entry)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                fitLine(entry)
                RadarVerdictLines(verdict: entry.verdict)
            }
            Spacer(minLength: Space.md)
            if let id = entry.recipeID, let recipe = store.modelRecipes.first(where: { $0.id == id }) {
                ModelInstallControl(store: store, recipe: recipe, actionTitle: entry.tier == .proven ? "Install" : "Download & Test") { review(recipe) }
            }
        }
        .padding(Space.md)
        .background(tint(entry.tier).opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    /// Collapsed: the label alone says what exists, and the detail is one click away. Never has an install button.
    private func watchRow(_ entry: RadarEntry) -> some View {
        DisclosureGroup {
            RadarWatchDetail(entry: entry, sentence: sentence(entry))
        } label: {
            HStack(spacing: 8) {
                TierChip(tier: .watch, title: entry.verdict != nil ? "Suggested" : nil)
                Text(entry.verdict != nil ? "\(entry.title) meets the bar — not built into GenStudio yet" : "\(entry.title) is out — GenStudio can't run it yet")
                    .fontWeight(.semibold)
            }
        }
        .padding(Space.md)
        .background(tint(.watch).opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.sm))
    }

    private func fitLine(_ entry: RadarEntry) -> some View { RadarFitLine(entry: entry) }

    private func sentence(_ entry: RadarEntry) -> String { RadarPrompt.sentence(for: entry, blurbs: radar.notes?.blurbs ?? [:]) }

    private func tint(_ tier: RadarTier) -> Color { tier.color }
}

private extension RadarTier {
    var color: Color {
        switch self {
        case .proven: .green
        case .readyToTest: .blue
        case .watch: .orange
        }
    }
}

/// The evidence behind showing a model: its quality and speed, whether the speed was measured here, and any licence note.
struct RadarVerdictLines: View {
    let verdict: MacFitVerdict?

    var body: some View {
        if let verdict {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quality: \(verdict.quality)").font(.caption).foregroundStyle(.secondary)
                Text("Speed: \(verdict.speed)").font(.caption).foregroundStyle(.secondary)
                Text("Evidence: \(verdict.basis.label)\(verdict.status == .expectedToMeet ? " — expected to meet the bar, not yet measured here" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
                if let note = verdict.note {
                    Label(note, systemImage: "info.circle").font(.caption2).foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
    }
}

private struct RadarFitLine: View {
    let entry: RadarEntry

    var body: some View {
        let size = entry.sizeBytes.flatMap { $0 > 0 ? ModelLibraryViewModel.bytes($0) : nil }
        let text = [entry.fit.label, size.map { entry.tier == .watch ? "published size \($0)" : "\($0) download" }].compactMap { $0 }.joined(separator: " · ")
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color).help(entry.fit.detail).fixedSize(horizontal: false, vertical: true)
    }

    private var color: Color {
        switch entry.fit.level {
        case .comfortable: .green
        case .demanding: .orange
        case .exceeds: .red
        case .unknown: .secondary
        }
    }
}

/// What a Watch entry reveals when opened: facts and links out, never an install action.
struct RadarWatchDetail: View {
    let entry: RadarEntry
    let sentence: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sentence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            RadarFitLine(entry: entry)
            RadarVerdictLines(verdict: entry.verdict)
            if entry.gated {
                Text("Gated on Hugging Face: accept the publisher's licence there before downloading anything.").font(.caption).foregroundStyle(.secondary)
            }
            if let repository = entry.repository, let url = Self.hubURL(repository) {
                Link("Publisher's release · \(repository)", destination: url).font(.caption)
            }
            if !entry.buildRepositories.isEmpty {
                Text("Apple Silicon (MLX) builds by the community:").font(.caption).foregroundStyle(.secondary)
                ForEach(entry.buildRepositories) { build in
                    if let url = Self.hubURL(build.id) {
                        Link("\(build.id)\(build.downloads.map { " · \($0) downloads" } ?? "")", destination: url).font(.caption)
                    }
                }
            }
            Text("GenStudio can't install or run these yet. Links open huggingface.co in your browser.").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// Links are rebuilt from a validated `owner/name`, never taken from stored text as-is.
    static func hubURL(_ repository: String) -> URL? {
        guard (try? ModelLibrary.parseHubLink(repository)) == repository else { return nil }
        return URL(string: "https://huggingface.co/\(repository)")
    }
}

/// The tier is always spelled out as well as coloured.
private struct TierChip: View {
    let tier: RadarTier
    var title: String? = nil

    var body: some View {
        Text(title ?? tier.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tier.color.opacity(0.18), in: RoundedRectangle(cornerRadius: Radius.xs))
            .foregroundStyle(tier.color)
            .frame(minWidth: 84, alignment: .leading)
    }
}
