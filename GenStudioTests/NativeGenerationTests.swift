import XCTest
import ImageIO
@testable import GenStudio

final class NativeGenerationTests: XCTestCase, @unchecked Sendable {
    func testProcessCancellationReapsAndAllowsNextRun() async throws {
        let runner = NativeProcessRunner()
        let task = Task { try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { throw error }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let next = try await NativeProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["NEXT_JOB"], timeout: .seconds(3))
        XCTAssertEqual(next.status, 0); XCTAssertEqual(next.stdout, "NEXT_JOB")
    }

    func testProcessTimeoutAndBoundedOutput() async throws {
        do {
            _ = try await NativeProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: .milliseconds(100))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? StudioError, .timedOut) }
        let result = try await NativeProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1048576", "/dev/zero"], timeout: .seconds(5))
        XCTAssertEqual(result.status, 0); XCTAssertEqual(result.stdout.utf8.count, 512 * 1024)
    }

    func testProcessEnvironmentKeepsManagedPythonReadOnlyAndIsolated() async throws {
        let result = try await NativeProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], timeout: .seconds(3))
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("PYTHONDONTWRITEBYTECODE=1"))
        XCTAssertTrue(result.stdout.contains("PYTHONNOUSERSITE=1"))
        XCTAssertFalse(result.stdout.contains("PYTHONPATH="))
    }

    func testUnsupportedReferenceRejectedBeforeLoading() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = NativeImageEngine(library: ModelLibrary(root: root), outputRoot: root.appending(path: "outputs"))
        var (request, _) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .textToImage, prompt: "test", width: 512, height: 512, seed: 42, strength: nil, registry: ImageCapabilityRegistry.shipped)
        request.referenceImage = root.appending(path: "reference.png")
        do {
            _ = try await engine.generate(request)
            XCTFail("Connected references must not be silently ignored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Disconnect the reference")) }
        // A withdrawn route is still a hard block, and its recorded reason is what the user sees.
        let withdrawn = NativeImageEngine(library: ModelLibrary(root: root), outputRoot: root.appending(path: "outputs"),
            capabilities: [ImageCapabilityRegistry.sd15ImageToImage.with(readiness: .unavailable(reason: "This route was withdrawn."))])
        var (edit, _) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .imageToImage, prompt: "test", width: 512, height: 512, seed: 42, strength: 0.5, registry: [ImageCapabilityRegistry.sd15ImageToImage])
        edit.referenceImage = root.appending(path: "reference.png")
        do {
            _ = try await withdrawn.generate(edit)
            XCTFail("Withdrawn adapters must not run")
        } catch { XCTAssertTrue(error.localizedDescription.contains("withdrawn"), error.localizedDescription) }
    }

    /// Explicit opt-in, using files already on disk. Never downloads test weights.
    func testRealBundledGenerationAndOfflineLibraryReopen() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_NATIVE_GENERATION_INTEGRATION"] == "1",
              let textPath = environment["NATIVE_TEST_TEXT_WEIGHTS"], let imagePath = environment["NATIVE_TEST_IMAGE_WEIGHTS"] else {
            throw XCTSkip("Opt in with RUN_NATIVE_GENERATION_INTEGRATION and existing text/image weight paths.")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudio-Native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: root)
        for (id, path) in [("qwen25-05b-q4km", textPath), ("sd15-q4", imagePath)] {
            let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == id })
            let component = try XCTUnwrap(recipe.components.first)
            _ = try await library.importFiles(recipe: recipe, filesByComponentID: [component.id: URL(fileURLWithPath: path)], progress: { _ in })
        }
        let textEngine = NativeTextEngine(library: library)
        let response = try await textEngine.generate(prompt: "Reply with exactly LOCAL_READY.", model: "qwen25-05b-q4km", temperature: 0, maxTokens: 20, timeout: .seconds(90))
        XCTAssertTrue(response.contains("LOCAL_READY"), response)
        let imageEngine = NativeImageEngine(library: library, outputRoot: root.appending(path: "outputs"))
        let (request, _) = try ImageRequestPlanner.makeRequest(recipeID: "sd15-q4", task: .textToImage, prompt: "a red apple on a dark table, studio photograph, detailed", width: 512, height: 512, seed: 424242, strength: nil, registry: ImageCapabilityRegistry.shipped)
        let output = try await imageEngine.generate(request)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 512); XCTAssertEqual(image.height, 512)
        if let evidence = environment["NATIVE_TEST_EVIDENCE_DIRECTORY"] {
            let directory = URL(fileURLWithPath: evidence)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contentsOf: output).write(to: directory.appending(path: "native-app-image.png"))
            try response.write(to: directory.appending(path: "native-app-text.txt"), atomically: true, encoding: .utf8)
        }
        let reopened = ModelLibrary(root: root)
        let installed = try await reopened.installedModels()
        XCTAssertEqual(installed.count, 2); XCTAssertTrue(installed.allSatisfy(\.inferenceVerified))
        let restartedText = try await NativeTextEngine(library: reopened).generate(prompt: "Reply with exactly RESTART_READY.", model: "qwen25-05b-q4km", temperature: 0, maxTokens: 20, timeout: .seconds(90))
        XCTAssertTrue(restartedText.contains("RESTART_READY"), restartedText)
    }
}
