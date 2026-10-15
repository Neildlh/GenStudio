import XCTest
@testable import GenStudio

/// Picking a model adopts that model's tuned settings automatically, while keeping what the person
/// chose on purpose (clip length, shape, a locked seed, the fast-draft preference), and shows how long
/// a take should take on this Mac.
final class ModelSwitchSettingsTests: XCTestCase {
    private let fastMetal = VideoCapabilityRegistry.fastMetal5TextToVideo
    private let ltx = VideoCapabilityRegistry.ltx23TextToVideo

    func testSwitchingModelKeepsAPortraitShape() {
        var portrait = ltx.recommended
        portrait.width = 448; portrait.height = 768
        let next = fastMetal.recommendedSettings(preservingDurationFrom: portrait)
        XCTAssertLessThan(next.width, next.height, "A 9:16-style clip stays portrait on the new model")
        XCTAssertEqual(Double(next.width) / Double(next.height), 448.0 / 768.0, accuracy: 0.05)
        XCTAssertTrue(fastMetal.width.contains(next.width) && fastMetal.height.contains(next.height))
        let pixels = Double(next.width * next.height), optimal = Double(fastMetal.optimalPixels)
        XCTAssertTrue((0.75 * optimal...1.25 * optimal).contains(pixels), "Sized to the new model's preferred pixel count")
    }

    func testSwitchingModelUsesTheModelsOwnCanvasForASimilarShape() {
        let next = fastMetal.recommendedSettings(preservingDurationFrom: VideoGenerationSettings())
        XCTAssertEqual(next.width, 832)
        XCTAssertEqual(next.height, 480)
        XCTAssertEqual(next.steps, fastMetal.recommended.steps)
        XCTAssertEqual(next.fps, 24)
    }

    func testSwitchingModelKeepsTheSeedAndTheFastDraftChoice() {
        var previous = fastMetal.recommended
        previous.seed = 777; previous.fastDraft = true
        let onLTX = ltx.recommendedSettings(preservingDurationFrom: previous)
        XCTAssertEqual(onLTX.seed, 777, "Comparing models on the same seed needs the seed to survive a switch")
        XCTAssertNil(onLTX.fastDraft, "LTX has no fast draft, so none is carried")
        let back = fastMetal.recommendedSettings(preservingDurationFrom: previous)
        XCTAssertEqual(back.fastDraft, true)
    }

    func testEstimateReproducesTheMeasuredRunsOnThisMac() throws {
        func seconds(_ width: Int, _ height: Int, fast: Bool = false) throws -> Double {
            var settings = fastMetal.recommended
            settings.width = width; settings.height = height; settings.fastDraft = fast ? true : nil
            return try XCTUnwrap(VideoTimeEstimate.seconds(settings, capability: fastMetal))
        }
        XCTAssertEqual(try seconds(832, 480), 88, accuracy: 1)
        XCTAssertEqual(try seconds(832, 480, fast: true), 46, accuracy: 1)
        XCTAssertEqual(try seconds(1280, 704), 281, accuracy: 1)
        XCTAssertEqual(try seconds(1280, 704, fast: true), 134, accuracy: 1)
        let ltxSeconds = try XCTUnwrap(VideoTimeEstimate.seconds(ltx.recommended, capability: ltx))
        XCTAssertEqual(ltxSeconds, 173, accuracy: 1)
    }

    func testEstimateGrowsWithSizeAndLength() throws {
        var mid = fastMetal.recommended
        mid.width = 1024; mid.height = 576
        let midSeconds = try XCTUnwrap(VideoTimeEstimate.seconds(mid, capability: fastMetal))
        XCTAssertTrue((88...281).contains(midSeconds))

        var short = fastMetal.recommended
        short.frameCount = 61
        let shortSeconds = try XCTUnwrap(VideoTimeEstimate.seconds(short, capability: fastMetal))
        XCTAssertLessThan(shortSeconds, 88)
    }

    func testNoEstimateWithoutMeasurementsOnThisMac() {
        let unmeasured = VideoCapabilityRegistry.wan22TextToVideo
        XCTAssertNil(VideoTimeEstimate.seconds(unmeasured.recommended, capability: unmeasured))
    }

    func testEstimateReadsNaturally() {
        XCTAssertEqual(VideoTimeEstimate.label(46), "about 45 s")
        XCTAssertEqual(VideoTimeEstimate.label(88), "about 1½ min")
        XCTAssertEqual(VideoTimeEstimate.label(173), "about 3 min")
        XCTAssertEqual(VideoTimeEstimate.label(281), "about 4½ min")
        XCTAssertEqual(VideoTimeEstimate.label(8 * 173), "about 23 min")
        XCTAssertEqual(VideoTimeEstimate.label(24 * 173), "about 1 h 10 min")
    }
}

final class VideoTimeEstimateRangeTests: XCTestCase {
    func testNoEstimateFarOutsideTheMeasuredRange() {
        let h3 = VideoCapabilityRegistry.minimaxH3FirstLastFrame
        var measured = h3.recommended
        measured.width = 320; measured.height = 576; measured.frameCount = 39
        let seconds = VideoTimeEstimate.seconds(measured, capability: h3)
        XCTAssertEqual(seconds ?? 0, 1506, accuracy: 1, "MiniMax-H3 start/end is timed from this Mac's own runs")

        var tiny = measured
        tiny.width = 320; tiny.height = 192; tiny.frameCount = 9
        XCTAssertNil(VideoTimeEstimate.seconds(tiny, capability: h3), "Far below any measured size the fixed load time dominates; no guess")
    }

    func testMiniMaxImageToVideoUsesItsTwoMeasuredSizes() throws {
        let h3 = VideoCapabilityRegistry.minimaxH3ImageToVideo
        var small = h3.recommended
        small.width = 320; small.height = 544; small.frameCount = 56
        XCTAssertEqual(try XCTUnwrap(VideoTimeEstimate.seconds(small, capability: h3)), 1081, accuracy: 1)
    }
}
