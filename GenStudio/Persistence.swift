import Foundation

actor StudioPersistence {
    nonisolated let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// The file name last written for each folder-bound project, so a rename can clean up the old one.
    private var mirroredNames: [UUID: String] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "GenStudio", directoryHint: .isDirectory)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private var projectsURL: URL { root.appending(path: "Projects", directoryHint: .isDirectory) }
    private var runsURL: URL { root.appending(path: "Runs", directoryHint: .isDirectory) }
    private var outputsURL: URL { root.appending(path: "Outputs", directoryHint: .isDirectory) }
    private var executionArtifactsURL: URL { root.appending(path: "ExecutionArtifacts", directoryHint: .isDirectory) }
    private var artifactsURL: URL { root.appending(path: "Artifacts", directoryHint: .isDirectory) }

    private func prepare() throws {
        for url in [projectsURL, runsURL, outputsURL, executionArtifactsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            try prepare()
            try encoder.encode(value).write(to: url, options: [.atomic])
        } catch {
            throw StudioError.persistence(error.localizedDescription)
        }
    }

    func saveProject(_ project: WorkflowProject) throws {
        guard !FileManager.default.fileExists(atPath: projectsURL.appending(path: "\(project.id.uuidString).deleted").path) else { return }
        _ = try GraphValidator().validate(project, installedModels: nil, requireRunnableInputs: false)
        let nodes = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
        var persisted = project
        persisted.edges = try project.edges.map { try GraphValidator().resolved($0, nodes: nodes) }
        try write(persisted, to: projectsURL.appending(path: "\(project.id.uuidString).json"))
    }

    func deleteProject(_ id: UUID) throws {
        try prepare()
        let tombstone = projectsURL.appending(path: "\(id.uuidString).deleted")
        let document = projectsURL.appending(path: "\(id.uuidString).json")
        try Data().write(to: tombstone, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: document.path) { try FileManager.default.removeItem(at: document) }
        } catch {
            try? FileManager.default.removeItem(at: tombstone)
            throw StudioError.persistence(error.localizedDescription)
        }
    }

    func loadProjects() throws -> [WorkflowProject] {
        try prepare()
        let urls = try FileManager.default.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try urls.filter { !FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("deleted").path) }.map { url in
            do {
                let project = try decoder.decode(WorkflowProject.self, from: Data(contentsOf: url))
                guard project.schemaVersion == WorkflowProject.schemaVersion else { throw StudioError.unsupportedSchema(project.schemaVersion) }
                _ = try GraphValidator().validate(project, installedModels: nil, requireRunnableInputs: false)
                return project
            } catch let error as StudioError {
                throw error
            } catch {
                throw StudioError.malformedData("\(url.lastPathComponent): \(error.localizedDescription). The file was left untouched.")
            }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveRun(_ run: RunRecord) throws { try write(run, to: runsURL.appending(path: "\(run.id.uuidString).json")) }
    func saveOutput(_ output: TextOutput) throws { try write(output, to: outputsURL.appending(path: "\(output.id.uuidString).json")) }
    func saveExecutionArtifact(_ artifact: ExecutionArtifact) throws { try write(artifact, to: executionArtifactsURL.appending(path: "\(artifact.id.uuidString).json")) }

    func deleteRuns(_ ids: Set<UUID>) throws {
        for id in ids { try removeRecord(at: runsURL.appending(path: "\(id.uuidString).json")) }
    }

    func deleteOutput(_ id: UUID) throws {
        try deleteGalleryItems(outputIDs: [id], artifacts: [])
    }

    func deleteExecutionArtifact(_ artifact: ExecutionArtifact, preserving values: [RuntimeValue] = []) throws {
        try deleteGalleryItems(outputIDs: [], artifacts: [artifact], preserving: values)
    }

    func deleteGalleryItems(outputIDs: Set<UUID>, artifacts: [ExecutionArtifact], preserving values: [RuntimeValue] = []) throws {
        let artifactIDs = Set(artifacts.map(\.id))
        let remaining = try loadExecutionArtifacts().filter { !artifactIDs.contains($0.id) }
        for id in outputIDs { try removeRecord(at: outputsURL.appending(path: "\(id.uuidString).json")) }
        for id in artifactIDs { try removeRecord(at: executionArtifactsURL.appending(path: "\(id.uuidString).json")) }

        let protected = Set((remaining.flatMap { Array($0.values.values) } + values).flatMap(mediaURLs).map(normalizedPath))
        let candidates = Set(artifacts.flatMap { Array($0.values.values) }.flatMap(mediaURLs).map(normalizedPath))
        for path in candidates.subtracting(protected) where isRetainedArtifact(path) {
            // The gallery record is already gone. A failed best-effort cleanup must not
            // make the deleted result reappear or risk another result's shared media.
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    private func removeRecord(at url: URL) throws {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        } catch {
            throw StudioError.persistence(error.localizedDescription)
        }
    }

    private func mediaURLs(in value: RuntimeValue) -> [URL] {
        switch value {
        case .image(let url), .video(let url): [url]
        case .shotSequence(let sequence): sequence.anchors.map(\.image)
        case .text, .textArray, .number: []
        }
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isRetainedArtifact(_ path: String) -> Bool {
        let rootPath = normalizedPath(artifactsURL)
        return path.hasPrefix(rootPath + "/")
    }

    func loadRuns(recoverInterrupted: Bool = true) throws -> [RunRecord] {
        try prepare()
        let urls = try FileManager.default.contentsOfDirectory(at: runsURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        var result: [RunRecord] = []
        for url in urls {
            do {
                var run = try decoder.decode(RunRecord.self, from: Data(contentsOf: url))
                if recoverInterrupted && (run.status == .queued || run.status == .running) {
                    run.status = .interrupted
                    run.finishedAt = Date()
                    run.error = "The app closed before this run completed."
                    try write(run, to: url)
                }
                result.append(run)
            } catch let error as StudioError { throw error }
            catch { throw StudioError.malformedData("\(url.lastPathComponent): \(error.localizedDescription). The file was left untouched.") }
        }
        return result.sorted { $0.queuedAt > $1.queuedAt }
    }

    func loadOutputs() throws -> [TextOutput] {
        try prepare()
        let urls = try FileManager.default.contentsOfDirectory(at: outputsURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try urls.map { url in
            do { return try decoder.decode(TextOutput.self, from: Data(contentsOf: url)) }
            catch { throw StudioError.malformedData("\(url.lastPathComponent): \(error.localizedDescription). The file was left untouched.") }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func loadExecutionArtifacts() throws -> [ExecutionArtifact] {
        try prepare()
        let urls = try FileManager.default.contentsOfDirectory(at: executionArtifactsURL, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try urls.map { url in
            do { return try decoder.decode(ExecutionArtifact.self, from: Data(contentsOf: url)) }
            catch { throw StudioError.malformedData("\(url.lastPathComponent): \(error.localizedDescription). The file was left untouched.") }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func exportProject(_ project: WorkflowProject, to url: URL) throws { try write(project, to: url) }

    /// Writes a folder-bound project's `.genstudio` file into its project folder.
    func mirror(_ project: WorkflowProject, models: [ModelUsage]) throws {
        let name = ProjectMirror.fileName(for: project)
        try ProjectMirror.write(project, models: models, cleanStale: mirroredNames[project.id] != name)
        mirroredNames[project.id] = name
    }
}


enum MediaExport {
    static func copy(source: URL, destination: URL) throws {
        let manager = FileManager.default
        let sourceURL = source.standardizedFileURL.resolvingSymlinksInPath()
        let destinationURL = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard sourceURL != destinationURL else { return }
        if manager.fileExists(atPath: destinationURL.path) {
            let sourceAttributes = try manager.attributesOfItem(atPath: sourceURL.path)
            let destinationAttributes = try manager.attributesOfItem(atPath: destinationURL.path)
            if let sourceNumber = sourceAttributes[.systemFileNumber] as? NSNumber,
               let destinationNumber = destinationAttributes[.systemFileNumber] as? NSNumber,
               sourceNumber == destinationNumber,
               sourceAttributes[.systemNumber] as? NSNumber == destinationAttributes[.systemNumber] as? NSNumber { return }
        }
        let staged = destinationURL.deletingLastPathComponent().appending(path: ".genstudio-export-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: sourceURL, to: staged)
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(destinationURL, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destinationURL)
        }
    }
}
