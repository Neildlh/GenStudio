import Foundation

/// A finished project saved as an ordinary folder: a small `.genstudio` file next to a `Links` folder,
/// the way InDesign packages a document. The file holds the workflow and each node's last result; the
/// media those results and inputs point at sits in `Links`. Models are never included, and neither are
/// earlier takes or run history.
///
/// Paths inside the file are relative to the folder, so the folder can be moved, zipped or backed up.
struct ProjectPackage: Codable, Sendable {
    static let formatVersion = 1
    static let fileExtension = "genstudio"
    static let linksFolder = "Links"

    var formatVersion = Self.formatVersion
    var appVersion: String
    var packagedAt: Date
    /// The workflow with every media path rewritten to `Links/<name>`.
    var project: WorkflowProject
    var results: [PackagedResult]
}

/// One node's current generation: the take it shows, with the names you gave its media.
struct PackagedResult: Codable, Hashable, Sendable {
    struct Value: Codable, Hashable, Sendable { var portID: String; var value: RuntimeValue }

    var nodeID: UUID
    var createdAt: Date
    /// The node as it was configured when this result ran (seed, model, size).
    var node: StudioNode
    var values: [Value]
    var mediaProvenance: RenderedMediaProvenance?
    /// Keyed `<nodeID>/<portID>`, the same key the sidebar's Images section uses.
    var mediaNames: [String: String]?
    /// True when this was the take the node was displaying.
    var isSelectedTake: Bool
}

/// Where a link lives inside the package. Media URLs inside results use a sentinel root because they are
/// typed `URL`s; plain path strings in nodes use the relative `Links/...` form directly.
enum PackageLinks {
    static let sentinelRoot = "/.genstudio-package"

    static func relativePath(forName name: String) -> String { "\(ProjectPackage.linksFolder)/\(name)" }

    static func packaged(_ relative: String) -> URL { URL(fileURLWithPath: sentinelRoot + "/" + relative) }

    /// The real location of a packaged link, or nil when the URL is not a packaged link.
    static func resolved(_ url: URL, in folder: URL) -> URL? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(sentinelRoot + "/") else { return nil }
        return folder.appending(path: String(path.dropFirst(sentinelRoot.count + 1)))
    }

    static func resolved(path: String, in folder: URL) -> String {
        guard path.hasPrefix(ProjectPackage.linksFolder + "/") else { return path }
        return folder.appending(path: path).path
    }
}

extension RuntimeValue {
    /// Every media file this value refers to.
    var mediaFiles: [URL] {
        switch self {
        case .image(let url), .video(let url): [url]
        case .shotSequence(let sequence): sequence.anchors.map(\.image)
        case .text, .textArray, .number: []
        }
    }

    /// The same value with each media URL replaced. Returns nil if `transform` cannot supply one.
    func mappingMedia(_ transform: (URL, _ label: String?) throws -> URL?) rethrows -> RuntimeValue? {
        switch self {
        case .image(let url):
            return try transform(url, nil).map { RuntimeValue.image($0) }
        case .video(let url):
            return try transform(url, nil).map { RuntimeValue.video($0) }
        case .shotSequence(let sequence):
            var anchors: [ResolvedShotSequence.Anchor] = []
            for anchor in sequence.anchors {
                guard let image = try transform(anchor.image, anchor.label) else { return nil }
                anchors.append(.init(anchorID: anchor.anchorID, label: anchor.label, image: image, identity: anchor.identity,
                                     transitionNote: anchor.transitionNote, boundaryToNext: anchor.boundaryToNext))
            }
            return .shotSequence(.init(anchors: anchors, timing: sequence.timing, width: sequence.width, height: sequence.height))
        case .text, .textArray, .number:
            return self
        }
    }
}

extension StudioNode {
    /// The same node with each stored media path replaced; nil from `transform` leaves that path alone.
    func mappingPaths(_ transform: (String) throws -> String?) rethrows -> StudioNode {
        var copy = self
        if let path = copy.imagePath, let mapped = try transform(path) { copy.imagePath = mapped }
        if let path = copy.videoPath, let mapped = try transform(path) { copy.videoPath = mapped }
        if copy.sequenceSpec != nil {
            for index in copy.sequenceSpec!.anchors.indices {
                if let path = copy.sequenceSpec!.anchors[index].imagePath, let mapped = try transform(path) {
                    copy.sequenceSpec!.anchors[index].imagePath = mapped
                }
            }
        }
        return copy
    }

    var storedMediaPaths: [String] {
        [imagePath, videoPath].compactMap { $0 } + (sequenceSpec?.anchors.compactMap(\.imagePath) ?? [])
    }
}

/// One model a workflow relies on. Only a description is saved, never the weights, so someone can install
/// the same model on another Mac from the Model Library.
struct ModelUsage: Hashable, Sendable {
    struct Component: Hashable, Sendable {
        var role: String
        var repository: String
        var revision: String
        var filename: String
        var license: String
        var byteSize: Int64
    }

    var id: String
    var name: String
    var kind: String
    var engine: String?
    var provider: String?
    var sourceURL: String?
    /// Empty when the model was not installed on this Mac, so only its id is known.
    var components: [Component]
    /// The nodes that use it, e.g. "Hero (Image Generator)".
    var usedBy: [String]
}

/// The plain-text "Models Used" list saved beside the project, like the font list InDesign's Package writes.
enum ModelsUsedFile {
    static let fileName = "Models Used.txt"

    /// Repeats collapse into counts ("Image Generator ×6") and a long list stops after a few names, so a large
    /// workflow still reads at a glance.
    static func usedByText(_ names: [String], limit: Int = 6) -> String {
        var order: [String] = [], counts: [String: Int] = [:]
        for name in names { if counts[name] == nil { order.append(name) }; counts[name, default: 0] += 1 }
        let shown = order.prefix(limit).map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }
        let hidden = order.dropFirst(limit).reduce(0) { $0 + counts[$1]! }
        let total = names.count
        return shown.joined(separator: ", ") + (hidden > 0 ? ", and \(hidden) more" : "") + (total > shown.count ? "  (\(total) nodes)" : "")
    }

    static func text(projectName: String, models: [ModelUsage], packagedAt: Date, appVersion: String) -> String {
        var lines = [
            "Models used by “\(projectName)”",
            "Packaged \(packagedAt.formatted(date: .long, time: .shortened)) with GenStudio \(appVersion)",
            "",
            "Model files are not included in a package. To run this workflow on another Mac, install",
            "these models from GenStudio's Model Library, or download them from the sources below.",
        ]
        for (index, model) in models.enumerated() {
            lines += ["", "\(index + 1). \(model.name)", "   Used by: \(usedByText(model.usedBy))", "   Type:    \(model.kind)" + (model.engine.map { " · \($0)" } ?? ""), "   ID:      \(model.id)"]
            if let provider = model.provider, !provider.isEmpty { lines.append("   From:    \(provider)") }
            if let source = model.sourceURL, !source.isEmpty { lines.append("   Source:  \(source)") }
            if model.components.isEmpty {
                lines.append("   (Not installed on the Mac that made this package, so only its id is known.)")
                continue
            }
            lines.append("   Files:")
            for component in model.components {
                let size = ByteCountFormatter.string(fromByteCount: component.byteSize, countStyle: .file)
                let revision = component.revision.isEmpty ? "" : " @ \(String(component.revision.prefix(12)))"
                lines.append("     - \(component.filename)  (\(component.role), \(size), \(component.license))")
                lines.append("       \(component.repository)\(revision)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Copies a project's linked media into a folder and writes the package file. Pure file work, so it runs
/// off the main actor and is tested without the app model.
struct ProjectPackager: Sendable {
    struct ResultSource: Sendable {
        var nodeID: UUID
        var createdAt: Date
        var node: StudioNode
        var values: [PortAddress: RuntimeValue]
        var mediaProvenance: RenderedMediaProvenance?
        var mediaNames: [String: String]?
        var isSelectedTake: Bool
        /// The name the sidebar shows for each media port; becomes the file name inside `Links`.
        var displayNames: [PortAddress: String]
    }

    struct Report: Sendable {
        var packageFile: URL
        var linkedFiles = 0
        var totalBytes: Int64 = 0
        var resultCount = 0
        var modelCount = 0
        /// Files the workflow referred to that no longer exist. Their paths are left as they were.
        var missing: [String] = []
    }

    var appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func write(project: WorkflowProject, results: [ResultSource], models: [ModelUsage] = [], to folder: URL, fileName: String) throws -> Report {
        let manager = FileManager.default
        let links = folder.appending(path: ProjectPackage.linksFolder, directoryHint: .isDirectory)
        do { try manager.createDirectory(at: links, withIntermediateDirectories: true) }
        catch { throw StudioError.persistence("Could not create the package folder: \(error.localizedDescription)") }

        var report = Report(packageFile: folder.appending(path: fileName))
        var placed: [String: String] = [:]   // resolved source path → name inside Links
        var reportedMissing = Set<String>()

        let home = ProjectHome(root: folder)
        /// Returns where the file sits inside `Links`, e.g. `images/Hero.png`, copying it in when it is not already there.
        func place(_ source: URL, preferredName: String) throws -> String? {
            let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
            if let name = placed[resolved.path] { return name }
            guard manager.fileExists(atPath: resolved.path) else {
                if reportedMissing.insert(resolved.path).inserted { report.missing.append(resolved.path) }
                return nil
            }
            // A file already in this project's Links folder, such as a locked final, stays exactly where it is.
            if let inside = home.relativePath(of: resolved) {
                let name = String(inside.dropFirst(ProjectPackage.linksFolder.count + 1))
                placed[resolved.path] = name
                return name
            }
            let (stem, ext) = Self.split(preferredName, fallbackExtension: resolved.pathExtension)
            let subfolder = LinkKind.kind(forExtension: resolved.pathExtension).map { $0.folderName + "/" } ?? ""
            var ordinal = 1
            while true {
                let name = subfolder + (ordinal == 1 ? "\(stem)\(ext)" : "\(stem)-\(ordinal)\(ext)")
                let destination = links.appending(path: name)
                if !manager.fileExists(atPath: destination.path) {
                    do { try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true) }
                    catch { throw StudioError.persistence("Could not create the Links folder: \(error.localizedDescription)") }
                    try Self.copy(resolved, to: destination)
                    report.linkedFiles += 1
                    report.totalBytes += Self.size(of: destination)
                    placed[resolved.path] = name
                    return name
                }
                if destination.standardizedFileURL.resolvingSymlinksInPath() == resolved || manager.contentsEqual(atPath: resolved.path, andPath: destination.path) {
                    placed[resolved.path] = name
                    return name
                }
                ordinal += 1
            }
        }

        // Results first so their names, which you chose, win any clash over an input's file name.
        var packagedResults: [PackagedResult] = []
        for source in results.sorted(by: { $0.createdAt > $1.createdAt }) {
            var values: [PackagedResult.Value] = []
            for (address, value) in source.values.sorted(by: { $0.key.portID < $1.key.portID }) {
                let base = source.displayNames[address] ?? source.node.label
                let mapped = try value.mappingMedia { url, label in
                    let preferred = label.map { "\(base) - \($0)" } ?? base
                    return try place(url, preferredName: preferred).map { PackageLinks.packaged(PackageLinks.relativePath(forName: $0)) }
                }
                if let mapped { values.append(.init(portID: address.portID, value: mapped)) }
            }
            guard !values.isEmpty else { continue }
            let snapshot = try source.node.mappingPaths { path in
                try place(URL(fileURLWithPath: path), preferredName: URL(fileURLWithPath: path).lastPathComponent).map(PackageLinks.relativePath(forName:))
            }
            var node = snapshot; node.selectedTakeID = nil
            packagedResults.append(.init(nodeID: source.nodeID, createdAt: source.createdAt, node: node, values: values,
                                         mediaProvenance: source.mediaProvenance, mediaNames: source.mediaNames, isSelectedTake: source.isSelectedTake))
        }
        report.resultCount = packagedResults.count

        var packagedProject = project
        packagedProject.homeFolder = nil
        packagedProject.nodes = try project.nodes.map { node in
            var mapped = try node.mappingPaths { path in
                let url = URL(fileURLWithPath: path)
                return try place(url, preferredName: url.lastPathComponent).map(PackageLinks.relativePath(forName:))
            }
            mapped.selectedTakeID = nil
            return mapped
        }

        let package = ProjectPackage(appVersion: appVersion, packagedAt: Date(), project: packagedProject, results: packagedResults)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(package).write(to: report.packageFile, options: .atomic) }
        catch { throw StudioError.persistence("Could not write \(fileName): \(error.localizedDescription)") }
        if !models.isEmpty {
            let list = ModelsUsedFile.text(projectName: project.name, models: models, packagedAt: package.packagedAt, appVersion: appVersion)
            do { try Data(list.utf8).write(to: folder.appending(path: ModelsUsedFile.fileName), options: .atomic) }
            catch { throw StudioError.persistence("Could not write \(ModelsUsedFile.fileName): \(error.localizedDescription)") }
            report.modelCount = models.count
        }
        return report
    }

    /// A safe file stem and extension for a name shown in the app. Keeps an extension the name already has.
    static func split(_ name: String, fallbackExtension: String) -> (stem: String, ext: String) {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "Untitled" }
        let existing = (cleaned as NSString).pathExtension
        let wanted = fallbackExtension.isEmpty ? existing : fallbackExtension
        if !wanted.isEmpty, existing.caseInsensitiveCompare(wanted) == .orderedSame {
            cleaned = (cleaned as NSString).deletingPathExtension
        }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
        return (cleaned, wanted.isEmpty ? "" : ".\(wanted)")
    }

    static func copy(_ source: URL, to destination: URL) throws {
        do { try MediaExport.copy(source: source, destination: destination) }
        catch { throw StudioError.persistence("Could not copy \(source.lastPathComponent) into the package: \(error.localizedDescription)") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue,
           size(of: source) != size(of: destination) {
            try? FileManager.default.removeItem(at: destination)
            throw StudioError.persistence("\(source.lastPathComponent) was not copied completely. Check the free space on the destination.")
        }
    }

    private static func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

/// A package read back into the pieces the app adopts. Every identity is new, so opening a package never
/// collides with the same project still in the library. Media stays where it is, in the package's `Links`.
struct OpenedPackage {
    /// The id the project had in the file, before it was given a new one.
    var sourceProjectID: UUID
    var project: WorkflowProject
    var artifacts: [ExecutionArtifact]
    var missing: [String]
}

enum ProjectPackageReader {
    static func read(_ file: URL) throws -> OpenedPackage {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch { throw StudioError.malformedData("\(file.lastPathComponent): \(error.localizedDescription)") }
        struct Header: Decodable { var formatVersion: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), let version = header.formatVersion else {
            throw StudioError.malformedData("\(file.lastPathComponent) is not a GenStudio project file.")
        }
        guard version <= ProjectPackage.formatVersion else {
            throw StudioError.validation("\(file.lastPathComponent) was saved by a newer GenStudio (package format \(version)). Update GenStudio to open it.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package: ProjectPackage
        do { package = try decoder.decode(ProjectPackage.self, from: data) }
        catch let error as StudioError { throw error }
        catch { throw StudioError.malformedData("\(file.lastPathComponent): \(error.localizedDescription). The file was left untouched.") }

        let folder = file.deletingLastPathComponent()
        var missing: [String] = []
        func note(_ path: String) { if !FileManager.default.fileExists(atPath: path), !missing.contains(path) { missing.append(path) } }
        let resolvePath: (String) -> String? = { path in
            let resolved = PackageLinks.resolved(path: path, in: folder)
            return resolved == path ? nil : resolved
        }

        var project = package.project
        let sourceProjectID = project.id
        project.homeFolder = nil
        project.nodes = project.nodes.map { node in var mapped = node.mappingPaths(resolvePath); mapped.selectedTakeID = nil; return mapped }
        for node in project.nodes { node.storedMediaPaths.forEach(note) }
        let home = ProjectHome(root: folder)
        for node in project.nodes { if let record = node.finalized, home.isMissing(record) { note(home.url(for: record.path).path) } }

        // New identity throughout; socket ids stay, because they are only unique within a node and other
        // settings (reference roles) are keyed by them.
        var idMap: [UUID: UUID] = [:]
        project.id = UUID(); project.createdAt = Date(); project.updatedAt = project.createdAt
        for index in project.nodes.indices {
            let fresh = UUID(); idMap[project.nodes[index].id] = fresh; project.nodes[index].id = fresh
        }
        project.edges = project.edges.compactMap { original in
            guard let source = idMap[original.sourceID], let target = idMap[original.targetID] else { return nil }
            var edge = original; edge.id = UUID(); edge.sourceID = source; edge.targetID = target
            return edge
        }

        var artifacts: [ExecutionArtifact] = []
        for result in package.results {
            guard let nodeID = idMap[result.nodeID], let nodeIndex = project.nodes.firstIndex(where: { $0.id == nodeID }) else { continue }
            var values: [PortAddress: RuntimeValue] = [:]
            for entry in result.values {
                let value = entry.value.mappingMedia { url, _ in PackageLinks.resolved(url, in: folder) ?? url }
                guard let value else { continue }
                value.mediaFiles.forEach { note($0.path) }
                values[PortAddress(nodeID: nodeID, portID: entry.portID)] = value
            }
            guard !values.isEmpty else { continue }
            var snapshot = result.node.mappingPaths(resolvePath)
            snapshot.id = nodeID; snapshot.selectedTakeID = nil
            var names: [String: String] = [:]
            // Names are keyed by node id; the node has a new id now. A UUID string is 36 characters.
            for (key, value) in result.mediaNames ?? [:] where key.hasPrefix(result.nodeID.uuidString) {
                names[nodeID.uuidString + key.dropFirst(36)] = value
            }
            let artifact = ExecutionArtifact(
                id: UUID(), projectID: project.id, targetID: nodeID,
                graphSnapshot: WorkflowProject(id: project.id, name: project.name, nodes: [snapshot], edges: []),
                values: values, createdAt: result.createdAt,
                mediaProvenance: result.mediaProvenance.map { [nodeID: $0] },
                generatedNodeIDs: [nodeID],
                mediaNames: names.isEmpty ? nil : names)
            artifacts.append(artifact)
            if project.nodes[nodeIndex].supportsTakes { project.nodes[nodeIndex].selectedTakeID = artifact.id }
        }
        return OpenedPackage(sourceProjectID: sourceProjectID, project: project, artifacts: artifacts, missing: missing)
    }
}
