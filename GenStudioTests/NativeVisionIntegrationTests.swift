import XCTest
import ImageIO
@testable import GenStudio

final class NativeVisionIntegrationTests: XCTestCase {
    func testPreparedImagesPreserveFullFrameAndBoundSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
        let input = root.appendingPathComponent("wide.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = try NativeVisionEngine.prepare([input], in: root)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(prepared[0] as CFURL, nil))
        let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(result.width, 1024); XCTAssertEqual(result.height, 512)
        XCTAssertThrowsError(try NativeVisionEngine.prepare([URL(string: "https://example.com/image.png")!], in: root))
    }

    /// Explicit opt-in. Uses already-downloaded isolated proof weights; never downloads or touches the user library.
    func testRealVisionPixelsAfterLibraryRestart() async throws {
        guard let path = ProcessInfo.processInfo.environment["GENSTUDIO_VISION_PROOF_ROOT"] else { throw XCTSkip("Set GENSTUDIO_VISION_PROOF_ROOT to the isolated vision proof directory.") }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let recipe = VisionModelCatalog.recipes[0]
        let library = ModelLibrary(root: root.appendingPathComponent("library"))
        let installed = try await library.resolveInstalledModel(id: recipe.id)
        XCTAssertEqual(installed.kind, .vision)
        let engine = NativeVisionEngine(library: library)
        var answers: [String] = []
        for name in ["red-square", "blue-circle"] {
            let answer = try await engine.describe(images: [root.appendingPathComponent(name + ".png")], prompt: "What color and shape is the large object? Answer briefly.", model: recipe.id, temperature: 0, maxTokens: 64, timeout: .seconds(120))
            XCTAssertFalse(answer.isEmpty); answers.append(answer.lowercased())
        }
        XCTAssertTrue(answers[0].contains("red")); XCTAssertTrue(answers[1].contains("blue"))
        XCTAssertNotEqual(answers[0], answers[1])
    }
}
