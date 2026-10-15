import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

enum UpscaleFixtures {
    static func root(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "GenStudio-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func solidPNG(width: Int, height: Int, in directory: URL, name: String) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appending(path: "\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// A minimal ZIP-local-file-header-shaped fixture file, matching what NativeUpscaleEngine's `.pth`
    /// header check requires. Never real weights; content and size are otherwise arbitrary.
    static func fixtureCheckpoint(in directory: URL) throws -> (url: URL, byteSize: Int64, sha256: String) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "fixture-checkpoint.pth")
        var data = Data([0x50, 0x4B, 0x03, 0x04])
        data.append(Data(repeating: 0x11, count: 60))
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, Int64(data.count), digest)
    }

    static func fixtureRecipe(id: String, byteSize: Int64, sha256: String) -> ModelRecipe {
        .init(id: id, name: "Fixture Upscaler", kind: .upscaler, engineID: "stable-diffusion.cpp", components: [
            .init(id: "checkpoint", role: "checkpoint", repository: "genstudio-tests/fixture-upscaler", revision: String(repeating: "a", count: 40), filename: "fixture.pth", byteSize: byteSize, sha256: sha256, license: "Test fixture")
        ], runtimeReady: false, minimumMemoryBytes: 1024)
    }

    /// Installs a fixture recipe into a fresh ModelLibrary rooted at `root` and returns it plus the recipe.
    static func installedLibrary(root: URL) async throws -> (library: ModelLibrary, recipe: ModelRecipe) {
        let checkpoint = try fixtureCheckpoint(in: root.appending(path: "Sources"))
        let recipe = fixtureRecipe(id: "fixture-upscaler-\(UUID().uuidString)", byteSize: checkpoint.byteSize, sha256: checkpoint.sha256)
        let library = ModelLibrary(root: root.appending(path: "ModelLibrary"), catalog: [recipe], diskAvailable: { _ in Int64.max })
        _ = try await library.importFiles(recipe: recipe, filesByComponentID: ["checkpoint": checkpoint.url])
        return (library, recipe)
    }

    /// Writes an executable `/bin/sh` fixture standing in for `sd-cli -M upscale ...`. It locates the
    /// `-o` argument and, if `copyFrom` is set, copies that fixed file to it — the caller pre-generates
    /// exactly the PNG bytes each scenario needs (correct size, wrong size, etc). No environment
    /// variables are used because NativeProcessRunner deliberately does not pass the test process's
    /// environment through to the child process.
    static func fixtureExecutable(exitCode: Int32, stderrMarker: String? = nil, copyFrom: URL? = nil, in directory: URL, name: String) throws -> URL {
        let script = directory.appending(path: name)
        var body = "#!/bin/sh\nOUT=\"\"\nwhile [ $# -gt 0 ]; do\n  case \"$1\" in\n    -o) OUT=\"$2\"; shift 2 ;;\n    *) shift ;;\n  esac\ndone\n"
        if let stderrMarker { body += "echo '\(stderrMarker)' 1>&2\n" }
        if let copyFrom { body += "cp '\(copyFrom.path)' \"$OUT\"\n" }
        body += "exit \(exitCode)\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

/// Returns a pre-generated PNG in place of real inference. Used only to test executor wiring
/// (persistence, provenance, retention), never as upscale-quality evidence. Mirrors FixtureVideoEngine.
actor FixtureUpscaleEngine: ImageUpscaleEngine {
    enum Behaviour: Sendable { case succeed(URL), fail, waitForCancellation }
    let behaviour: Behaviour
    private(set) var requests: [UpscaleRequest] = []
    init(_ behaviour: Behaviour) { self.behaviour = behaviour }
    func captured() -> [UpscaleRequest] { requests }
    func upscale(_ request: UpscaleRequest) async throws -> URL {
        requests.append(request)
        switch behaviour {
        case .fail: throw StudioError.validation("fixture upscale engine failure")
        case .waitForCancellation: try await Task.sleep(for: .seconds(60)); throw StudioError.timedOut
        case .succeed(let template):
            let copy = template.deletingLastPathComponent().appending(path: "\(UUID().uuidString).png")
            try FileManager.default.copyItem(at: template, to: copy)
            return copy
        }
    }
}

// MARK: - Catalog and picker exclusion

final class UpscaleCatalogTests: XCTestCase {
    func testPinnedRecipesMatchTheResearchBrief() throws {
        let general = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == UpscaleCapabilityRegistry.realesrganX4PlusRecipeID })
        XCTAssertEqual(general.kind, .upscaler)
        XCTAssertEqual(general.engineID, "stable-diffusion.cpp")
        let generalComponent = try XCTUnwrap(general.components.first)
        XCTAssertEqual(generalComponent.repository, "amd/realesrgan-x4plus")
        XCTAssertEqual(generalComponent.revision, "bda69abcaf525425b371622349e975245ae090c2")
        XCTAssertEqual(generalComponent.filename, "RealESRGAN_x4plus.pth")
        XCTAssertEqual(generalComponent.byteSize, 67_040_989)
        XCTAssertEqual(generalComponent.sha256, "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1")
        XCTAssertTrue(generalComponent.license.contains("BSD-3-Clause"))

        let anime = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == UpscaleCapabilityRegistry.realesrganX4PlusAnimeRecipeID })
        XCTAssertEqual(anime.kind, .upscaler)
        let animeComponent = try XCTUnwrap(anime.components.first)
        XCTAssertEqual(animeComponent.repository, "amd/realesrgan-x4plus-anime-6b")
        XCTAssertEqual(animeComponent.revision, "b14ff5f8ecb5a4b56ce4049a58d0bca1f8814690")
        XCTAssertEqual(animeComponent.filename, "RealESRGAN_x4plus_anime_6B.pth")
        XCTAssertEqual(animeComponent.byteSize, 17_938_799)
        XCTAssertEqual(animeComponent.sha256, "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da")
        XCTAssertTrue(animeComponent.license.contains("BSD-3-Clause"))

        // Both are pinned exact 40-hex-character git revisions and 64-hex-character SHA-256 digests,
        // satisfying ModelLibrary's shared recipe-shape validation.
        for component in [generalComponent, animeComponent] {
            XCTAssertEqual(component.revision.count, 40); XCTAssertTrue(component.revision.allSatisfy(\.isHexDigit))
            XCTAssertEqual(component.sha256.count, 64); XCTAssertTrue(component.sha256.allSatisfy(\.isHexDigit))
        }
    }

    func testGeneralAndIllustrationGuidanceAreDistinct() {
        let general = UpscaleCapabilityRegistry.x4Plus.qualityNote
        let illustration = UpscaleCapabilityRegistry.x4PlusAnime.qualityNote
        XCTAssertNotEqual(general, illustration)
        XCTAssertTrue(general.localizedCaseInsensitiveContains("photograph"))
        XCTAssertTrue(illustration.localizedCaseInsensitiveContains("illustration"))
    }

    func testBothUpscalerRecipesHaveGenStudioAdapterProof() {
        XCTAssertTrue(UpscaleCapabilityRegistry.x4Plus.readiness.proven)
        XCTAssertTrue(UpscaleCapabilityRegistry.x4PlusAnime.readiness.proven)
    }

    func testUpscalerModelsAreExcludedFromEveryOtherNodeModelPicker() {
        let installed = InstalledGenerationModel(id: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, name: "x", kind: .upscaler, engineID: "stable-diffusion.cpp", components: [], installedAt: Date(), inferenceVerified: true, available: true)
        for kind: GenerationModelKind in [.text, .image, .video, .vision] {
            XCTAssertFalse(NodeModelCompatibility.supports(installed, kind: kind), "Upscaler model must not satisfy \(kind) node requirements")
        }
        // requiredKind maps the node kind that actually needs it, independent of registry readiness.
        XCTAssertEqual(NodeModelCompatibility.requiredKind(for: .imageUpscale), .upscaler)
        XCTAssertEqual(NodeModelCompatibility.requiredKind(for: .videoUpscale), .upscaler)
        for kind in NodeKind.allCases where kind != .imageUpscale && kind != .videoUpscale {
            XCTAssertNotEqual(NodeModelCompatibility.requiredKind(for: kind), .upscaler, "Only Image/Video Upscale may require an upscaler model")
        }
    }

    @MainActor
    func testStudioModelGenerationPickersNeverIncludeUpscalerModels() throws {
        let root = try UpscaleFixtures.root("picker-exclusion"); defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.libraryStore.installed = [
            .init(id: "some-upscaler", name: "Upscaler", kind: .upscaler, engineID: "stable-diffusion.cpp", components: [], installedAt: Date(), inferenceVerified: true, available: true, verifiedUpscale: true)
        ]
        XCTAssertTrue(model.generationModels(.image).isEmpty)
        XCTAssertTrue(model.generationModels(.video).isEmpty)
        XCTAssertTrue(model.generationModels(.text).isEmpty)
        XCTAssertTrue(model.generationModels(.vision).isEmpty)
    }

    @MainActor
    func testModelLibraryPresentsUpscalerRecipesAlongsideImageAndVideo() {
        XCTAssertTrue(ModelLibraryViewModel.isMediaRecipe(UpscalerModelCatalog.recipes[0]))
        XCTAssertTrue(ModelLibraryViewModel.hasAdapter(UpscalerModelCatalog.recipes[0]))
    }

    @MainActor
    func testGeneralUpscalerIsIncludedInTheOneClickStarterSet() throws {
        let root = try UpscaleFixtures.root("starter-upscaler")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelLibraryViewModel(library: ModelLibrary(root: root))
        XCTAssertTrue(store.starterRecipes.contains { $0.id == UpscaleCapabilityRegistry.realesrganX4PlusRecipeID })
        XCTAssertFalse(store.starterRecipes.contains { $0.id == UpscaleCapabilityRegistry.realesrganX4PlusAnimeRecipeID })
    }
}

// MARK: - Backward-compatible Codable defaults

final class UpscaleCodableDefaultsTests: XCTestCase {
    func testOldNodeJSONWithoutUpscaleFieldsDecodesWithSafeDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"imageUpscale","label":"Upscale","position":{"x":0,"y":0}}
        """
        let node = try JSONDecoder().decode(StudioNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.upscaleScale, 4)
        XCTAssertEqual(node.upscaleTileSize, 128)
        XCTAssertNil(node.experimentalUpscaleRecipeID)
        XCTAssertTrue(node.supportsTakes)
    }

    func testOldInstalledModelJSONWithoutVerifiedUpscaleFallsBackToInferenceVerified() throws {
        let json = """
        {"id":"x","name":"x","kind":"upscaler","engineID":"stable-diffusion.cpp","components":[],"installedAt":"2026-01-01T00:00:00Z","inferenceVerified":true,"available":true}
        """
        var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
        let model = try decoder.decode(InstalledGenerationModel.self, from: Data(json.utf8))
        XCTAssertNil(model.verifiedUpscale)
        XCTAssertTrue(model.hasVerifiedUpscale)
    }

    func testOldRunSnapshotJSONWithoutUpscaleRequestDecodes() throws {
        let json = """
        {"projectID":"\(UUID().uuidString)","nodeID":"\(UUID().uuidString)","prompt":"p","model":"m","temperature":0,"maxTokens":1}
        """
        let snapshot = try JSONDecoder().decode(RunInputSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.upscaleRequest)
    }
}

// MARK: - Pure request/command validation (no weights)

final class UpscaleRequestPlannerTests: XCTestCase {
    private let verified = UpscaleCapabilityRegistry.x4Plus.with(readiness: .verified(evidence: "test"))

    func testInvalidScaleOrTileIsRejected() {
        XCTAssertThrowsError(try UpscaleRequestPlanner.validateSettings(recipeID: verified.recipeID, scale: 3, tileSize: 128, registry: [verified]))
        XCTAssertThrowsError(try UpscaleRequestPlanner.validateSettings(recipeID: verified.recipeID, scale: 4, tileSize: 100, registry: [verified]))
        XCTAssertNoThrow(try UpscaleRequestPlanner.validateSettings(recipeID: verified.recipeID, scale: 2, tileSize: 0, registry: [verified]))
    }

    /// Proof is a label, not a permission: an unmeasured route validates, a withdrawn one does not.
    func testUnverifiedRecipeValidatesButWithdrawnRecipeIsBlocked() {
        let unverified = UpscaleCapabilityRegistry.x4Plus.with(readiness: .awaitingProof)
        XCTAssertNoThrow(try UpscaleRequestPlanner.validateSettings(recipeID: unverified.recipeID, scale: 4, tileSize: 128, registry: [unverified]))
        let withdrawn = UpscaleCapabilityRegistry.x4Plus.with(readiness: .unavailable(reason: "This upscaler was withdrawn."))
        XCTAssertThrowsError(try UpscaleRequestPlanner.validateSettings(recipeID: withdrawn.recipeID, scale: 4, tileSize: 128, registry: [withdrawn])) {
            XCTAssertTrue($0.localizedDescription.contains("withdrawn"), $0.localizedDescription)
        }
    }

    func testResolvedTileSizeFallsBackToCapabilityDefaultOnlyForAuto() {
        XCTAssertEqual(UpscaleRequestPlanner.resolvedTileSize(0, defaultTileSize: 128), 128)
        XCTAssertEqual(UpscaleRequestPlanner.resolvedTileSize(64, defaultTileSize: 128), 64)
    }

    /// Exactly at both bounds: 2048×2048 source → 8192×8192 (4×) is 67,108,864 px, the exact limit.
    func testCheckedBoundsAcceptExactlyAtTheLimit() throws {
        let capability = try UpscaleRequestPlanner.validate(recipeID: verified.recipeID, scale: 4, tileSize: 128, sourceWidth: 2048, sourceHeight: 2048, registry: [verified])
        XCTAssertEqual(capability.recipeID, verified.recipeID)
    }

    func testCheckedBoundsRejectSideOverflowBeforeAnyProcessLaunches() {
        // 4097 × 4 = 16388 > 16384, rejected purely on the per-side bound.
        XCTAssertThrowsError(try UpscaleRequestPlanner.validate(recipeID: verified.recipeID, scale: 4, tileSize: 128, sourceWidth: 4097, sourceHeight: 100, registry: [verified])) { error in
            XCTAssertTrue(error.localizedDescription.contains("pixels per side"))
        }
    }

    func testCheckedBoundsRejectAreaOverflowEvenWhenBothSidesPass() {
        // 4096×2048 → 16384×8192 (both sides ≤ 16384) but area 134,217,728 > 67,108,864.
        XCTAssertThrowsError(try UpscaleRequestPlanner.validate(recipeID: verified.recipeID, scale: 4, tileSize: 128, sourceWidth: 4096, sourceHeight: 2048, registry: [verified])) { error in
            XCTAssertTrue(error.localizedDescription.contains("pixels."))
        }
    }

    func testCheckedMultiplicationNeverTrapsOnHugeInput() {
        XCTAssertThrowsError(try UpscaleRequestPlanner.validate(recipeID: verified.recipeID, scale: 4, tileSize: 128, sourceWidth: Int.max / 2, sourceHeight: 4, registry: [verified]))
    }

    func testInvalidOrMissingDimensionsAreRejected() {
        XCTAssertThrowsError(try UpscaleRequestPlanner.validate(recipeID: verified.recipeID, scale: 4, tileSize: 128, sourceWidth: 0, sourceHeight: 100, registry: [verified]))
        XCTAssertThrowsError(try UpscaleRequestPlanner.validate(recipeID: verified.recipeID, scale: 4, tileSize: 128, sourceWidth: 100, sourceHeight: -1, registry: [verified]))
    }

    func testUnknownRecipeIsRejected() {
        XCTAssertThrowsError(try UpscaleRequestPlanner.validateSettings(recipeID: "not-a-real-recipe", scale: 4, tileSize: 128, registry: [verified]))
    }
}

final class UpscaleAdapterCommandTests: XCTestCase {
    func testArgumentsMatchTheProvenSdCliUpscaleProfile() throws {
        let capability = UpscaleCapabilityRegistry.x4Plus
        let request = UpscaleRequest(recipeID: capability.recipeID, engineBuild: capability.engineBuild, scale: 4, tileSize: 128, sourceImage: URL(fileURLWithPath: "/tmp/in.png"), sourceIdentity: .init(sha256: "0", byteSize: 0))
        let checkpoint = URL(fileURLWithPath: "/tmp/model.pth"), output = URL(fileURLWithPath: "/tmp/out.png")
        let arguments = try UpscaleAdapterCommand.arguments(request, capability: capability, checkpoint: checkpoint, output: output)
        XCTAssertEqual(arguments, ["-M", "upscale", "--upscale-model", "/tmp/model.pth", "--upscale-tile-size", "128", "-i", "/tmp/in.png", "-o", "/tmp/out.png"])
    }

    func testMismatchedRecipeOrEngineBuildIsRejected() {
        let capability = UpscaleCapabilityRegistry.x4Plus
        let wrongRecipe = UpscaleRequest(recipeID: "other", engineBuild: capability.engineBuild, scale: 4, tileSize: 128, sourceImage: URL(fileURLWithPath: "/tmp/in.png"), sourceIdentity: .init(sha256: "0", byteSize: 0))
        XCTAssertThrowsError(try UpscaleAdapterCommand.arguments(wrongRecipe, capability: capability, checkpoint: URL(fileURLWithPath: "/tmp/m"), output: URL(fileURLWithPath: "/tmp/o")))
    }

    func testInvalidResolvedTileSizeIsRejected() {
        let capability = UpscaleCapabilityRegistry.x4Plus
        let request = UpscaleRequest(recipeID: capability.recipeID, engineBuild: capability.engineBuild, scale: 4, tileSize: 100, sourceImage: URL(fileURLWithPath: "/tmp/in.png"), sourceIdentity: .init(sha256: "0", byteSize: 0))
        XCTAssertThrowsError(try UpscaleAdapterCommand.arguments(request, capability: capability, checkpoint: URL(fileURLWithPath: "/tmp/m"), output: URL(fileURLWithPath: "/tmp/o")))
    }
}

final class UpscaleDiskPreflightTests: XCTestCase {
    func testRequiredBytesIsCheckedAndPositive() {
        let bytes = UpscaleDiskPreflight.requiredBytes(x4Width: 2048, x4Height: 2048, finalWidth: 1024, finalHeight: 1024)
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 0)
    }
    func testRequiredBytesRejectsInvalidDimensionsAndOverflow() {
        XCTAssertNil(UpscaleDiskPreflight.requiredBytes(x4Width: 0, x4Height: 100, finalWidth: 10, finalHeight: 10))
        XCTAssertNil(UpscaleDiskPreflight.requiredBytes(x4Width: Int.max, x4Height: Int.max, finalWidth: 10, finalHeight: 10))
    }
    func testFreeBytesNeverCrashesForAMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "does-not-exist-\(UUID().uuidString)/deeper")
        XCTAssertGreaterThanOrEqual(UpscaleDiskPreflight.freeBytes(at: missing), 0)
    }
}

// MARK: - NativeUpscaleEngine: exit-code, error-marker and dimension defenses (fixture sd-cli, no weights)

final class UpscaleEngineDefenseTests: XCTestCase {
    private func request(recipeID: String, engineBuild: String, scale: Int, source: URL) throws -> UpscaleRequest {
        .init(recipeID: recipeID, engineBuild: engineBuild, scale: scale, tileSize: 128, sourceImage: source, sourceIdentity: try MediaIdentity.of(source))
    }

    func testNonZeroExitIsRejectedRegardlessOfOutput() async throws {
        let root = try UpscaleFixtures.root("nonzero"); defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let source = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source")
        let script = try UpscaleFixtures.fixtureExecutable(exitCode: 1, in: root, name: "sd-fail")
        let capability = UpscaleCapability(recipeID: recipe.id, engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [capability])
        do {
            _ = try await engine.upscale(request(recipeID: recipe.id, engineBuild: "test-build", scale: 4, source: source))
            XCTFail("A non-zero exit must never be accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("failed"), error.localizedDescription) }
    }

    /// The exact defense the brief requires: the rejected x2 checkpoint exits 0, prints an error marker,
    /// and copies the input unchanged. Both the marker and the dimension check must independently catch this.
    func testZeroExitWithErrorMarkerIsRejectedEvenThoughOutputWasWritten() async throws {
        let root = try UpscaleFixtures.root("zeroexit-error"); defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let source = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source")
        // Simulates the copied-unchanged-input failure mode exactly.
        let script = try UpscaleFixtures.fixtureExecutable(exitCode: 0, stderrMarker: "[ERROR] tensor 'conv_first.weight' has wrong shape", copyFrom: source, in: root, name: "sd-error-marker")
        let capability = UpscaleCapability(recipeID: recipe.id, engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [capability])
        do {
            _ = try await engine.upscale(request(recipeID: recipe.id, engineBuild: "test-build", scale: 4, source: source))
            XCTFail("A zero-exit run that prints a runtime error marker must never be accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("runtime error"), error.localizedDescription) }
    }

    func testZeroExitWithNoErrorMarkerButWrongDimensionsIsStillRejected() async throws {
        let root = try UpscaleFixtures.root("wrong-dims"); defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let source = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source")
        // No error marker at all, but the "upscaled" output is the unchanged 8×8 input, not 32×32.
        let script = try UpscaleFixtures.fixtureExecutable(exitCode: 0, copyFrom: source, in: root, name: "sd-wrong-size")
        let capability = UpscaleCapability(recipeID: recipe.id, engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [capability])
        do {
            _ = try await engine.upscale(request(recipeID: recipe.id, engineBuild: "test-build", scale: 4, source: source))
            XCTFail("An unchanged/wrong-dimension result must never be accepted, even with no error marker")
        } catch { XCTAssertTrue(error.localizedDescription.contains("32×32") || error.localizedDescription.contains("valid"), error.localizedDescription) }
        // Nothing is left behind in scratch after a rejected result.
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Scratch").path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "Rejected output must not remain in scratch: \(leftover)")
    }

    func testExactFourTimesContractOnSuccess() async throws {
        let root = try UpscaleFixtures.root("x4-success"); defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let source = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source")
        let x4Result = try UpscaleFixtures.solidPNG(width: 32, height: 32, in: root, name: "x4result")
        let script = try UpscaleFixtures.fixtureExecutable(exitCode: 0, copyFrom: x4Result, in: root, name: "sd-ok")
        let capability = UpscaleCapability(recipeID: recipe.id, engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [capability])
        let output = try await engine.upscale(request(recipeID: recipe.id, engineBuild: "test-build", scale: 4, source: source))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(decoded.width, 32); XCTAssertEqual(decoded.height, 32)
        let reopened = try await library.installedModels().first { $0.id == recipe.id }
        XCTAssertEqual(reopened?.verifiedUpscale, true, "A decoded, dimension-verified render marks this exact recipe verified")
    }

    /// 2× must render the full proven 4× output first (validated exactly like the 4× path), then
    /// downsample it — never scale the source directly.
    func testTwoTimesRendersProvenFourTimesThenDownsamples() async throws {
        let root = try UpscaleFixtures.root("x2-success"); defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let source = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source")
        let x4Result = try UpscaleFixtures.solidPNG(width: 32, height: 32, in: root, name: "x4result")
        let script = try UpscaleFixtures.fixtureExecutable(exitCode: 0, copyFrom: x4Result, in: root, name: "sd-ok")
        let capability = UpscaleCapability(recipeID: recipe.id, engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [capability])
        let output = try await engine.upscale(request(recipeID: recipe.id, engineBuild: "test-build", scale: 2, source: source))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(decoded.width, 16); XCTAssertEqual(decoded.height, 16, "2× of an 8×8 source is 16×16, not the 32×32 intermediate")
        // The x4 intermediate must not survive as a leftover scratch file.
        let leftover = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Scratch").path)
        XCTAssertEqual(leftover.count, 1, "Only the final downsampled output remains in scratch: \(leftover)")
    }

    /// An unmeasured recipe runs on first use and needs no opt-in; a withdrawn one never runs.
    func testAwaitingProofRecipeRunsAndWithdrawnRecipeIsRefused() async throws {
        let root = try UpscaleFixtures.root("optin"); defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let source = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source")
        let x4Result = try UpscaleFixtures.solidPNG(width: 32, height: 32, in: root, name: "x4result")
        let script = try UpscaleFixtures.fixtureExecutable(exitCode: 0, copyFrom: x4Result, in: root, name: "sd-ok")
        let capability = UpscaleCapability(recipeID: recipe.id, engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .awaitingProof, qualityNote: "", measuredBaseline: nil)
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [capability])
        let unmeasured = try request(recipeID: recipe.id, engineBuild: "test-build", scale: 4, source: source)
        _ = try await engine.upscale(unmeasured)

        let withdrawnCapability = capability.with(readiness: .unavailable(reason: "This upscaler was withdrawn."))
        let withdrawnEngine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [withdrawnCapability])
        do { _ = try await withdrawnEngine.upscale(unmeasured); XCTFail("Withdrawn capability must not run") }
        catch { XCTAssertTrue(error.localizedDescription.contains("withdrawn"), error.localizedDescription) }
    }

    func testCancellationLeavesNoScratchFile() async throws {
        let root = try UpscaleFixtures.root("cancel"); defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let source = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source")
        let script = try UpscaleFixtures.fixtureExecutable(exitCode: 0, in: root, name: "sd-slow")
        // Overwrite with a sleeping script (fixtureExecutable already wrote a fast one above).
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let capability = UpscaleCapability(recipeID: recipe.id, engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), executableOverride: script, capabilities: [capability])
        let req = try request(recipeID: recipe.id, engineBuild: "test-build", scale: 4, source: source)
        let task = Task { try await engine.upscale(req) }
        try await Task.sleep(for: .milliseconds(200)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Scratch").path)) ?? []
        XCTAssertTrue(leftover.isEmpty, "Cancellation must not leave a scratch file: \(leftover)")
    }
}

// MARK: - ExecutionQueue wiring: node execution, persistence, provenance, take history

final class UpscaleExecutionQueueTests: XCTestCase {
    private func project(sourcePath: String? = nil) -> (WorkflowProject, StudioNode) {
        var input = StudioNode(kind: .imageInput, label: "Source", position: .init(x: 0, y: 0))
        input.imagePath = sourcePath
        var upscale = StudioNode(kind: .imageUpscale, label: "Upscale", position: .init(x: 1, y: 0), model: "fixture-recipe")
        upscale.upscaleScale = 4; upscale.upscaleTileSize = 128
        let preview = StudioNode(kind: .imagePreview, label: "Preview", position: .init(x: 2, y: 0))
        let edges = [
            StudioEdge(sourceID: input.id, sourcePortID: "image", targetID: upscale.id, targetPortID: "image", type: .image),
            StudioEdge(sourceID: upscale.id, sourcePortID: "image", targetID: preview.id, targetPortID: "image", type: .image)
        ]
        return (WorkflowProject(name: "Upscale", nodes: [input, upscale, preview], edges: edges), upscale)
    }

    func testSuccessfulRunRetainsImageAndRecordsProvenance() async throws {
        let root = try UpscaleFixtures.root("execqueue-success"); defer { try? FileManager.default.removeItem(at: root) }
        let sourcePath = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source").path
        let (graph, upscale) = project(sourcePath: sourcePath)
        let result4x = try UpscaleFixtures.solidPNG(width: 32, height: 32, in: root, name: "x4")
        let capability = UpscaleCapability(recipeID: "fixture-recipe", engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let engine = FixtureUpscaleEngine(.succeed(result4x))
        let store = StudioPersistence(root: root)
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, upscaleEngine: engine, upscaleCapabilities: [capability])
        let preview = graph.nodes[2]
        let result = try await queue.execute(project: graph, targetID: preview.id)
        guard case .image(let retained)? = result.values[.init(nodeID: preview.id, portID: "image")] else { return XCTFail("Expected upscaled image downstream") }
        XCTAssertTrue(retained.path.contains("/Artifacts/"))
        let requests = await engine.captured()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.scale, 4); XCTAssertEqual(requests.first?.tileSize, 128); XCTAssertEqual(requests.first?.recipeID, "fixture-recipe")
        let runs = try await store.loadRuns()
        let run = try XCTUnwrap(runs.first { $0.snapshot.nodeID == upscale.id })
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.snapshot.upscaleRequest?.scale, 4)
        XCTAssertEqual(run.snapshot.upscaleRequest?.tileSize, 128)
        XCTAssertEqual(run.snapshot.upscaleRequest?.recipeID, "fixture-recipe")
        XCTAssertEqual(run.snapshot.imageWidth, 8); XCTAssertEqual(run.snapshot.imageHeight, 8)
    }

    func testFailedAndCancelledRunsRecordAttemptWithoutOutput() async throws {
        let root = try UpscaleFixtures.root("execqueue-failure"); defer { try? FileManager.default.removeItem(at: root) }
        let sourcePath = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source").path
        let (graph, upscale) = project(sourcePath: sourcePath)
        let capability = UpscaleCapability(recipeID: "fixture-recipe", engineID: "stable-diffusion.cpp", engineBuild: "test-build", defaultTileSize: 128, readiness: .verified(evidence: "test"), qualityNote: "", measuredBaseline: nil)
        let store = StudioPersistence(root: root)
        do {
            _ = try await ExecutionQueue(engine: StubEngine(), persistence: store, upscaleEngine: FixtureUpscaleEngine(.fail), upscaleCapabilities: [capability]).execute(project: graph, targetID: upscale.id)
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("fixture upscale engine failure")) }
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, upscaleEngine: FixtureUpscaleEngine(.waitForCancellation), upscaleCapabilities: [capability])
        let task = Task { try await queue.execute(project: graph, targetID: upscale.id) }
        try await Task.sleep(for: .milliseconds(300)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let runs = try await store.loadRuns()
        XCTAssertEqual(Set(runs.map(\.status)), [.failed, .cancelled])
        XCTAssertTrue(runs.allSatisfy { $0.snapshot.nodeID == upscale.id && $0.snapshot.upscaleRequest?.scale == 4 })
        let artifacts = try await store.loadExecutionArtifacts()
        XCTAssertTrue(artifacts.isEmpty, "No execution result is published for failed or cancelled runs")
        // The upstream Image Input node still succeeds and retains its own copy on each of the two
        // attempts (unlike the video fixture's text-only ancestor); the Upscale node itself must never
        // retain an output for a failed or cancelled run.
        let retained = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Artifacts").path)) ?? []
        XCTAssertEqual(retained.count, 2, "Only the two upstream Image Input retains are present: \(retained)")
    }

    /// A failed/cancelled rerun must never destroy an already-selected successful take.
    @MainActor
    func testModelKeepsSuccessfulTakeAfterFailedRerun() async throws {
        let root = try UpscaleFixtures.root("stale-take"); defer { try? FileManager.default.removeItem(at: root) }
        let sourcePath = try UpscaleFixtures.solidPNG(width: 8, height: 8, in: root, name: "source").path
        let (graph, upscale) = project(sourcePath: sourcePath)
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine(), upscaleEngine: FixtureUpscaleEngine(.fail))
        model.projects = [graph]; model.currentProjectID = graph.id
        let old = URL(fileURLWithPath: "/tmp/old-take.png")
        model.executionArtifacts = [.init(id: UUID(), projectID: graph.id, targetID: upscale.id, graphSnapshot: graph, values: [.init(nodeID: upscale.id, portID: "image"): .image(old)], createdAt: Date())]
        XCTAssertEqual(model.displayedValue(for: upscale), .image(old))
        model.selectedNodeID = upscale.id
        model.runSelected()
        if model.pendingRun != nil { model.confirmPendingRun() }
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.displayedValue(for: upscale), .image(old), "A failed rerun must preserve the selected successful take")
        XCTAssertNotNil(model.supersededAttempts[upscale.id])
        XCTAssertEqual(model.executionArtifacts.count, 1, "The earlier result is preserved, not destroyed")
    }

    /// Take history for Image Upscale must behave exactly like a generation node: repeated runs
    /// accumulate takes the user can step through.
    @MainActor
    func testTakeHistoryAccumulatesAndNavigatesLikeAGenerationNode() throws {
        let node = StudioNode(kind: .imageUpscale, label: "Upscale", position: .init(x: 0, y: 0))
        let project = WorkflowProject(name: "Takes", nodes: [node], edges: [])
        let address = PortAddress(nodeID: node.id, portID: "image")
        let first = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(URL(fileURLWithPath: "/tmp/first.png"))], createdAt: Date(timeIntervalSince1970: 1))
        let second = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(URL(fileURLWithPath: "/tmp/second.png"))], createdAt: Date(timeIntervalSince1970: 2))
        let model = StudioModel(persistence: StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id
        model.executionArtifacts = [second, first]
        XCTAssertEqual(model.takes(for: node).map(\.id), [first.id, second.id])
        XCTAssertEqual(model.displayedValue(for: node), second.values[address])
        model.stepTake(for: node, by: -1)
        XCTAssertEqual(model.currentProject?.nodes.first?.selectedTakeID, first.id)
    }
}
