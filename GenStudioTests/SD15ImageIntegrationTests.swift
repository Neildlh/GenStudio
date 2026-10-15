import CoreGraphics
import ImageIO
import XCTest
@testable import GenStudio

/// Real inference, explicitly opted in. Uses the existing local SD 1.5 Q4_0 file only; never downloads.
/// Run: TEST_RUNNER_RUN_SD15_IMAGE_INTEGRATION=1 TEST_RUNNER_SD15_MODEL=<gguf> TEST_RUNNER_SD15_EVIDENCE_DIR=<dir> xcodebuild test -only-testing:GenStudioTests/SD15ImageIntegrationTests
final class SD15ImageIntegrationTests: XCTestCase {
    private struct Stats: Encodable { let meanAbsoluteDifference: Double; let outputStandardDeviation: Double }

    private func pixels(_ url: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var data = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        return data
    }

    func testRealSD15TextToImageAndImageToImageThroughGenStudioAdapter() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_SD15_IMAGE_INTEGRATION"] == "1", let modelPath = environment["SD15_MODEL"] else {
            throw XCTSkip("Opt in with RUN_SD15_IMAGE_INTEGRATION=1 and SD15_MODEL pointing at the pinned SD 1.5 Q4_0 file.")
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else { throw XCTSkip("Blocker: missing \(modelPath). No download attempted.") }
        let root = try VideoFixtures.root("sd15-integration"); defer { try? FileManager.default.removeItem(at: root) }
        let library = ModelLibrary(root: root.appending(path: "ModelLibrary"), diskAvailable: { _ in Int64.max })
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == ImageCapabilityRegistry.sd15RecipeID })
        _ = try await library.importFiles(recipe: recipe, filesByComponentID: ["checkpoint": URL(fileURLWithPath: modelPath)])

        // Candidate registry: exactly the shipped descriptors, with image-to-image admitted for this proof run only.
        let registry = [ImageCapabilityRegistry.sd15TextToImage, ImageCapabilityRegistry.sd15ImageToImage.with(readiness: .verified(evidence: "integration candidate"))]
        let store = StudioPersistence(root: root)
        let engine = NativeImageEngine(library: library, outputRoot: root.appending(path: "GenerationScratch"), capabilities: registry)
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, imageEngine: engine, imageCapabilities: registry)

        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "a red apple on a dark wooden table, studio photograph, detailed")
        let t2i = StudioNode(kind: .imageGenerator, label: "Text to image", position: .init(x: 1, y: 0), model: recipe.id, width: 512, height: 512, imageSeed: 424242)
        let t2iStart = Date()
        let first = try await queue.execute(project: .init(name: "SD T2I", nodes: [prompt, t2i], edges: [VideoFixtures.edge(prompt, "text", t2i, "prompt", .text)]), targetID: t2i.id)
        let t2iSeconds = Date().timeIntervalSince(t2iStart)
        guard case .image(let base)? = first.values[.init(nodeID: t2i.id, portID: "image")] else { return XCTFail("Missing text-to-image output") }

        let editPrompt = StudioNode(kind: .prompt, label: "Edit prompt", position: .init(x: 0, y: 1), prompt: "a green apple on a dark wooden table, studio photograph, detailed")
        let reference = StudioNode(kind: .imageInput, label: "Start image", position: .init(x: 0, y: 2), imagePath: base.path)
        var i2i = StudioNode(kind: .imageGenerator, label: "Image to image", position: .init(x: 1, y: 1), model: recipe.id, width: 512, height: 512, imageSeed: 7)
        i2i.imageStrength = 0.55
        let i2iStart = Date()
        let second = try await queue.execute(project: .init(name: "SD I2I", nodes: [editPrompt, reference, i2i], edges: [VideoFixtures.edge(editPrompt, "text", i2i, "prompt", .text), VideoFixtures.edge(reference, "image", i2i, "referenceImage", .image)]), targetID: i2i.id)
        let i2iSeconds = Date().timeIntervalSince(i2iStart)
        guard case .image(let edited)? = second.values[.init(nodeID: i2i.id, portID: "image")] else { return XCTFail("Missing image-to-image output") }

        let runs = try await store.loadRuns()
        let editRun = try XCTUnwrap(runs.first { $0.snapshot.nodeID == i2i.id })
        XCTAssertEqual(editRun.status, .succeeded)
        XCTAssertEqual(editRun.snapshot.imageRequest?.task, .imageToImage); XCTAssertEqual(editRun.snapshot.imageRequest?.strength, 0.55)
        for url in [base, edited] {
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            XCTAssertEqual(image.width, 512); XCTAssertEqual(image.height, 512)
        }
        let a = try pixels(base), b = try pixels(edited)
        let diff = zip(a, b).enumerated().filter { $0.offset % 4 != 3 }.reduce(0.0) { $0 + abs(Double($1.element.0) - Double($1.element.1)) } / Double(64 * 64 * 3)
        let channel = b.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
        let mean = channel.reduce(0, +) / Double(channel.count)
        let deviation = (channel.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(channel.count)).squareRoot()
        XCTAssertGreaterThan(diff, 1.0, "The edit must change the starting picture")
        XCTAssertGreaterThan(deviation, 5.0, "The edit must not be a flat image")
        let reopened = try await ModelLibrary(root: root.appending(path: "ModelLibrary")).installedModels()
        XCTAssertTrue(reopened.first?.inferenceVerified == true)

        if let evidence = environment["SD15_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: evidence)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: directory.appending(path: "sd15-t2i-512.png")); try FileManager.default.copyItem(at: base, to: directory.appending(path: "sd15-t2i-512.png"))
            try? FileManager.default.removeItem(at: directory.appending(path: "sd15-i2i-512-strength055.png")); try FileManager.default.copyItem(at: edited, to: directory.appending(path: "sd15-i2i-512-strength055.png"))
            struct Record: Encodable {
                let date: Date; let engineBuild: String; let recipeID: String; let checkpointSHA256: String
                let textToImageWallSeconds: Double; let imageToImageWallSeconds: Double
                let textToImageOutput: MediaIdentity; let imageToImageOutput: MediaIdentity
                let imageToImageRequest: ImageGenerationRequest?; let textToImageRequest: ImageGenerationRequest?
                let stats: Stats; let note: String
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let record = Record(date: Date(), engineBuild: VideoCapabilityRegistry.sdCppBuild, recipeID: recipe.id, checkpointSHA256: recipe.components[0].sha256,
                                textToImageWallSeconds: t2iSeconds, imageToImageWallSeconds: i2iSeconds,
                                textToImageOutput: try MediaIdentity.of(base), imageToImageOutput: try MediaIdentity.of(edited),
                                imageToImageRequest: editRun.snapshot.imageRequest, textToImageRequest: runs.first { $0.snapshot.nodeID == t2i.id }?.snapshot.imageRequest,
                                stats: .init(meanAbsoluteDifference: diff, outputStandardDeviation: deviation),
                                note: "Wall seconds include component SHA-256 validation, model load, sampling, decode and artifact retention through ExecutionQueue. Paths in requests point at a deleted temporary library.")
            try encoder.encode(record).write(to: directory.appending(path: "sd15-image-integration.json"), options: .atomic)
        }
    }
}
