import SwiftUI

/// "What should be on this Mac": every installed model judged for this machine (keep, can't be used, not
/// needed), workflow nodes that point at missing models, and recommended models still to add. Removal and
/// node moves are always the owner's confirmed actions; nothing here deletes on its own.
struct ModelAdviceSection: View {
    @ObservedObject var model: StudioModel
    @State private var removeTarget: ModelAdvice?
    @State private var confirmingBulkRemoval = false
    @State private var showKept = false

    var body: some View {
        let report = model.modelAdvice
        let store = model.libraryStore
        let locked = store.busy || store.generationRunning
        let cannotRun = report.advice.filter { $0.status == .cannotRun }
        let notNeeded = report.advice.filter { $0.status == .notNeeded }
        let kept = report.advice.filter { $0.status == .keep }
        let unused = report.advice.filter { $0.status != .keep && $0.usage.nodeCount == 0 }

        Section("What this Mac should have") {
            summary(report: report, kept: kept.count, unused: unused, locked: locked)
            if !report.missing.isEmpty || store.ltxNeedsSoundFiles {
                group("Needs your attention", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    if store.ltxNeedsSoundFiles { LTXSoundFilesRow(store: store) }
                    ForEach(report.missing) { missing in missingRow(missing, locked: locked) }
                }
            }
            if !cannotRun.isEmpty {
                group("Can't be used on this Mac", systemImage: "xmark.octagon.fill", tint: .red) {
                    ForEach(cannotRun) { row($0, locked: locked) }
                }
            }
            if !notNeeded.isEmpty {
                group("Not needed on this Mac", systemImage: "arrow.down.circle.fill", tint: .orange) {
                    ForEach(notNeeded) { row($0, locked: locked) }
                }
            }
            if !kept.isEmpty {
                DisclosureGroup(isExpanded: $showKept) {
                    ForEach(kept) { row($0, locked: locked) }
                } label: {
                    Label("Keep · \(kept.count) model\(kept.count == 1 ? "" : "s")", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
            }
        }
        Section("Discover") {
            if report.toAdd.isEmpty {
                Label("Everything recommended for this Mac is installed.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(report.toAdd, id: \.id) { recipe in addRow(recipe) }
            }
            Text("The Model Library checks Hugging Face for new releases every week and only lists models that fit this Mac and meet its speed-and-quality bar.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .alert("Remove \(removeTarget.map(\.name) ?? "model")?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button("Cancel", role: .cancel) { removeTarget = nil }
            Button("Remove \(removeTarget.map { ModelLibraryViewModel.bytes($0.bytes) } ?? "")", role: .destructive) {
                if let target = removeTarget { Task { await store.remove(target.id) } }
                removeTarget = nil
            }
        } message: {
            if let target = removeTarget {
                Text(target.usage.nodeCount > 0
                     ? "\(target.usage.nodeCount) node\(target.usage.nodeCount == 1 ? "" : "s") still use it and will need another model. Its files are deleted; workflows and generated media are kept."
                     : "No workflow uses it. Its files are deleted; workflows and generated media are kept.")
            }
        }
        .confirmationDialog("Remove \(unused.count) unused model\(unused.count == 1 ? "" : "s")?", isPresented: $confirmingBulkRemoval, titleVisibility: .visible) {
            Button("Remove \(ModelLibraryViewModel.bytes(unused.reduce(0) { $0 + $1.bytes }))", role: .destructive) {
                let ids = unused.map(\.id)
                Task { for id in ids { await store.remove(id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unused.map { "• \($0.name) (\(ModelLibraryViewModel.bytes($0.bytes)))" }.joined(separator: "\n")
                 + "\n\nNo workflow uses these. Their files are deleted; workflows and generated media are kept.")
        }
    }

    // MARK: pieces

    @ViewBuilder private func summary(report: ModelAdviceReport, kept: Int, unused: [ModelAdvice], locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if report.reclaimableBytes > 0 {
                Text("Free up to \(ModelLibraryViewModel.bytes(report.reclaimableBytes))").font(.headline)
                Text("\(kept) model\(kept == 1 ? "" : "s") to keep. The others can't be used here or aren't needed; each says why.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !report.advice.isEmpty {
                Label("Every installed model is right for this Mac.", systemImage: "checkmark.seal").font(.callout)
            } else {
                Text("No models installed yet. Discover below lists what this Mac should have.").font(.caption).foregroundStyle(.secondary)
            }
            if !unused.isEmpty {
                Button("Remove \(unused.count) unused (\(ModelLibraryViewModel.bytes(unused.reduce(0) { $0 + $1.bytes })))…", role: .destructive) { confirmingBulkRemoval = true }
                    .disabled(locked)
                    .help(locked ? "Wait for the current download or generation to finish." : "Remove models no workflow uses that can't be used here or aren't needed.")
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func group<Content: View>(_ title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(tint)
            content()
        }
        .padding(.vertical, Space.xs)
    }

    private func row(_ item: ModelAdvice, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(2)
                Spacer(minLength: Space.xs)
                Text(ModelLibraryViewModel.bytes(item.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(item.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .help(item.detail ?? "")
            if item.usage.nodeCount > 0 {
                Text("Used by \(item.usage.nodeCount) node\(item.usage.nodeCount == 1 ? "" : "s") in \(item.usage.workflowNames.joined(separator: ", ")).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let measured = item.measured {
                Text(measured).font(.caption2).foregroundStyle(.secondary)
            }
            if item.status != .keep {
                HStack(spacing: Space.sm) {
                    if let replacement = item.replacementRecipeID {
                        let movable = model.switchableNodeCount(from: item.id, to: replacement)
                        if movable > 0 {
                            Button("Move \(movable) node\(movable == 1 ? "" : "s") to \(Self.shortName(replacement))") { model.switchNodes(from: item.id, to: replacement) }
                                .help("Points those nodes at \(Self.shortName(replacement)), keeping each clip's length and shape. Undo restores them.")
                        }
                    }
                    Button("Remove…", role: .destructive) { removeTarget = item }
                        .disabled(locked)
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func missingRow(_ missing: MissingModelReference, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(missing.nodeCount) node\(missing.nodeCount == 1 ? "" : "s") in \(missing.workflowNames.joined(separator: ", ")) use \(Self.shortName(missing.modelID)), which isn't installed, so they can't run.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let replacement = missing.replacementRecipeID {
                Button("Use \(Self.shortName(replacement)) instead") { model.switchNodes(from: missing.modelID, to: replacement) }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Points those nodes at the installed \(Self.shortName(replacement)). Undo restores them.")
            }
        }
    }

    /// Install sits on the trailing edge of the row, as on the Model Library page. Downloads may run during a
    /// generation, and a second Install while one downloads joins the queue.
    private func addRow(_ recipe: ModelRecipe) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.shortName(recipe.id, fallback: recipe.name)).font(.callout.weight(.medium))
                if let verdict = MacFitStandard.verdict(forSubject: "recipe:\(recipe.id)") {
                    Text(verdict.speed).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(verdict.speed)
                }
            }
            Spacer(minLength: Space.xs)
            ModelInstallControl(store: model.libraryStore, recipe: recipe, size: .compact)
        }
        .padding(.vertical, 2)
    }

    static func shortName(_ recipeID: String, fallback: String? = nil) -> String {
        ModelAdvisor.displayName(recipeID) ?? fallback ?? recipeID
    }
}
