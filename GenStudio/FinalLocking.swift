import AppKit
import Foundation

/// How a node's lock badge reads on the canvas.
enum FinalBadgeState: Equatable {
    /// Still being worked on: it can generate, and nothing is saved yet.
    case open
    /// Final: its result is saved in the project folder and is what downstream nodes use.
    case locked
    /// Locked, but the saved file was moved or deleted outside the app.
    case missing
}

extension StudioModel {
    // MARK: - Project folder

    func home(for project: WorkflowProject?) -> ProjectHome? { project?.homeFolder.map { ProjectHome(path: $0) } }
    var currentHome: ProjectHome? { home(for: currentProject) }

    /// Points a project at a folder: creates `Links/images|video|prompts` and starts keeping its `.genstudio` file there.
    func bindProjectFolder(_ folder: URL, to projectID: UUID) throws {
        guard var project = projects.first(where: { $0.id == projectID }) else { return }
        let root = folder.standardizedFileURL
        if let other = projects.first(where: { $0.id != projectID && $0.homeFolder.map { ProjectHome(path: $0).root } == root }) {
            throw StudioError.validation("“\(root.lastPathComponent)” is already the folder of “\(other.name)”. Choose a different folder.")
        }
        if let message = ProjectMirror.conflict(for: project, in: root) { throw StudioError.validation(message) }
        try ProjectHome(root: root).prepare()
        project.homeFolder = root.path
        replace(project)
    }

    /// Asks where the project lives. Returns true once it is bound to a folder.
    @discardableResult
    func chooseProjectFolder(for projectID: UUID, message: String? = nil) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }) else { return false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = message ?? "Choose or create the project folder for “\(project.name)”. Its workflow file and a Links folder (images, video, prompts) are kept there."
        if let path = project.homeFolder { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do { try bindProjectFolder(url, to: projectID); return true }
        catch { alertMessage = error.localizedDescription; return false }
    }

    /// Starts a project inside a folder you choose, or opens the project already saved there.
    func newProjectInFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Project"
        panel.message = "Choose or create the project folder. GenStudio saves the workflow there and keeps its images, video and prompts in a Links folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted().first { $0.hasSuffix("." + ProjectPackage.fileExtension) }
        if let existing { openPackage(folder.appending(path: existing)); return }
        createProject()
        guard var project = projects.first else { return }
        project.name = uniqueProjectName(folder.lastPathComponent)
        replace(project)
        do { try bindProjectFolder(folder, to: project.id) } catch { alertMessage = error.localizedDescription }
    }

    // MARK: - Results a node can be finalized from

    /// The generation a node is currently showing: the selected take for generation nodes, the latest result for
    /// the text nodes that generate.
    func currentArtifact(for node: StudioNode, in project: WorkflowProject) -> ExecutionArtifact? {
        if node.supportsTakes {
            let history = takes(for: node, inProject: project.id)
            return history.first { $0.id == node.selectedTakeID } ?? history.last
        }
        return executionArtifacts
            .filter { ($0.projectID == project.id || $0.graphSnapshot.id == project.id) && $0.generatedNodeIDs?.contains(node.id) == true && $0.values.keys.contains { $0.nodeID == node.id } }
            .max { $0.createdAt < $1.createdAt }
    }

    private enum FinalSource {
        case media(URL, LinkKind, takeID: UUID?)
        case text(String)
    }

    private func finalSource(for node: StudioNode, in project: WorkflowProject) throws -> FinalSource {
        if node.kind == .prompt {
            let text = node.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StudioError.validation("Write the prompt in “\(node.label)” before locking it.") }
            return .text(node.prompt)
        }
        guard let port = node.outputPorts.first, let artifact = currentArtifact(for: node, in: project),
              let value = artifact.values[PortAddress(nodeID: node.id, portID: port.id)] else {
            throw StudioError.validation("Run “\(node.label)” first, then lock the result you want to keep.")
        }
        switch value {
        case .image(let url): return .media(url, .image, takeID: node.supportsTakes ? artifact.id : nil)
        case .video(let url): return .media(url, .video, takeID: node.supportsTakes ? artifact.id : nil)
        case .text(let text): return .text(text)
        default: throw StudioError.validation("“\(node.label)” has no result that can be saved as a file.")
        }
    }

    // MARK: - Locking

    /// The project with the node's current result saved into its folder and the node marked final.
    func projectByLocking(_ nodeID: UUID, in project: WorkflowProject) throws -> WorkflowProject {
        guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return project }
        let node = project.nodes[index]
        guard node.canBeFinalized else { throw StudioError.validation("“\(node.label)” cannot be locked.") }
        guard !node.isLockedFinal else { return project }
        guard let home = home(for: project) else { throw StudioError.validation("Choose a project folder before locking.") }
        let claimed = Set(project.nodes.filter { $0.id != nodeID }.compactMap { $0.finalized?.path })
        let record: FinalRecord
        var takeID: UUID?
        switch try finalSource(for: node, in: project) {
        case .media(let url, let kind, let take):
            let path = try home.writeFinal(from: url, name: node.label, kind: kind, claimed: claimed, own: node.finalized?.path)
            record = FinalRecord(path: path, kind: kind, takeID: take, lockedAt: Date())
            takeID = take
        case .text(let text):
            let path = try home.writeFinalText(text, name: node.label, claimed: claimed, own: node.finalized?.path)
            record = FinalRecord(path: path, kind: .text, takeID: nil, lockedAt: Date(), text: text)
        }
        var locked = project
        locked.nodes[index].finalized = record
        if let takeID { locked.nodes[index].selectedTakeID = takeID }
        return locked
    }

    /// Saves the node's current result to the project folder and locks it as final. Asks for a folder first if
    /// the project does not have one yet.
    @discardableResult
    func lockFinal(_ nodeID: UUID) -> Bool {
        guard let project = currentProject, let node = project.nodes.first(where: { $0.id == nodeID }) else { return false }
        guard !isRunning(nodeID), !isQueued(nodeID) else { alertMessage = "“\(node.label)” is generating. Lock it when the run finishes."; return false }
        if project.homeFolder == nil {
            guard chooseProjectFolder(for: project.id, message: "Locking saves “\(node.label)” as a file. Choose or create the project folder for “\(project.name)”.") else { return false }
        }
        guard let bound = currentProject else { return false }
        do {
            let locked = try projectByLocking(nodeID, in: bound)
            editGraph { $0 = locked }
            return true
        } catch { alertMessage = error.localizedDescription; return false }
    }

    func unlockFinal(_ nodeID: UUID) {
        updateNode(nodeID) { $0.finalized?.isLocked = false }
    }

    func toggleFinal(_ nodeID: UUID) {
        guard let node = currentProject?.nodes.first(where: { $0.id == nodeID }) else { return }
        if node.isLockedFinal { unlockFinal(nodeID) } else { lockFinal(nodeID) }
    }

    /// Refuses a run whose locked upstream node has lost its saved file, instead of quietly drawing a new one.
    func lockedFinalIssue(in project: WorkflowProject, target: UUID) throws {
        let byID = Dictionary(uniqueKeysWithValues: project.nodes.map { ($0.id, $0) })
        let home = home(for: project)
        var seen: Set<UUID> = [target], pending = [target]
        while let id = pending.popLast() {
            for edge in project.edges where edge.targetID == id {
                guard let source = byID[edge.sourceID] else { continue }
                if source.isLockedFinal {
                    if let record = source.finalized, home == nil || home?.isMissing(record) == true {
                        throw StudioError.validation("“\(source.label)” is locked as final, but its saved file (\(record.path)) is missing. Put the file back, or unlock the node to generate it again.")
                    }
                    continue
                }
                if seen.insert(source.id).inserted { pending.append(source.id) }
            }
        }
    }

    func finalBadgeState(for node: StudioNode) -> FinalBadgeState? {
        guard node.canBeFinalized else { return nil }
        guard node.isLockedFinal, let record = node.finalized else { return .open }
        if let home = currentHome, home.isMissing(record) { return .missing }
        return .locked
    }

    /// The saved result of a locked node, which stands in for the node everywhere downstream.
    func finalValue(for node: StudioNode) -> RuntimeValue? {
        guard node.isLockedFinal, let record = node.finalized, let home = currentHome else { return nil }
        return home.value(of: record)
    }

    /// Generating nodes that have a result but are not locked yet, in projects that have a folder to save into.
    func unlockedGenerations(in project: WorkflowProject) -> [StudioNode] {
        guard project.homeFolder != nil else { return [] }
        return project.nodes.filter { node in
            node.canBeFinalized && node.kind != .prompt && !node.isLockedFinal && currentArtifact(for: node, in: project) != nil
        }
    }

    var unlockedGenerationCount: Int { projects.reduce(0) { $0 + unlockedGenerations(in: $1).count } }

    /// Locks every unlocked generation in every folder-bound project. Returns what could not be saved.
    @discardableResult
    func lockAllGenerations() -> [String] {
        var problems: [String] = []
        for project in projects {
            var updated = project
            for node in unlockedGenerations(in: project) {
                do { updated = try projectByLocking(node.id, in: updated) }
                catch { problems.append("\(project.name) › \(node.label): \(error.localizedDescription)") }
            }
            if updated != project { replace(updated) }
        }
        return problems
    }

    func revealFinal(_ nodeID: UUID) {
        guard let node = currentProject?.nodes.first(where: { $0.id == nodeID }), let record = node.finalized, let home = currentHome else { return }
        revealInFinder(home.url(for: record.path))
    }

    // MARK: - Heading is the file name

    /// Renames the files of finalized nodes whose headings changed, so the name on disk always matches the heading.
    /// Also catches undo and redo, which put an older heading and file path back.
    func reconcileFinalFiles(from old: WorkflowProject, to new: WorkflowProject) -> WorkflowProject {
        guard let home = home(for: new) else { return new }
        var result = new
        for index in new.nodes.indices {
            let node = new.nodes[index]
            guard let record = node.finalized, let oldNode = old.nodes.first(where: { $0.id == node.id }),
                  oldNode.label != node.label || oldNode.finalized?.path != record.path else { continue }
            let claimed = Set(new.nodes.filter { $0.id != node.id }.compactMap { $0.finalized?.path })
            let present = [oldNode.finalized?.path, record.path].compactMap { $0 }.first { FileManager.default.fileExists(atPath: home.url(for: $0).path) } ?? record.path
            do {
                let renamed = try home.renameFinal(at: present, to: node.label, kind: record.kind, claimed: claimed)
                if renamed != record.path { result.nodes[index].finalized?.path = renamed }
            } catch { alertMessage = error.localizedDescription }
        }
        return result
    }

    /// Renames a node from anywhere, including a project that is not the one on screen (the Images sidebar spans all).
    func renameNode(_ nodeID: UUID, to name: String, inProject projectID: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if projectID == currentProjectID { renameNode(nodeID, to: trimmed); return }
        guard var project = projects.first(where: { $0.id == projectID }),
              let index = project.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        project.nodes[index].label = trimmed
        replace(project)
    }
}
