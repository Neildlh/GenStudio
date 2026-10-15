import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

/// Real inference through GenStudio's own NativeUpscaleEngine, explicitly opted in. Uses an already-downloaded
/// pinned checkpoint only; never downloads. This is the proof this codebase's convention requires before
/// UpscaleCapabilityRegistry's readiness can move from .awaitingProof to .verified(evidence:) — see
/// docs/research/upscaling/ENGINEERING_PLAN.md.
///
/// Run (general model):
///   RUN_UPSCALE_INTEGRATION=1 UPSCALE_X4PLUS_MODEL=<path to RealESRGAN_x4plus.pth> [UPSCALE_EVIDENCE_DIR=<dir>] \
///     xcodebuild test -only-testing:GenStudioTests/UpscaleIntegrationTests/testRealX4PlusUpscaleThroughGenStudioAdapter
/// Run (illustration model):
///   RUN_UPSCALE_INTEGRATION=1 UPSCALE_X4PLUS_ANIME_MODEL=<path to RealESRGAN_x4plus_anime_6B.pth> [UPSCALE_EVIDENCE_DIR=<dir>] \
///     xcodebuild test -only-testing:GenStudioTests/UpscaleIntegrationTests/testRealX4PlusAnimeUpscaleThroughGenStudioAdapter
final class UpscaleIntegrationTests: XCTestCase {
    private struct Record: Encodable {
        let date: Date; let engineBuild: String; let recipeID: String; let checkpointSHA256: String
        let fourTimesWallSeconds: Double; let twoTimesWallSeconds: Double
        let fourTimesOutput: MediaIdentity; let twoTimesOutput: MediaIdentity
        let note: String
    }

    private func run(recipeID: String, modelPathEnvVar: String) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_UPSCALE_INTEGRATION"] == "1", let modelPath = environment[modelPathEnvVar] else {
            throw XCTSkip("Opt in with RUN_UPSCALE_INTEGRATION=1 and \(modelPathEnvVar) pointing at the pinned checkpoint.")
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else { throw XCTSkip("Blocker: missing \(modelPath). No download attempted.") }
        let root = FileManager.default.temporaryDirectory.appending(path: "GenStudio-upscale-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: root.appending(path: "ModelLibrary"), diskAvailable: { _ in Int64.max })
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == recipeID })
        _ = try await library.importFiles(recipe: recipe, filesByComponentID: ["checkpoint": URL(fileURLWithPath: modelPath)])

        // Exactly the shipped descriptor, admitted as verified for this proof run only — mirrors
        // SD15ImageIntegrationTests' "candidate registry" convention.
        guard let shipped = UpscaleCapabilityRegistry.capability(recipeID: recipeID) else { return XCTFail("No shipped capability for \(recipeID)") }
        let registry = [shipped.with(readiness: .verified(evidence: "integration candidate"))]
        let engine = NativeUpscaleEngine(library: library, outputRoot: root.appending(path: "Scratch"), capabilities: registry)

        // 64×64 source, matching the brief's own direct sd-cli evidence for this exact recipe.
        let source = try makeSource(in: root)
        let sourceIdentity = try MediaIdentity.of(source)

        let fourStart = Date()
        let fourRequest = UpscaleRequest(recipeID: recipeID, engineBuild: shipped.engineBuild, scale: 4, tileSize: 128, sourceImage: source, sourceIdentity: sourceIdentity)
        let fourOutput = try await engine.upscale(fourRequest)
        let fourSeconds = Date().timeIntervalSince(fourStart)
        let fourImage = try XCTUnwrap(CGImageSourceCreateWithURL(fourOutput as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(fourImage.width, 256); XCTAssertEqual(fourImage.height, 256, "4× of a 64×64 source must decode to exactly 256×256")

        let twoStart = Date()
        let twoRequest = UpscaleRequest(recipeID: recipeID, engineBuild: shipped.engineBuild, scale: 2, tileSize: 128, sourceImage: source, sourceIdentity: sourceIdentity)
        let twoOutput = try await engine.upscale(twoRequest)
        let twoSeconds = Date().timeIntervalSince(twoStart)
        let twoImage = try XCTUnwrap(CGImageSourceCreateWithURL(twoOutput as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(twoImage.width, 128); XCTAssertEqual(twoImage.height, 128, "2× of a 64×64 source must decode to exactly 128×128 (via the validated 4× intermediate, then downsampled)")

        let reopened = try await ModelLibrary(root: root.appending(path: "ModelLibrary")).installedModels()
        XCTAssertEqual(reopened.first?.verifiedUpscale, true, "A decoded, dimension-verified render marks this exact recipe verified")

        if let evidence = environment["UPSCALE_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: evidence).appending(path: recipeID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: directory.appending(path: "4x.png")); try FileManager.default.copyItem(at: fourOutput, to: directory.appending(path: "4x.png"))
            try? FileManager.default.removeItem(at: directory.appending(path: "2x.png")); try FileManager.default.copyItem(at: twoOutput, to: directory.appending(path: "2x.png"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let record = Record(date: Date(), engineBuild: shipped.engineBuild, recipeID: recipeID, checkpointSHA256: recipe.components[0].sha256,
                fourTimesWallSeconds: fourSeconds, twoTimesWallSeconds: twoSeconds,
                fourTimesOutput: try MediaIdentity.of(fourOutput), twoTimesOutput: try MediaIdentity.of(twoOutput),
                note: "Wall seconds include model load, upscale and (for 2×) the bounded downsample, through NativeUpscaleEngine directly. Once reviewed, this JSON is the evidence to cite when moving UpscaleCapabilityRegistry's readiness for \(recipeID) to .verified(evidence:).")
            try encoder.encode(record).write(to: directory.appending(path: "upscale-integration.json"), options: .atomic)
        }
    }

    private func makeSource(in directory: URL) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
        let url = directory.appending(path: "source-64.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testRealX4PlusUpscaleThroughGenStudioAdapter() async throws {
        try await run(recipeID: UpscaleCapabilityRegistry.realesrganX4PlusRecipeID, modelPathEnvVar: "UPSCALE_X4PLUS_MODEL")
    }

    func testRealX4PlusAnimeUpscaleThroughGenStudioAdapter() async throws {
        try await run(recipeID: UpscaleCapabilityRegistry.realesrganX4PlusAnimeRecipeID, modelPathEnvVar: "UPSCALE_X4PLUS_ANIME_MODEL")
    }
}
