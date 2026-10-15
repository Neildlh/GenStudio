import CryptoKit
import XCTest
@testable import GenStudio

private struct SlowFixtureTransport: ModelDownloadTransport {
    let bytes: Data
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await Task.sleep(for: .milliseconds(150))
        try bytes.write(to: to); progress(Int64(bytes.count))
    }
}

/// The owner could not find a clear Install button. Every listing now shares one control whose state comes
/// from `ModelInstallState`, and a second Install while one downloads queues instead of greying out.
@MainActor
final class ModelInstallControlTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private func fixture(_ tag: String) -> Data {
        var data = Data("GGUF".utf8); data.append(contentsOf: [3, 0, 0, 0]); data.append(Data(tag.utf8)); data.append(Data(repeating: 0, count: 64)); return data
    }
    private func recipe(_ id: String, _ bytes: Data) -> ModelRecipe {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(id: id, name: id, kind: .text, engineID: "llama.cpp", components: [
            ModelComponent(id: "model", role: "model", repository: "test/\(id)", revision: String(repeating: "a", count: 40), filename: "\(id).gguf", byteSize: Int64(bytes.count), sha256: digest, license: "test")
        ], runtimeReady: true, minimumMemoryBytes: 0)
    }
    private func store(_ recipes: [ModelRecipe], data: Data) -> (ModelLibraryViewModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudioInstallControl-\(UUID())", directoryHint: .isDirectory)
        let library = ModelLibrary(root: root, catalog: recipes, transport: SlowFixtureTransport(bytes: data), diskAvailable: { _ in Int64.max })
        return (ModelLibraryViewModel(library: library), root)
    }

    func testSecondInstallQueuesAndStartsWhenTheFirstFinishes() async throws {
        let data = fixture("shared")
        let first = recipe("first", data), second = recipe("second", data)
        let (store, root) = store([first, second], data: data); defer { try? FileManager.default.removeItem(at: root) }

        store.requestInstall(first)
        XCTAssertEqual(ModelInstallState.resolve(first, in: store), .installing(fraction: 0))
        guard case .ready(_, let startsAfter) = ModelInstallState.resolve(second, in: store) else { return XCTFail("still installable while another downloads") }
        XCTAssertTrue(startsAfter, "the button says it will wait")

        store.requestInstall(second)
        XCTAssertEqual(ModelInstallState.resolve(second, in: store), .queued(position: 1))
        store.requestInstall(second)
        XCTAssertEqual(store.queuedRecipes.count, 1, "a second click does not queue it twice")

        for _ in 0..<300 where !(store.isInstalled(first.id) && store.isInstalled(second.id)) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(ModelInstallState.resolve(first, in: store), .installed)
        XCTAssertEqual(ModelInstallState.resolve(second, in: store), .installed, "the queued package installed without another click")
        XCTAssertTrue(store.queuedRecipes.isEmpty)
        XCTAssertNil(store.failure)
    }

    func testRemovedFromQueueDoesNotInstall() async throws {
        let data = fixture("queue")
        let first = recipe("first", data), second = recipe("second", data)
        let (store, root) = store([first, second], data: data); defer { try? FileManager.default.removeItem(at: root) }
        store.requestInstall(first); store.requestInstall(second)
        store.removeFromQueue(second.id)
        XCTAssertNil(store.queuePosition(second.id))
        for _ in 0..<200 where store.busy { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(store.isInstalled(first.id))
        XCTAssertFalse(store.isInstalled(second.id))
    }

    func testAPackageWithNoRouteShowsWhyInsteadOfAnInstallButton() {
        let data = fixture("blocked")
        var blocked = recipe("blocked", data); blocked = .init(id: blocked.id, name: blocked.name, kind: .text, engineID: "llama.cpp", components: blocked.components, runtimeReady: false, minimumMemoryBytes: 0)
        let (store, root) = store([blocked], data: data); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(ModelInstallState.resolve(blocked, in: store), .blocked(reason: "GenStudio can't run this model yet"))
        store.requestInstall(blocked)
        XCTAssertFalse(store.busy, "a blocked package never starts")
    }

    func testReadyStateShowsOnlyTheBytesStillToDownload() {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: FileManager.default.temporaryDirectory.appending(path: "GenStudioInstallBytes-\(UUID())")))
        store.hardware = HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 * gib, osVersion: "Version 27.0", freeDiskBytes: 400_000_000_000,
                                         totalDiskBytes: 994_000_000_000, gpuWorkingSetBytes: 52 * gib, performanceCores: 8, efficiencyCores: 2, gpuCores: 32)
        let z = try! XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.zImageTurboRecipeID })
        XCTAssertEqual(ModelInstallState.resolve(z, in: store), .ready(downloadBytes: z.totalBytes, startsAfterCurrent: false))
    }

    // MARK: Z-Image Turbo

    func testZImageTurboIsAnInstallablePinnedRecipeSharingKleinsTextEncoder() throws {
        let z = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.zImageTurboRecipeID })
        let klein = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == MediaModelCatalog.kleinRecipeID })
        XCTAssertEqual(z.components.map(\.id), ["diffusion", "textEncoder", "vae"])
        XCTAssertEqual(z.components.first { $0.id == "textEncoder" }, klein.components.first { $0.id == "textEncoder" }, "identical bytes, so installing both downloads it once")
        XCTAssertTrue(z.components.allSatisfy { $0.sha256.count == 64 && $0.revision.count == 40 && $0.byteSize > 0 })
        XCTAssertFalse(z.components.contains { $0.repository.hasPrefix("black-forest-labs/") }, "no gated repository: GenStudio collects no Hugging Face credentials")
        XCTAssertTrue(ModelLibraryViewModel.hasAdapter(z))
        XCTAssertNil(ModelCandidateCatalog.candidate(forRepository: "leejet/Z-Image-Turbo-GGUF"), "no longer listed as unimplemented")
        let fit = RecipeFit.assess(recipe: z, hardware: FitFixtures.m1Max(), installed: [])
        XCTAssertTrue(fit.canInstall, fit.label)
        XCTAssertEqual(ImageCapabilityRegistry.capability(recipeID: z.id, task: .textToImage)?.readiness, .awaitingProof, "runs on first use and earns its proof")
        XCTAssertNil(ImageCapabilityRegistry.capability(recipeID: z.id, task: .imageToImage), "text to image only")
    }

    func testZImageTurboUsesThePinnedEngineExampleCommand() throws {
        let (request, capability) = try ImageRequestPlanner.makeRequest(recipeID: MediaModelCatalog.zImageTurboRecipeID, task: .textToImage, prompt: "apple",
                                                                         width: 512, height: 512, seed: 42, strength: nil, registry: ImageCapabilityRegistry.shipped)
        let components = ["diffusion": URL(fileURLWithPath: "/m/z.gguf"), "textEncoder": URL(fileURLWithPath: "/m/q.gguf"), "vae": URL(fileURLWithPath: "/m/ae.safetensors")]
        XCTAssertEqual(try ImageAdapterCommand.arguments(request, capability: capability, components: components, output: URL(fileURLWithPath: "/o/out.png")),
                       ["-M", "img_gen", "--diffusion-model", "/m/z.gguf", "--vae", "/m/ae.safetensors", "--llm", "/m/q.gguf", "-p", "apple", "-W", "512", "-H", "512",
                        "--steps", "8", "--cfg-scale", "1.0", "--diffusion-fa", "--offload-to-cpu", "--seed", "42", "-o", "/o/out.png"])
    }
}
