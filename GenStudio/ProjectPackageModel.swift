import AppKit
import Foundation
import UniformTypeIdentifiers

/// Shown after a package is written: the project can now leave the app's library, because the package
/// holds the workflow and its last results.
struct PackageOffer: Identifiable {
    let id = UUID()
    let projectID: UUID
    let projectName: String
    let packageFile: URL
    let summary: String
}

extension StudioModel {
    static let packageContentType = UTType(filenameExtension: ProjectPackage.fileExtension) ?? .json

    /// The result each node is currently showing, ready to copy: the selected take for generation nodes,
    /// the latest result for other nodes that generate. Earlier takes and run history stay behind.
    func packageResultSources(for project: WorkflowProject) -> [ProjectPackager.ResultSource] {
        var sources: [ProjectPackager.ResultSource] = []
        for node in project.nodes {
            // A locked node's file is its result, wherever the take it came from now lives.
            if node.isLockedFinal, let record = node.finalized, record.kind != .text, let home = home(for: project), let port = node.outputPorts.first {
                let address = PortAddress(nodeID: node.id, portID: port.id)
                let take = currentArtifact(for: node, in: project)
                sources.append(.init(nodeID: node.id, createdAt: record.lockedAt, node: take?.graphSnapshot.nodes.first { $0.id == node.id } ?? node,
                                     values: [address: home.value(of: record)], mediaProvenance: take?.mediaProvenance?[node.id], mediaNames: nil,
                                     isSelectedTake: true, displayNames: [address: (record.path as NSString).lastPathComponent]))
                continue
            }
            guard let chosen = currentArtifact(for: node, in: project) else { continue }
            let values = chosen.values.filter { $0.key.nodeID == node.id }
            guard !values.isEmpty else { continue }
            let snapshot = chosen.graphSnapshot.nodes.first { $0.id == node.id } ?? node
            let names = chosen.mediaNames?.filter { $0.key.hasPrefix(node.id.uuidString) }
            var displayNames: [PortAddress: String] = [:]
            for address in values.keys {
                displayNames[address] = chosen.mediaNames?[Self.galleryMediaKey(address)]
                    ?? "\(snapshot.label) · \(chosen.createdAt.formatted(date: .abbreviated, time: .shortened))"
            }
            sources.append(.init(nodeID: node.id, createdAt: chosen.createdAt, node: snapshot, values: values,
                                 mediaProvenance: chosen.mediaProvenance?[node.id],
                                 mediaNames: names?.isEmpty == false ? names : nil,
                                 isSelectedTake: node.selectedTakeID == chosen.id, displayNames: displayNames))
        }
        return sources
    }

    /// The models the workflow's nodes are set to, one entry each, with what is known about where they come from.
    func packageModelUsages(for project: WorkflowProject) -> [ModelUsage] {
        var order: [String] = []
        var usages: [String: ModelUsage] = [:]
        for node in project.nodes where node.kind.usesModel && !node.model.isEmpty {
            let label = node.label == node.kind.title ? node.label : "\(node.label) (\(node.kind.title))"
            if usages[node.model] != nil { usages[node.model]?.usedBy.append(label); continue }
            let installed = libraryStore.installed.first { $0.id == node.model }
            let recipe = installed?.recipeSnapshot
            usages[node.model] = ModelUsage(
                id: node.model, name: installed?.name ?? recipe?.name ?? node.model,
                kind: installed.map { $0.kind.rawValue.capitalized } ?? "Unknown", engine: installed?.engineID,
                provider: recipe?.provider, sourceURL: recipe?.sourceURL?.absoluteString,
                components: (recipe?.components ?? []).map {
                    .init(role: $0.role, repository: $0.repository, revision: $0.revision, filename: $0.filename, license: $0.license, byteSize: $0.byteSize)
                },
                usedBy: [label])
            order.append(node.model)
        }
        return order.compactMap { usages[$0] }
    }

    /// Asks for a folder, then writes `<name>.genstudio` and a `Links` folder into it.
    func packageProject(_ id: UUID? = nil) {
        guard !isPackaging, let project = projects.first(where: { $0.id == (id ?? currentProjectID) }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Package"
        panel.message = "Choose or create the folder for “\(project.name)”. The workflow is saved there with a Links folder holding its inputs and last generations."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        isPackaging = true
        Task {
            await flushProjectWrites()
            let latest = projects.first { $0.id == project.id } ?? project
            let sources = packageResultSources(for: latest)
            let models = packageModelUsages(for: latest)
            let (stem, ext) = ProjectPackager.split(latest.name, fallbackExtension: ProjectPackage.fileExtension)
            let fileName = stem + ext
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let report = try ProjectPackager().write(project: latest, results: sources, models: models, to: folder, fileName: fileName)
                    // Only offer to remove the original once the file reads back cleanly.
                    _ = try ProjectPackageReader.read(report.packageFile)
                    return report
                }.value
                isPackaging = false
                packageOffer = PackageOffer(projectID: latest.id, projectName: latest.name, packageFile: report.packageFile,
                                            summary: Self.summary(of: report, folder: folder))
            } catch {
                isPackaging = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private static func summary(of report: ProjectPackager.Report, folder: URL) -> String {
        var text = "Saved to “\(folder.lastPathComponent)”: the workflow, \(report.linkedFiles) linked file\(report.linkedFiles == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file))) and \(report.resultCount) last result\(report.resultCount == 1 ? "" : "s")."
        if report.modelCount > 0 { text += " A “\(ModelsUsedFile.fileName)” list names the \(report.modelCount) model\(report.modelCount == 1 ? "" : "s") it uses; the models themselves are not included." }
        if !report.missing.isEmpty {
            text += "\n\n\(report.missing.count) linked file\(report.missing.count == 1 ? " was" : "s were") no longer on disk and could not be included:\n" + report.missing.prefix(5).map { "• " + $0 }.joined(separator: "\n")
            if report.missing.count > 5 { text += "\n• …and \(report.missing.count - 5) more" }
        }
        return text + "\n\nRemove it from GenStudio? The package keeps the workflow and its media; open the .genstudio file any time to bring it back."
    }

    /// Takes a packaged project out of the app: the workflow, its generations and the app's copies of their
    /// media. Files in the package folder and files you imported from elsewhere are never touched.
    func removeFromLibrary(_ projectID: UUID) async {
        guard !isRunning else { alertMessage = "Wait for the current run to finish before removing a workflow."; return }
        await flushProjectWrites()
        let artifactIDs = Set(executionArtifacts.filter { $0.projectID == projectID || $0.graphSnapshot.id == projectID }.map(\.id))
        let outputIDs = Set(outputs.filter { $0.projectID == projectID }.map(\.id))
        let runIDs = Set(runs.filter { $0.snapshot.projectID == projectID }.map(\.id))
        await deleteGalleryItems(outputIDs: outputIDs, artifactIDs: artifactIDs)
        await deleteHistoryItems(runIDs)
        await deleteProject(projectID)
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Opens a `.genstudio` file as a new workflow in the library, its last results showing as they were.
    func openPackage(_ url: URL? = nil) {
        var file = url
        if file == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [Self.packageContentType]
            panel.allowsMultipleSelection = false
            panel.message = "Choose a GenStudio project file (.genstudio). Keep its Links folder next to it."
            guard panel.runModal() == .OK else { return }
            file = panel.url
        }
        guard let file else { return }
        do {
            var opened = try ProjectPackageReader.read(file)
            let folder = file.deletingLastPathComponent().standardizedFileURL.path
            // The project is already open from this folder: show it instead of adding a copy.
            if let existing = projects.first(where: { $0.id == opened.sourceProjectID && $0.homeFolder == folder }) {
                selectProject(existing.id)
                return
            }
            opened.project.name = uniqueProjectName(opened.project.name)
            // Opened from its folder, the project keeps working there, unless another project already owns that folder.
            if !projects.contains(where: { $0.homeFolder == folder }) { opened.project.homeFolder = folder }
            adoptImportedProject(opened.project)
            executionArtifacts.append(contentsOf: opened.artifacts)
            executionArtifacts.sort { $0.createdAt > $1.createdAt }
            persistArtifacts(opened.artifacts)
            if !opened.missing.isEmpty {
                alertMessage = "Opened “\(opened.project.name)”, but \(opened.missing.count) linked file\(opened.missing.count == 1 ? " is" : "s are") missing:\n"
                    + opened.missing.prefix(5).map { "• " + $0 }.joined(separator: "\n")
                    + (opened.missing.count > 5 ? "\n• …and \(opened.missing.count - 5) more" : "")
                    + "\n\nPut the Links folder back next to \(file.lastPathComponent) and open it again."
            }
        } catch { alertMessage = error.localizedDescription }
    }
}
