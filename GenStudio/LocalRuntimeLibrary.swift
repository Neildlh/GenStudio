import Foundation

struct LocalRuntimeInstallationStatus: Sendable, Equatable {
    let ready: Bool
    let canInstall: Bool
    let location: URL?
    let message: String
}

/// Owns the heavyweight local inference runtime independently of the app
/// bundle. Development builds install it once into Application Support, so a
/// clean Swift build never needs to copy and re-sign the Python/MLX tree.
actor LocalRuntimeLibrary {
    /// Bumped whenever the runtime's contents change, so a Debug build reports "setup needed" instead
    /// of running against the previous installation. 2026-10-12: ltx-2-mlx 0.16.3 (float16 DiT,
    /// tiled decode) and FastMetal's bundled TAEHV/RIFE weights.
    static let packageID = "native-2026-10-12"

    let root: URL
    private let developmentSource: URL?

    init(
        root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GenStudio/RuntimeLibrary", directoryHint: .isDirectory),
        developmentSource: URL? = LocalRuntimeLibrary.configuredDevelopmentSource()
    ) {
        self.root = root
        self.developmentSource = developmentSource
    }

    var installedRoot: URL {
        root.appending(path: "Installed/\(Self.packageID)", directoryHint: .isDirectory)
    }

    func status() -> LocalRuntimeInstallationStatus {
        if Self.isCompleteRuntime(at: installedRoot) {
            return .init(ready: true, canInstall: false, location: installedRoot,
                         message: "Ready · app-owned Metal and MLX runtime installed once outside the app bundle")
        }
        if let developmentSource, Self.isCompleteRuntime(at: developmentSource) {
            return .init(ready: false, canInstall: true, location: nil,
                         message: "Setup needed · install the pinned local runtime once, then download models below")
        }
        if Self.isCompleteRuntime(at: Self.bundledRuntimeRoot()) {
            return .init(ready: true, canInstall: false, location: Self.bundledRuntimeRoot(),
                         message: "Ready · signed runtime included with this release build")
        }
        return .init(ready: false, canInstall: false, location: nil,
                     message: "Runtime package unavailable · reinstall this build or provide the pinned development runtime")
    }

    func installDevelopmentRuntime() async throws {
        guard let developmentSource, Self.isCompleteRuntime(at: developmentSource) else {
            throw StudioError.validation("The pinned development runtime is unavailable. Rebuild the local runtime package before installing models.")
        }
        if Self.isCompleteRuntime(at: installedRoot) { return }

        let root = self.root
        let final = installedRoot
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let stagingParent = root.appending(path: ".staging", directoryHint: .isDirectory)
            let staging = stagingParent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try manager.createDirectory(at: stagingParent, withIntermediateDirectories: true)
            do {
                for engine in ["llama", "sd"] {
                    let source = developmentSource.appending(path: engine, directoryHint: .isDirectory)
                    let destination = staging.appending(path: engine, directoryHint: .isDirectory)
                    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                    for part in ["bin", "lib", "licenses"] {
                        try manager.copyItem(at: source.appending(path: part, directoryHint: .isDirectory),
                                             to: destination.appending(path: part, directoryHint: .isDirectory))
                    }
                }
                try manager.copyItem(at: developmentSource.appending(path: "mlx-fastvideo", directoryHint: .isDirectory),
                                     to: staging.appending(path: "mlx-fastvideo", directoryHint: .isDirectory))
                guard Self.isCompleteRuntime(at: staging) else {
                    throw StudioError.validation("The copied runtime failed its structure check; the previous installation was preserved.")
                }
                try Task.checkCancellation()
                try manager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: final.path) {
                    let backup = final.deletingLastPathComponent().appending(path: ".previous-\(UUID().uuidString)")
                    try manager.moveItem(at: final, to: backup)
                    do {
                        try manager.moveItem(at: staging, to: final)
                        try? manager.removeItem(at: backup)
                    } catch {
                        try? manager.moveItem(at: backup, to: final)
                        throw error
                    }
                } else {
                    try manager.moveItem(at: staging, to: final)
                }
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
            Self.removeSupersededRuntimes(besides: final)
        }.value
    }

    /// Earlier app-owned runtimes (`native-*` siblings) are about 1.7 GB each and are never used once a
    /// newer package is installed. Only that naming pattern is touched; anything else is left alone.
    private nonisolated static func removeSupersededRuntimes(besides current: URL) {
        let manager = FileManager.default
        let parent = current.deletingLastPathComponent()
        guard let entries = try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("native-") && entry.lastPathComponent != current.lastPathComponent {
            try? manager.removeItem(at: entry)
        }
    }

    nonisolated static func installedRuntimeRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "GenStudio/RuntimeLibrary/Installed/\(packageID)", directoryHint: .isDirectory)
    }

    nonisolated static func bundledRuntimeRoot(resourceRoot: URL? = Bundle.main.resourceURL) -> URL? {
        resourceRoot?.appending(path: "LocalRuntimes", directoryHint: .isDirectory)
    }

    nonisolated static func engineRoot(_ engine: String, resourceRoot: URL? = Bundle.main.resourceURL) -> URL? {
        if let bundled = bundledRuntimeRoot(resourceRoot: resourceRoot)?.appending(path: engine, directoryHint: .isDirectory),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let installed = installedRuntimeRoot().appending(path: engine, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    nonisolated static func isCompleteRuntime(at root: URL?) -> Bool {
        guard let root else { return false }
        let manager = FileManager.default
        let executables = [
            "llama/bin/llama-cli", "llama/bin/llama-mtmd-cli", "sd/bin/sd-cli",
            "mlx-fastvideo/bin/python", "mlx-fastvideo/bin/genstudio-mlx-vlm",
            "mlx-fastvideo/bin/genstudio-fastmetal-5b", "mlx-fastvideo/bin/genstudio-ltx-23", "mlx-fastvideo/bin/genstudio-mlx-tts"
        ]
        return executables.allSatisfy { manager.isExecutableFile(atPath: root.appending(path: $0).path) }
            && manager.fileExists(atPath: root.appending(path: "mlx-fastvideo/RUNTIME.lock").path)
    }

    private nonisolated static func configuredDevelopmentSource(bundle: Bundle = .main) -> URL? {
        if let path = bundle.object(forInfoDictionaryKey: "GenStudioDevelopmentRuntimeSource") as? String,
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
#if DEBUG
        return URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: ".vendor", directoryHint: .isDirectory)
#else
        return nil
#endif
    }
}
