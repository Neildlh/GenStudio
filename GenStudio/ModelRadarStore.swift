import Foundation
import SwiftUI

/// Runs a radar check on demand and exposes the result to the Model Library.
///
/// The check has two stages, and the first is useful on its own: live facts from Hugging Face
/// appear as soon as they arrive, and only then does a writer (a local model, Apple Intelligence,
/// or neither) add wording. Tier and fit are recomputed from the current library on every read,
/// so installing a model re-tiers the list without another check.
@MainActor
final class ModelRadarStore: ObservableObject {
    @Published private(set) var snapshot: RadarSnapshot?
    @Published private(set) var checking = false
    @Published private(set) var phase = ""
    @Published private(set) var failure: String?

    private unowned let host: ModelLibraryViewModel
    private let service: ModelRadarService
    private var task: Task<Void, Never>?
    private var loadedCache = false

    init(host: ModelLibraryViewModel, service: ModelRadarService = ModelRadarService()) {
        self.host = host
        self.service = service
    }

    /// The families, tiers and fit for the current library. Cheap: no I/O beyond capability lookups.
    var reports: [RadarFamilyReport] {
        let host = self.host
        let inputs = RadarInputs(
            recipe: { id in host.modelRecipes.first { $0.id == id } },
            assess: { host.compatibility($0) },
            proven: { host.hasOperationalProof($0, category: .all, task: .all) },
            installed: Set(host.installed.filter(\.available).map(\.id)),
            hardware: host.hardware)
        return ModelRadar.report(snapshot: snapshot, inputs: inputs)
    }

    /// What the Model Library shows: only models assessed against the speed-and-quality bar for this Mac.
    /// Nothing else is displayed or handed to a writer.
    var presentation: RadarPresentation { MacFitStandard.present(reports) }

    /// Writer notes, only if they were written about exactly the models shown now.
    var notes: RadarNotes? { snapshot?.notes(forVisible: presentation.families.flatMap(\.entries).map(\.id)) }

    /// Who would write the notes if a check ran now, shown beside the button so the choice is never hidden.
    var wordingSource: String {
        if let model = localWriterModel { return "\(model.name) will write the notes, on this Mac." }
        if AppleIntelligenceRadarWriter.isAvailable { return "Apple Intelligence will write the notes." }
        return "Built-in wording. Install the text + vision model from Start Here to have a local model write the notes."
    }

    // MARK: actions

    /// Shows the last saved check straight away, including offline.
    func loadCached() async {
        guard !loadedCache else { return }
        loadedCache = true
        if snapshot == nil { snapshot = await service.loadCached() }
    }

    /// Models change weekly, so the radar re-checks on its own when the last check is older than this.
    nonisolated static let automaticCheckInterval: TimeInterval = 7 * 86_400

    nonisolated static func needsAutomaticCheck(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= automaticCheckInterval
    }

    /// Called when the Model Library appears. A due check fetches facts only: the optional write-up loads a
    /// local language model, so it runs only when the owner presses "Check for new models".
    func checkIfDue() {
        guard !checking, Self.needsAutomaticCheck(lastChecked: snapshot?.fetchedAt) else { return }
        check(writeUp: false)
    }

    func check(writeUp: Bool = true) {
        guard !checking else { return }
        checking = true; failure = nil; phase = "Checking Hugging Face for new releases…"
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.checking = false; self.phase = ""; self.task = nil }
            do {
                var fresh = try await self.service.check()
                if fresh.isTotalFailure {
                    // Keep whatever was showing: an offline check must never empty the section.
                    self.failure = fresh.families.compactMap(\.error).first ?? "Hugging Face could not be reached."
                    return
                }
                self.snapshot = fresh
                await self.service.save(fresh)
                guard writeUp else { return }

                // The writer only ever sees models that met the bar; it cannot mention what it was never given.
                let entries = self.presentation.families.flatMap(\.entries)
                let writers = self.writers()
                if !writers.isEmpty && !entries.isEmpty {
                    self.phase = "Writing it up with \(writers[0].name)… the first run loads the model, so this can take a minute."
                }
                let written = await RadarWriting.compose(writers: writers, hardware: self.host.hardware, entries: entries)
                try Task.checkCancellation()
                fresh.summary = written.summary
                fresh.blurbs = written.blurbs
                fresh.writer = Self.attribution(written)
                fresh.writtenFor = entries.map(\.id)
                self.snapshot = fresh
                await self.service.save(fresh)
            } catch is CancellationError {
                self.failure = "Check cancelled."
            } catch {
                self.failure = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    // MARK: writers

    private var localWriterModel: InstalledGenerationModel? {
        guard !host.generationRunning, host.mlxRuntimeStatus.hasPrefix("Ready") else { return nil }
        return host.installedMultitaskModels.first
    }

    /// Preference order: a local model, then Apple Intelligence. The small llama.cpp text model is left
    /// out on purpose: the catalogue records that it failed local prompt-writing checks.
    private func writers() -> [any RadarWriter] {
        var result: [any RadarWriter] = []
        if let model = localWriterModel {
            result.append(MLXRadarWriter(library: host.library, modelID: model.id, name: "\(model.name) (on this Mac)"))
        }
        if AppleIntelligenceRadarWriter.isAvailable { result.append(AppleIntelligenceRadarWriter()) }
        return result
    }

    nonisolated static func attribution(_ written: RadarWritten) -> String {
        let notes = written.notes.joined(separator: " ")
        if let writer = written.writer {
            return "Notes written by \(writer)." + (notes.isEmpty ? "" : " " + notes)
        }
        return "Built-in wording." + (notes.isEmpty ? "" : " " + notes)
    }
}
