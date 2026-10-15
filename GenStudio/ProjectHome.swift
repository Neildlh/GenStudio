import Foundation
import UniformTypeIdentifiers

/// What kind of file a link is, which decides its folder inside `Links`.
enum LinkKind: String, Codable, Sendable, CaseIterable {
    case image, video, text

    var folderName: String {
        switch self { case .image: "images"; case .video: "video"; case .text: "prompts" }
    }

    /// Where a file of this extension belongs; nil for types the project folder does not organise.
    static func kind(forExtension ext: String) -> LinkKind? {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .text) { return .text }
        return nil
    }
}

/// The saved file behind a node the author has finalized. It stays on the node after unlocking so that
/// locking again replaces the same file instead of creating a second one beside it.
struct FinalRecord: Codable, Hashable, Sendable {
    /// Relative to the project folder, e.g. `Links/images/Hero.png`.
    var path: String
    var kind: LinkKind
    /// The take that was saved. Nil for text nodes, which have no takes.
    var takeID: UUID?
    var lockedAt: Date
    /// True while the node stands as final: it cannot generate, and this file is what flows downstream.
    var isLocked: Bool = true
    /// The saved text for text nodes, so showing the node never has to read the disk.
    var text: String?
}

extension StudioNode {
    /// The node is final and its saved result is what the rest of the workflow uses.
    var isLockedFinal: Bool { finalized?.isLocked == true }

    /// Nodes that can be locked: anything that produces takes, plus the nodes that produce text.
    var canBeFinalized: Bool {
        supportsTakes || [.prompt, .promptEnhancer, .textModel, .imageDescriber, .characterSheet].contains(kind)
    }
}

/// A project's folder: the `.genstudio` file, and `Links/` with `images`, `video` and `prompts` inside it.
/// Finals are written here under the node's heading, so the name in the sidebar is the name on disk.
struct ProjectHome: Sendable {
    static let linksFolder = "Links"

    let root: URL

    init(path: String) { root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
    init(root: URL) { self.root = root.standardizedFileURL }

    var links: URL { root.appending(path: Self.linksFolder, directoryHint: .isDirectory) }

    func folder(for kind: LinkKind) -> URL { links.appending(path: kind.folderName, directoryHint: .isDirectory) }

    func url(for relativePath: String) -> URL { root.appending(path: relativePath) }

    /// Creates `Links/images`, `Links/video` and `Links/prompts`.
    func prepare() throws {
        do { for kind in LinkKind.allCases { try FileManager.default.createDirectory(at: folder(for: kind), withIntermediateDirectories: true) } }
        catch { throw StudioError.persistence("Could not create the project folders in \(root.lastPathComponent): \(error.localizedDescription)") }
    }

    /// The `Links/...` path of a file inside this project's `Links` folder, or nil for a file elsewhere.
    func relativePath(of url: URL) -> String? {
        let base = links.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return nil }
        return Self.linksFolder + "/" + path.dropFirst(base.count)
    }

    /// The relative path a final named `name` should have: the node's heading, with `_2`, `_3`… added when another
    /// final or a file you put there already has that name. `own` is the node's current file, which it may reuse.
    func destination(name: String, kind: LinkKind, fileExtension: String, claimed: Set<String>, own: String?) -> String {
        let (stem, ext) = ProjectPackager.split(name, fallbackExtension: fileExtension)
        var ordinal = 1
        while true {
            let file = ordinal == 1 ? "\(stem)\(ext)" : "\(stem)_\(ordinal)\(ext)"
            let relative = "\(Self.linksFolder)/\(kind.folderName)/\(file)"
            if let own, own.caseInsensitiveCompare(relative) == .orderedSame { return relative }
            let taken = claimed.contains { $0.caseInsensitiveCompare(relative) == .orderedSame }
            if !taken, !FileManager.default.fileExists(atPath: url(for: relative).path) { return relative }
            ordinal += 1
        }
    }

    /// Saves a generated image or video as the node's final. Returns the relative path.
    func writeFinal(from source: URL, name: String, kind: LinkKind, claimed: Set<String>, own: String?) throws -> String {
        try prepare()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw StudioError.validation("The generated file is no longer on disk, so it cannot be saved. Generate it again.")
        }
        let relative = destination(name: name, kind: kind, fileExtension: source.pathExtension, claimed: claimed, own: own)
        try ProjectPackager.copy(source.standardizedFileURL.resolvingSymlinksInPath(), to: url(for: relative))
        return relative
    }

    /// Saves a prompt or other text result as a `.txt` file. Returns the relative path.
    func writeFinalText(_ text: String, name: String, claimed: Set<String>, own: String?) throws -> String {
        try prepare()
        let relative = destination(name: name, kind: .text, fileExtension: "txt", claimed: claimed, own: own)
        do { try Data(text.utf8).write(to: url(for: relative), options: .atomic) }
        catch { throw StudioError.persistence("Could not save \(relative): \(error.localizedDescription)") }
        return relative
    }

    /// Renames a saved final to match its node's new heading. Returns the new relative path, which is the same
    /// path when nothing needs to change or the file is not there to rename.
    func renameFinal(at relative: String, to name: String, kind: LinkKind, claimed: Set<String>) throws -> String {
        let source = url(for: relative)
        guard FileManager.default.fileExists(atPath: source.path) else { return relative }
        let target = destination(name: name, kind: kind, fileExtension: source.pathExtension, claimed: claimed, own: relative)
        guard target != relative else { return relative }
        let destination = url(for: target)
        do {
            // A change of letter case alone names the same file on a case-insensitive volume, so go via a temporary name.
            if target.caseInsensitiveCompare(relative) == .orderedSame {
                let temporary = source.deletingLastPathComponent().appending(path: ".rename-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: source, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        } catch { throw StudioError.persistence("Could not rename \(source.lastPathComponent) to \(destination.lastPathComponent): \(error.localizedDescription)") }
        return target
    }

    /// The value a locked node stands for downstream.
    func value(of record: FinalRecord) -> RuntimeValue {
        switch record.kind {
        case .image: .image(url(for: record.path))
        case .video: .video(url(for: record.path))
        case .text: .text(record.text ?? "")
        }
    }

    /// True when a media final's file has gone missing (moved or deleted outside the app).
    func isMissing(_ record: FinalRecord) -> Bool {
        record.kind != .text && !FileManager.default.fileExists(atPath: url(for: record.path).path)
    }
}
