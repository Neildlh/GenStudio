import Foundation

/// Low-priority housekeeping run once per launch, off the main actor. Every rule is narrow: it touches
/// only app-owned locations and only content that can no longer be in use.
enum StartupMaintenance {
    /// Leftovers older than this cannot belong to a run in progress (engine timeouts are at most two hours),
    /// even in a second GenStudio window or build that shares the same support folder.
    static let scratchRetention: TimeInterval = 86_400

    static func run(supportRoot: URL) {
        removeLegacyRuntime(supportRoot: supportRoot)
        sweepScratch(supportRoot: supportRoot)
    }

    /// Before the versioned RuntimeLibrary, the MLX vision runtime was a Homebrew-based virtual environment at
    /// `Runtime/mlx-vlm` (~730 MB). Nothing uses it any more. Only that exact folder, and only when it is a
    /// Python virtual environment (has `pyvenv.cfg`), is removed.
    static func removeLegacyRuntime(supportRoot: URL) {
        let legacy = supportRoot.appending(path: "Runtime/mlx-vlm", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: legacy.appending(path: "pyvenv.cfg").path) else { return }
        try? FileManager.default.removeItem(at: legacy)
        let parent = legacy.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Engines stage outputs in `GenerationScratch` and move them into retained storage on success; a crash
    /// or forced quit can leave them behind.
    static func sweepScratch(supportRoot: URL, now: Date = Date()) {
        let scratch = supportRoot.appending(path: "GenerationScratch", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > scratchRetention else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
