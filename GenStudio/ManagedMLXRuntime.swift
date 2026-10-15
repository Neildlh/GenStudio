import Foundation

/// App-owned MLX runtime locations.  GenStudio never falls through to a
/// Homebrew, system, or user virtual environment: a model may only be offered
/// when its exact, version-pinned runtime is installed by the application.
///
/// Runtime payloads are intentionally distinct from model weights. Packaging
/// Release packaging may add the audited ARM64 environment beneath
/// `LocalRuntimes`; development builds install it once in Application Support.
/// Users keep models separately and can remove them independently.
enum ManagedMLXRuntime {
    /// Release contract for the shared Python environment. Import success by
    /// itself is insufficient: a user-modified or partially upgraded runtime
    /// must not be treated as the engine build GenStudio tested.
    static let expectedPackageVersions: [String: String] = [
        "diffusers": "0.40.0",
        "mlx": "0.32.2",
        "mlx-vlm": "0.7.1",
        "torch": "2.12.0",
        "transformers": "5.15.1"
    ]
    static let expectedLTXPackageVersions: [String: String] = [
        "ltx-core-mlx": "0.16.3",
        "ltx-pipelines-mlx": "0.16.3",
        "mlx-arsenal": "0.2.4",
        "mlx-lm": "0.31.1",
        "protobuf": "7.36.1"
    ]
    static let expectedSpeechPackageVersions: [String: String] = ["mlx-audio": "0.5.4"]

    private actor HealthCache {
        private var healthyExecutables: Set<String> = []
        func contains(_ path: String) -> Bool { healthyExecutables.contains(path) }
        func insert(_ path: String) { healthyExecutables.insert(path) }
    }
    private static let healthCache = HealthCache()

    enum Family: String, Codable, Sendable, CaseIterable {
        case vlm = "mlx-vlm"
        case ltx = "mlx-ltx"
        case fastVideo = "mlx-fastvideo"
        case speech = "mlx-audio"

        var displayName: String {
            switch self {
            case .vlm: "MLX vision and text"
            case .ltx: "LTX MLX video"
            case .fastVideo: "FastVideo MLX"
            case .speech: "MLX speech"
            }
        }

        /// Text/vision, FastVideo and LTX deliberately share one pinned Python/MLX
        /// environment. This avoids shipping two copies of MLX, Torch, and
        /// Transformers while keeping model packages and typed launchers
        /// separate. LTX has an additional family-specific package check and
        /// launcher, while reusing the exact same MLX build.
        var runtimeDirectoryName: String {
            switch self {
            case .vlm, .fastVideo, .ltx, .speech: "mlx-fastvideo"
            }
        }
    }

    static func pythonExecutable(for family: Family, resourceRoot: URL? = Bundle.main.resourceURL) throws -> URL {
        guard let runtimeRoot = LocalRuntimeLibrary.engineRoot(family.runtimeDirectoryName, resourceRoot: resourceRoot) else {
            throw StudioError.validation("The GenStudio MLX runtime is not installed. Open Models → Start Here and install the local runtime package.")
        }
        let executable = runtimeRoot.appending(path: "bin/python")
        let resolvedRoot = runtimeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedExecutable = executable.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              resolvedExecutable.path.hasPrefix(resolvedRoot.path + "/") else {
            throw StudioError.validation("\(family.displayName) is missing or outside GenStudio's app-owned runtime library. Reinstall it from Models → Start Here; do not install Python packages manually.")
        }
        return executable
    }

    /// Runtime families expose narrowly-scoped launchers rather than allowing
    /// the Swift app to execute arbitrary bundled Python source. Each launcher
    /// owns its module path and its private caches under GenStudio support.
    static func launcher(named name: String, family: Family, resourceRoot: URL? = Bundle.main.resourceURL) throws -> URL {
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw StudioError.validation("Invalid managed runtime launcher name.")
        }
        _ = try pythonExecutable(for: family, resourceRoot: resourceRoot)
        guard let runtimeRoot = LocalRuntimeLibrary.engineRoot(family.runtimeDirectoryName, resourceRoot: resourceRoot) else {
            throw StudioError.validation("The GenStudio managed MLX runtime is unavailable. Install it from Models → Start Here.")
        }
        let executable = runtimeRoot.appending(path: "bin/\(name)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw StudioError.validation("The app-managed \(family.displayName) launcher is missing or damaged. Reinstall the local runtime package from Models → Start Here.")
        }
        return executable
    }

    static func checkEnvironment(family: Family, resourceRoot: URL? = Bundle.main.resourceURL, timeout: Duration = .seconds(20)) async throws {
        let python = try pythonExecutable(for: family, resourceRoot: resourceRoot)
        let cacheKey = python.standardizedFileURL.resolvingSymlinksInPath().path + "#" + family.rawValue
        if await healthCache.contains(cacheKey) { return }
        let marker = "genstudio-mlx-runtime-ready"
        let packages = family == .ltx ? expectedPackageVersions.merging(expectedLTXPackageVersions) { _, ltx in ltx }
            : family == .speech ? expectedPackageVersions.merging(expectedSpeechPackageVersions) { _, speech in speech } : expectedPackageVersions
        let expected = packages.keys.sorted().map { "'\($0)': '\(packages[$0]!)'" }.joined(separator: ", ")
        let program = """
        import importlib.metadata as m
        expected = {\(expected)}
        actual = {name: m.version(name) for name in expected}
        assert actual == expected, f"version mismatch: {actual}"
        import diffusers, mlx, mlx_vlm, torch, transformers
        \(family == .ltx ? "import ltx_core_mlx, ltx_pipelines_mlx, mlx_arsenal, mlx_lm" : family == .speech ? "import mlx_audio.tts.generate" : "")
        print('\(marker)')
        """
        let result = try await NativeProcessRunner().run(
            executable: python,
            arguments: ["-c", program],
            timeout: timeout
        )
        guard result.status == 0, result.stdout.contains(marker) else {
            throw StudioError.validation("The app-managed \(family.displayName) runtime failed its pinned-version health check. Reinstall the local runtime package from Models → Start Here; its model packages cannot run until this is fixed. \(result.stderr.suffix(500))")
        }
        await healthCache.insert(cacheKey)
    }
}
