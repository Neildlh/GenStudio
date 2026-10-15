import Foundation

/// Keeps a folder-bound project's `.genstudio` file current, so the project folder is a working file that
/// can be opened, moved or handed over at any moment. The app library still holds the project's drafts;
/// the folder holds the workflow and everything locked as final.
enum ProjectMirror {
    static func fileName(for project: WorkflowProject) -> String {
        let (stem, ext) = ProjectPackager.split(project.name, fallbackExtension: ProjectPackage.fileExtension)
        return stem + ext
    }

    private struct Header: Decodable {
        struct Project: Decodable { var id: UUID }
        var project: Project
    }

    /// The id of the project a `.genstudio` file holds, or nil if it is not one.
    static func projectID(inFile url: URL) -> UUID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Header.self, from: data))?.project.id
    }

    /// A message when binding `project` to `folder` would overwrite a different project's file.
    static func conflict(for project: WorkflowProject, in folder: URL) -> String? {
        let file = folder.appending(path: fileName(for: project))
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let id = projectID(inFile: file), id != project.id else { return nil }
        return "“\(folder.lastPathComponent)” already holds a different project, \(file.lastPathComponent). Open that file instead, or choose another folder."
    }

    /// Writes the project file into its folder. Nothing is copied; files in `Links` are recorded by relative path.
    /// - Parameter cleanStale: also remove this project's file under an older name, after a rename.
    @discardableResult
    static func write(_ project: WorkflowProject, models: [ModelUsage], cleanStale: Bool, appVersion: String = ProjectPackager().appVersion) throws -> URL {
        guard let path = project.homeFolder else { throw StudioError.validation("This project has no folder yet.") }
        let home = ProjectHome(path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StudioError.persistence("The project folder “\(home.root.lastPathComponent)” cannot be found. Reconnect the drive or choose the folder again; the project stays safe in GenStudio meanwhile.")
        }
        let file = home.root.appending(path: fileName(for: project))
        if let existing = projectID(inFile: file), existing != project.id {
            throw StudioError.persistence("\(file.lastPathComponent) in “\(home.root.lastPathComponent)” belongs to a different project, so it was not overwritten.")
        }
        var portable = project
        portable.homeFolder = nil
        portable.nodes = project.nodes.map { node in
            var mapped = node.mappingPaths { home.relativePath(of: URL(fileURLWithPath: $0)) }
            mapped.selectedTakeID = nil
            return mapped
        }
        let package = ProjectPackage(appVersion: appVersion, packagedAt: Date(), project: portable, results: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(package).write(to: file, options: .atomic) }
        catch { throw StudioError.persistence("Could not save \(file.lastPathComponent): \(error.localizedDescription)") }
        if !models.isEmpty {
            let list = ModelsUsedFile.text(projectName: project.name, models: models, packagedAt: package.packagedAt, appVersion: appVersion)
            try? Data(list.utf8).write(to: home.root.appending(path: ModelsUsedFile.fileName), options: .atomic)
        }
        if cleanStale {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: home.root.path)) ?? []
            for name in names where name.hasSuffix("." + ProjectPackage.fileExtension) && name != file.lastPathComponent {
                let other = home.root.appending(path: name)
                if projectID(inFile: other) == project.id { try? FileManager.default.removeItem(at: other) }
            }
        }
        return file
    }
}
