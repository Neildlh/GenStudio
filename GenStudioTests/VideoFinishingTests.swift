import XCTest
@testable import GenStudio

final class VideoFinishingTests: XCTestCase {
    func testRifeInterpolationRaisesFrameRateWithoutChangingCanvas() async throws {
        let root = try VideoFixtures.root("rife-interpolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try VideoFixtures.solidPNG((220, 30, 20), width: 64, height: 64, in: root, name: "first")
        let second = try VideoFixtures.solidPNG((20, 30, 220), width: 64, height: 64, in: root, name: "second")
        let source = root.appending(path: "source.mov")
        try await FrameSequenceEncoder.encode(frames: [.file(first), .file(second)], width: 64, height: 64, fps: 8, framesPerImage: nil, to: source)
        let result = try await FrameInterpolationRunner(scratchRoot: root.appending(path: "scratch")).run(sourceVideo: source, targetFPS: 16)
        XCTAssertEqual(result.probe.width, 64)
        XCTAssertEqual(result.probe.height, 64)
        XCTAssertEqual(result.probe.frameCount, 4)
        XCTAssertEqual(result.probe.nominalFPS, 16, accuracy: 0.2)
    }
}
