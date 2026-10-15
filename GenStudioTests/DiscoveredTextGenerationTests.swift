import XCTest
@testable import GenStudio

final class DiscoveredTextGenerationTests: XCTestCase, @unchecked Sendable {
    func testExplicitGGUFImportGeneratesAndReopensOffline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RUN_DISCOVERED_TEXT_INTEGRATION"] == "1", let path = env["DISCOVERED_TEXT_WEIGHTS"] else {
            throw XCTSkip("Opt in with existing local GGUF weights; never downloads test models.")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudio-DiscoveredText-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == "qwen25-05b-q4km" })
        let recipe = ModelRecipe(id: "text-gguf-integration", name: "Explicit GGUF integration", kind: .text, engineID: "llama.cpp", components: original.components,
            runtimeReady: false, minimumMemoryBytes: original.minimumMemoryBytes)
        let library = ModelLibrary(root: root)
        try await library.admitTextRecipe(recipe)
        let model = try await library.importFiles(recipe: recipe, filesByComponentID: ["model": URL(fileURLWithPath: path)])
        XCTAssertFalse(model.inferenceVerified)
        let reopened = ModelLibrary(root: root, catalog: [])
        let result = try await NativeTextEngine(library: reopened).generate(prompt: "Say hello in one short sentence.", model: model.id, temperature: 0, maxTokens: 32, timeout: .seconds(120))
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.contains("[end of text]"))
        XCTAssertFalse(result.contains("llama_model_loader"))
        let installed = try await reopened.installedModels()
        XCTAssertTrue(try XCTUnwrap(installed.first).inferenceVerified)
        XCTAssertEqual(installed.first?.id, model.id)
    }
}
