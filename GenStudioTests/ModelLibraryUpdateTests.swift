import CryptoKit
import XCTest
@testable import GenStudio

private struct UpdateFixtureTransport: ModelDownloadTransport {
    let bytes: Data
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try bytes.write(to: to); progress(Int64(bytes.count))
    }
}
private struct UpdateFixtureMetadata: ModelUpdateMetadataProvider {
    let revision: ModelRepositoryRevision
    func head(repository: String) async throws -> ModelRepositoryRevision { revision }
}

private struct ChecksumFixtureMetadata: ModelUpdateMetadataProvider {
    let revision: ModelRepositoryRevision
    let checksum: String
    func head(repository: String) async throws -> ModelRepositoryRevision { revision }
    func checksum(repository: String, revision: String, filename: String, expectedBytes: Int64) async throws -> String? { checksum }
}

final class ModelLibraryUpdateTests: XCTestCase {
    private func bytes(_ marker: UInt8) -> Data { Data([71, 71, 85, 70, 3, 0, 0, 0] + Array(repeating: marker, count: 64)) }
    private func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func recipe(_ bytes: Data) -> ModelRecipe {
        .init(id: "image-fixture", name: "Original", kind: .image, engineID: "stable-diffusion.cpp", components: [.init(id: "checkpoint", role: "checkpoint", repository: "test/model", revision: String(repeating: "a", count: 40), filename: "model.gguf", byteSize: Int64(bytes.count), sha256: sha(bytes), license: "test")], runtimeReady: false, minimumMemoryBytes: 0)
    }
    private func metadata(_ bytes: Data, filename: String = "model.gguf", digest: String? = nil) -> UpdateFixtureMetadata {
        .init(revision: .init(revision: String(repeating: "b", count: 40), files: [.init(filename: filename, byteSize: Int64(bytes.count), sha256: digest ?? sha(bytes))], license: "test"))
    }

    func testFrozenManifestSurvivesCatalogRemovalAndMetadataChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = bytes(1), original = recipe(bytes(1))
        let library = ModelLibrary(root: root, catalog: [original], transport: UpdateFixtureTransport(bytes: data), diskAvailable: { _ in Int64.max })
        let installed = try await library.install(recipe: original)
        let reopened = ModelLibrary(root: root, catalog: [])
        let resolved = try await reopened.resolveInstalledModel(id: installed.id)
        XCTAssertEqual(resolved.recipeSnapshot, original)
        XCTAssertEqual(resolved.id, original.id)
    }

    func testUpdateInstallsBesideOriginalAndSurvivesOfflineReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBytes = bytes(1), newBytes = bytes(2), original = recipe(bytes(1))
        let first = ModelLibrary(root: root, catalog: [original], transport: UpdateFixtureTransport(bytes: oldBytes), diskAvailable: { _ in Int64.max })
        _ = try await first.install(recipe: original)
        let updater = ModelLibrary(root: root, catalog: [], transport: UpdateFixtureTransport(bytes: newBytes), diskAvailable: { _ in Int64.max }, updateMetadata: metadata(newBytes))
        let result = try await updater.checkForUpdate(id: original.id)
        let candidate = try XCTUnwrap(result.candidate)
        XCTAssertEqual(candidate.baseRecipeID, original.id)
        XCTAssertNotEqual(candidate.id, original.id)
        XCTAssertFalse(candidate.runtimeReady)
        XCTAssertEqual(result.changedComponentIDs, ["checkpoint"])
        let repeated = try await updater.checkForUpdate(id: original.id)
        XCTAssertEqual(repeated.candidate?.id, candidate.id)
        _ = try await updater.install(recipe: candidate)
        let reopened = ModelLibrary(root: root, catalog: [])
        let old = try await reopened.resolveInstalledModel(id: original.id)
        let new = try await reopened.resolveInstalledModel(id: candidate.id)
        XCTAssertEqual(try Data(contentsOf: old.components[0].fileURL), oldBytes)
        XCTAssertEqual(try Data(contentsOf: new.components[0].fileURL), newBytes)
        XCTAssertFalse(new.inferenceVerified)
        try await reopened.remove(id: candidate.id)
        _ = try await reopened.resolveInstalledModel(id: original.id)
    }

    func testUnchangedFilesDoNotSuggestWeightsUpdateAndMissingFileRejects() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = bytes(1), original = recipe(data)
        let library = ModelLibrary(root: root, catalog: [original], transport: UpdateFixtureTransport(bytes: data), diskAvailable: { _ in Int64.max }, updateMetadata: metadata(data))
        _ = try await library.install(recipe: original)
        let result = try await library.checkForUpdate(id: original.id)
        XCTAssertNil(result.candidate)
        let missing = ModelLibrary(root: root, updateMetadata: metadata(data, filename: "different.gguf"))
        do { _ = try await missing.checkForUpdate(id: original.id); XCTFail("Missing exact component must reject") } catch { }
        let old = try await library.resolveInstalledModel(id: original.id)
        XCTAssertEqual(old.id, original.id)
    }

    func testCurrentRevisionDoesNotRequireHubChecksumsForNonLFSMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = bytes(1), original = recipe(data)
        let unchangedMetadata = UpdateFixtureMetadata(revision: .init(
            revision: original.components[0].revision,
            files: [.init(filename: "model.gguf", byteSize: Int64(data.count), sha256: nil)],
            license: "publisher-card-value-does-not-replace-a-frozen-manifest"
        ))
        let library = ModelLibrary(root: root, catalog: [original], transport: UpdateFixtureTransport(bytes: data), diskAvailable: { _ in Int64.max }, updateMetadata: unchangedMetadata)
        _ = try await library.install(recipe: original)

        let result = try await library.checkForUpdate(id: original.id)

        XCTAssertNil(result.candidate)
        XCTAssertEqual(result.changedComponentIDs, [])
        XCTAssertTrue(result.message.contains("unchanged"))
    }

    func testChangedRevisionPinsSmallMetadataAndPreservesRemotePath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(#"{"version":1}"#.utf8), digest = sha(data)
        let original = ModelRecipe(
            id: "nested-fixture", name: "Nested", kind: .vision, engineID: "mlx-vlm",
            components: [.init(id: "config", role: "config", repository: "test/model", revision: String(repeating: "a", count: 40), filename: "nested/config.json", byteSize: Int64(data.count), sha256: digest, license: "test", sourceFilename: "config.json")],
            runtimeReady: false, minimumMemoryBytes: 0, runtimeProfile: "mlx-vlm", provider: "huggingface", workflowCapabilities: [.textGeneration, .imageUnderstanding]
        )
        let updatedData = Data(#"{"version":2}"#.utf8), updatedDigest = sha(updatedData)
        let metadata = ChecksumFixtureMetadata(revision: .init(
            revision: String(repeating: "b", count: 40),
            files: [.init(filename: "config.json", byteSize: Int64(updatedData.count), sha256: nil)], license: "test"
        ), checksum: updatedDigest)
        let library = ModelLibrary(root: root, catalog: [original], transport: UpdateFixtureTransport(bytes: data), diskAvailable: { _ in Int64.max }, updateMetadata: metadata)
        _ = try await library.install(recipe: original)

        let check = try await library.checkForUpdate(id: original.id)
        let candidate = try XCTUnwrap(check.candidate)

        XCTAssertEqual(candidate.components[0].filename, "nested/config.json")
        XCTAssertEqual(candidate.components[0].sourceFilename, "config.json")
        XCTAssertEqual(candidate.components[0].sha256, updatedDigest)
        XCTAssertEqual(candidate.runtimeProfile, "mlx-vlm")
        XCTAssertEqual(candidate.workflowCapabilities, [.textGeneration, .imageUnderstanding])
    }

    func testChangedCandidateCannotBypassAdmissionAndFailedUpdateKeepsOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "UpdateTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = bytes(1), original = recipe(data)
        let library = ModelLibrary(root: root, catalog: [original], transport: UpdateFixtureTransport(bytes: data), diskAvailable: { _ in Int64.max }, updateMetadata: metadata(bytes(2)))
        _ = try await library.install(recipe: original)
        let check = try await library.checkForUpdate(id: original.id)
        let candidate = try XCTUnwrap(check.candidate)
        let forged = ModelRecipe(id: candidate.id, name: candidate.name, kind: .text, engineID: "llama.cpp", components: candidate.components, runtimeReady: true, minimumMemoryBytes: 0)
        do { _ = try await library.install(recipe: forged); XCTFail("Changed metadata must reject") } catch { }
        do { _ = try await library.install(recipe: candidate); XCTFail("Wrong downloaded hash must reject") } catch { }
        let models = try await library.installedModels()
        XCTAssertEqual(models.map(\.id), [original.id])
        _ = try await library.resolveInstalledModel(id: original.id)
    }
}
