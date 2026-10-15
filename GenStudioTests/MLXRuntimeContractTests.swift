import CryptoKit
import XCTest
@testable import GenStudio

final class MLXRuntimeContractTests: XCTestCase {
    func testDevelopmentRuntimeInstallsAtomicallyOutsideTheAppBundle() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "runtime-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appending(path: "source")
        let libraryRoot = scratch.appending(path: "library")
        let executables = [
            "llama/bin/llama-cli", "llama/bin/llama-mtmd-cli", "sd/bin/sd-cli",
            "mlx-fastvideo/bin/python", "mlx-fastvideo/bin/genstudio-mlx-vlm",
            "mlx-fastvideo/bin/genstudio-fastmetal-5b", "mlx-fastvideo/bin/genstudio-ltx-23", "mlx-fastvideo/bin/genstudio-mlx-tts"
        ]
        for path in executables {
            let file = source.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for path in ["llama/lib", "llama/licenses", "sd/lib", "sd/licenses", "mlx-fastvideo/licenses"] {
            let directory = source.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: directory.appending(path: "fixture"))
        }
        try Data("fixture=1\n".utf8).write(to: source.appending(path: "mlx-fastvideo/RUNTIME.lock"))

        let library = LocalRuntimeLibrary(root: libraryRoot, developmentSource: source)
        let before = await library.status()
        XCTAssertFalse(before.ready)
        XCTAssertTrue(before.canInstall)

        try await library.installDevelopmentRuntime()
        let after = await library.status()
        XCTAssertTrue(after.ready)
        XCTAssertFalse(after.canInstall)
        XCTAssertTrue(LocalRuntimeLibrary.isCompleteRuntime(at: after.location))
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRoot.appending(path: ".staging").appending(path: "unfinished").path))
    }

    func testInstallingANewRuntimeRemovesOnlySupersededRuntimes() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "runtime-supersede-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appending(path: "source")
        for path in ["llama/bin/llama-cli", "llama/bin/llama-mtmd-cli", "sd/bin/sd-cli", "mlx-fastvideo/bin/python",
                     "mlx-fastvideo/bin/genstudio-mlx-vlm", "mlx-fastvideo/bin/genstudio-fastmetal-5b", "mlx-fastvideo/bin/genstudio-ltx-23", "mlx-fastvideo/bin/genstudio-mlx-tts"] {
            let file = source.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for path in ["llama/lib", "llama/licenses", "sd/lib", "sd/licenses", "mlx-fastvideo/licenses"] {
            let directory = source.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: directory.appending(path: "fixture"))
        }
        try Data("fixture=1\n".utf8).write(to: source.appending(path: "mlx-fastvideo/RUNTIME.lock"))
        let installed = scratch.appending(path: "library/Installed", directoryHint: .isDirectory)
        let superseded = installed.appending(path: "native-2026-09-17", directoryHint: .isDirectory)
        let unrelated = installed.appending(path: "user-notes", directoryHint: .isDirectory)
        for directory in [superseded, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("keep?".utf8).write(to: directory.appending(path: "file"))
        }

        let library = LocalRuntimeLibrary(root: scratch.appending(path: "library"), developmentSource: source)
        try await library.installDevelopmentRuntime()

        XCTAssertNotEqual(LocalRuntimeLibrary.packageID, "native-2026-09-17", "The LTX 0.16.3 runtime ships under a new package ID")
        let installedRoot = await library.installedRoot
        XCTAssertTrue(LocalRuntimeLibrary.isCompleteRuntime(at: installedRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: superseded.path), "A superseded app-owned runtime is removed after the new one is in place")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appending(path: "file").path), "Only native-* runtimes are ever removed")
    }

    func testManagedRuntimeContractPinsLTXAndSharesTheAppOwnedMLXBuild() {
        XCTAssertEqual(ManagedMLXRuntime.expectedPackageVersions, [
            "diffusers": "0.40.0",
            "mlx": "0.32.2",
            "mlx-vlm": "0.7.1",
            "torch": "2.12.0",
            "transformers": "5.15.1"
        ])
        XCTAssertEqual(ManagedMLXRuntime.Family.vlm.runtimeDirectoryName, ManagedMLXRuntime.Family.fastVideo.runtimeDirectoryName)
        XCTAssertEqual(ManagedMLXRuntime.expectedLTXPackageVersions, [
            "ltx-core-mlx": "0.16.3", "ltx-pipelines-mlx": "0.16.3",
            "mlx-arsenal": "0.2.4", "mlx-lm": "0.31.1", "protobuf": "7.36.1"
        ])
        XCTAssertEqual(ManagedMLXRuntime.Family.ltx.runtimeDirectoryName, ManagedMLXRuntime.Family.fastVideo.runtimeDirectoryName)
        XCTAssertTrue(VideoCapabilityRegistry.hasUsableAdapter(MLXVideoModelCatalog.ltx23Q4RecipeID))
        XCTAssertFalse(VideoCapabilityRegistry.hasUsableAdapter(MediaModelCatalog.ltx25RecipeID))
        XCTAssertFalse(VideoCapabilityRegistry.selectableCapabilities(for: .textToVideo).contains { $0.recipeID == MediaModelCatalog.ltx25RecipeID })
        XCTAssertFalse(VideoCapabilityRegistry.selectableCapabilities(for: .imageToVideo).contains { $0.recipeID == MediaModelCatalog.ltx25RecipeID })
    }

    func testQwenModelBackendAndNodeCapabilitiesRemainSeparate() {
        let recipe = MLXVLMModelCatalog.qwen38
        XCTAssertEqual(recipe.kind, .vision, "Model storage has one primary kind")
        XCTAssertEqual(recipe.engineID, "mlx-vlm", "Backend identity is not inferred from the model name")
        XCTAssertEqual(recipe.runtimeProfile, "mlx-vlm")
        XCTAssertEqual(recipe.workflowCapabilities, [.textGeneration, .imageUnderstanding], "Node uses are explicit capabilities")
        XCTAssertEqual(recipe.components.count, 11)
        XCTAssertEqual(recipe.components.filter { $0.role == "weights" }.count, 3)
        XCTAssertEqual(Set(recipe.components.map(\.repository)), [MLXVLMModelCatalog.repository])
        XCTAssertEqual(Set(recipe.components.map(\.revision)), [MLXVLMModelCatalog.revision])
        XCTAssertEqual(Set(recipe.components.map(\.filename)).count, recipe.components.count)
        XCTAssertTrue(recipe.components.allSatisfy { !$0.filename.hasPrefix("/") && !$0.filename.split(separator: "/").contains("..") })
    }

    func testRouterDispatchesFastMetalLTXAndStableDiffusionByCapabilityEngine() async throws {
        let router = LocalVideoEngineRouter(
            stableDiffusion: RoutingProbeEngine(marker: "stable-diffusion.cpp"),
            fastVideo: RoutingProbeEngine(marker: "mlx-fastvideo"),
            ltx: RoutingProbeEngine(marker: "mlx-ltx")
        )
        await XCTAssertThrowsErrorAsync(try await router.generate(request(VideoCapabilityRegistry.fastMetal5TextToVideo))) { error in
            XCTAssertEqual((error as? RoutingProbeError)?.marker, "mlx-fastvideo")
        }
        await XCTAssertThrowsErrorAsync(try await router.generate(request(VideoCapabilityRegistry.wanTextToVideo))) { error in
            XCTAssertEqual((error as? RoutingProbeError)?.marker, "stable-diffusion.cpp")
        }
        await XCTAssertThrowsErrorAsync(try await router.generate(request(VideoCapabilityRegistry.ltx23TextToVideo))) { error in
            XCTAssertEqual((error as? RoutingProbeError)?.marker, "mlx-ltx")
        }
    }

    func testNestedMLXPackageSurvivesLibraryRestartAndKeepsItsRoute() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mlx-restart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configData = Data(#"{"model_type":"fixture"}"#.utf8)
        var tensorData = Data([16, 0, 0, 0, 0, 0, 0, 0])
        tensorData.append(Data(#"{"x":{"dtype":"F32"}}"#.utf8))
        tensorData.append(Data(repeating: 0, count: 8))
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let revision = String(repeating: "a", count: 40)
        let recipe = ModelRecipe(
            id: "mlx-vlm-restart-fixture", name: "Restart fixture", kind: .vision, engineID: "mlx-vlm",
            components: [
                .init(id: "config", role: "config", repository: "test/mlx-fixture", revision: revision, filename: "config.json", byteSize: Int64(configData.count), sha256: digest(configData), license: "test"),
                .init(id: "weights", role: "weights", repository: "test/mlx-fixture", revision: revision, filename: "weights/model.safetensors", byteSize: Int64(tensorData.count), sha256: digest(tensorData), license: "test")
            ], runtimeReady: false, minimumMemoryBytes: 1, runtimeProfile: "mlx-vlm",
            workflowCapabilities: [.textGeneration, .imageUnderstanding]
        )
        let configURL = root.appending(path: "source-config.json")
        let tensorURL = root.appending(path: "source-model.safetensors")
        try configData.write(to: configURL); try tensorData.write(to: tensorURL)
        let libraryRoot = root.appending(path: "library")
        let library = ModelLibrary(root: libraryRoot, catalog: [recipe], diskAvailable: { _ in Int64.max })
        let installed = try await library.importFiles(recipe: recipe, filesByComponentID: ["config": configURL, "weights": tensorURL])
        XCTAssertTrue(installed.components.contains { $0.fileURL.path.hasSuffix("weights/model.safetensors") })

        let restarted = ModelLibrary(root: libraryRoot, catalog: [recipe], diskAvailable: { _ in Int64.max })
        let resolved = try await restarted.resolveInstalledModel(id: recipe.id)
        XCTAssertEqual(resolved.recipeSnapshot, recipe)
        XCTAssertEqual(resolved.engineID, "mlx-vlm")
        XCTAssertTrue(resolved.canAttemptGeneration)
        XCTAssertEqual(resolved.recipeSnapshot?.workflowCapabilities, [.textGeneration, .imageUnderstanding])
    }

    private func request(_ capability: VideoCapability) -> VideoGenerationRequest {
        let settings = capability.recommended
        return .init(task: capability.task, recipeID: capability.recipeID, engineBuild: capability.engineBuild,
                     prompt: "routing probe", negativePrompt: "", width: settings.width, height: settings.height,
                     frameCount: settings.frameCount, fps: settings.fps, steps: settings.steps, cfgScale: settings.cfgScale,
                     flowShift: settings.flowShift, sampler: capability.sampler ?? "default", seed: 1, mediaInputs: [])
    }
}

private struct RoutingProbeError: Error, Sendable { let marker: String }
private struct RoutingProbeEngine: VideoGenerationEngine {
    let marker: String
    func generate(_ request: VideoGenerationRequest) async throws -> GeneratedVideo { throw RoutingProbeError(marker: marker) }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { _ = try await expression(); XCTFail("Expected error", file: file, line: line) }
    catch { handler(error) }
}
