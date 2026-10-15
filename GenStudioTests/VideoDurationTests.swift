import XCTest
@testable import GenStudio

final class VideoDurationTests: XCTestCase {
    func testSecondsToFramesAndNearestFourNPlusOneSnapping() throws {
        let rule = FrameCountRule(minimum: 5, maximum: 97, stride: 4, offset: 1)
        let resolved = try VideoDurationResolver.resolve(requestedSeconds: 3.0, fps: 24, rule: rule)
        XCTAssertEqual(resolved.requestedSeconds, 3.0)
        XCTAssertEqual(resolved.frameCount, 73)
        XCTAssertEqual(resolved.generatedSeconds, 73.0 / 24.0)
        XCTAssertEqual(resolved.control.stepSeconds, 1.0 / 24.0)
        XCTAssertTrue(rule.contains(resolved.frameCount))
    }

    func testSixteenNPlusOneAndFixedRules() throws {
        let strided = FrameCountRule(minimum: 1, maximum: 97, stride: 16, offset: 1)
        let snapped = try VideoDurationResolver.resolve(requestedSeconds: 2.0, fps: 24, rule: strided)
        XCTAssertEqual(snapped.frameCount, 49)
        XCTAssertEqual(snapped.generatedSeconds, 49.0 / 24.0)

        let fixed = FrameCountRule(minimum: 49, maximum: 49, stride: 1, offset: 0)
        let fixedResult = try VideoDurationResolver.resolve(requestedSeconds: 8.0, fps: 24, rule: fixed)
        XCTAssertEqual(fixedResult.frameCount, 49)
        XCTAssertEqual(fixedResult.requestedSeconds, 49.0 / 24.0, accuracy: 0.000_001)
        XCTAssertEqual(fixedResult.control.minimumSeconds, fixedResult.control.maximumSeconds)
    }

    func testDurationClampsToRuleMinimumAndMaximum() throws {
        let rule = FrameCountRule(minimum: 5, maximum: 33, stride: 4, offset: 1)
        let below = try VideoDurationResolver.resolve(requestedSeconds: 0.01, fps: 8, rule: rule)
        XCTAssertEqual(below.requestedSeconds, 5.0 / 8.0)
        XCTAssertEqual(below.frameCount, 5)

        let above = try VideoDurationResolver.resolve(requestedSeconds: 30, fps: 8, rule: rule)
        XCTAssertEqual(above.requestedSeconds, 33.0 / 8.0)
        XCTAssertEqual(above.frameCount, 33)
    }

    func testFPSChangePreservesRequestedSecondsAndRecalculatesFrames() throws {
        let rule = FrameCountRule(minimum: 5, maximum: 97, stride: 4, offset: 1)
        var settings = VideoGenerationSettings(fps: 24, requestedDurationSeconds: 3.0)
        _ = try VideoDurationResolver.apply(to: &settings, rule: rule)
        XCTAssertEqual(settings.frameCount, 73)

        settings.fps = 12
        let changed = try VideoDurationResolver.apply(to: &settings, rule: rule)
        XCTAssertEqual(settings.requestedDurationSeconds, 3.0)
        XCTAssertEqual(changed.frameCount, 37)
        XCTAssertEqual(changed.generatedSeconds, 37.0 / 12.0)
    }

    func testRecipeChangePreservesDurationButUsesNewTemporalRule() throws {
        var existing = VideoCapabilityRegistry.wanTextToVideo.recommended
        existing.requestedDurationSeconds = 6.0
        let changed = VideoCapabilityRegistry.lingBotTextToVideo.recommendedSettings(preservingDurationFrom: existing)
        XCTAssertEqual(changed.requestedDurationSeconds, 6.0)
        XCTAssertEqual(changed.fps, VideoCapabilityRegistry.lingBotTextToVideo.recommended.fps)
        XCTAssertTrue(VideoCapabilityRegistry.lingBotTextToVideo.frames.contains(changed.frameCount))
        XCTAssertEqual(changed.frameCount, 49)
    }

    func testOlderSettingsDecodeRequestedDurationFromFramesAndFPS() throws {
        let json = """
        {"negativePrompt":"old","width":448,"height":256,"frameCount":33,"fps":8,"steps":10,"cfgScale":3,"flowShift":3,"seed":42}
        """
        let decoded = try JSONDecoder().decode(VideoGenerationSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.requestedDurationSeconds, 4.125)
        XCTAssertEqual(decoded.frameCount, 33)
        XCTAssertEqual(decoded.fps, 8)

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["requestedDurationSeconds"] as? Double, 4.125)
    }

    func testExistingWorkflowWithoutRequestedDurationDecodesWithoutResettingFrames() throws {
        var video = StudioNode(kind: .textToVideo, label: "Legacy video", position: .init(x: 0, y: 0), model: VideoCapabilityRegistry.wanT2VRecipeID)
        video.video = VideoGenerationSettings(frameCount: 29, fps: 12)
        let original = WorkflowProject(name: "Legacy", nodes: [video], edges: [])
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        var settings = try XCTUnwrap(nodes[0]["videoSettings"] as? [String: Any])
        settings.removeValue(forKey: "requestedDurationSeconds")
        nodes[0]["videoSettings"] = settings
        object["nodes"] = nodes

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let reopened = try JSONDecoder().decode(WorkflowProject.self, from: legacyData)
        let reopenedVideo = try XCTUnwrap(reopened.nodes.first?.videoSettings)
        XCTAssertEqual(reopenedVideo.frameCount, 29)
        XCTAssertEqual(reopenedVideo.fps, 12)
        XCTAssertEqual(reopenedVideo.requestedDurationSeconds, 29.0 / 12.0)
    }

    func testInspectorDurationLabelsShowRequestedAndGeneratedValues() throws {
        let rule = FrameCountRule(minimum: 1, maximum: 97, stride: 16, offset: 1)
        let resolved = try VideoDurationResolver.resolve(requestedSeconds: 2.0, fps: 24, rule: rule)
        XCTAssertEqual(VideoDurationPresentation.requestedLabel(resolved), "Duration: 2.0 seconds")
        XCTAssertEqual(VideoDurationPresentation.resultLabel(resolved), "2.0 s requested · 49 expensive generated frames at 24 fps · 2.04 s")
        XCTAssertEqual(VideoDurationPresentation.snappingExplanation(resolved, rule: rule), "This model generates clips in 16-frame intervals. The closest supported duration is 2.04 seconds.")
    }

    func testLingBotNewNodeDefaultsAreEconomicalPortraitGenerationSettings() {
        for capability in [VideoCapabilityRegistry.lingBotTextToVideo, VideoCapabilityRegistry.lingBotImageToVideo] {
            XCTAssertEqual(capability.recommended.width, 256)
            XCTAssertEqual(capability.recommended.height, 448)
            XCTAssertEqual(capability.recommended.frameCount, 33)
            XCTAssertEqual(capability.recommended.fps, 8)
            XCTAssertEqual(capability.recommended.steps, 10)
        }
    }

    func testFinishingNodesDefaultToThirtyFPSAndSurvivePersistence() throws {
        let interpolation = StudioNode(kind: .frameInterpolate, label: "Smooth", position: .init(x: 0, y: 0))
        let export = StudioNode(kind: .instagramExport, label: "Reel", position: .init(x: 1, y: 0))
        XCTAssertEqual(interpolation.deliveryFPS, 30)
        XCTAssertEqual(interpolation.inputPorts.map(\.type), [.video])
        XCTAssertEqual(export.outputPorts.map(\.type), [.video])
        let decoded = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(interpolation))
        XCTAssertEqual(decoded.deliveryFPS, 30)
    }

    func testValidatedRuntimeCommandUsesResolvedFrameCountNotCachedFrames() throws {
        var settings = VideoGenerationSettings(frameCount: 10, fps: 24, requestedDurationSeconds: 1.0)
        settings.seed = 77
        let capability = VideoCapabilityRegistry.wanTextToVideo
        let request = try VideoRequestPlanner.makeRequest(settings: settings, task: .textToVideo, capability: capability, prompt: "a pinwheel", negativePrompt: nil)
        XCTAssertEqual(request.frameCount, 25)
        XCTAssertTrue(capability.frames.contains(request.frameCount))
        XCTAssertEqual(request.requestedDurationSeconds, 1.0)

        let components = WanTextToVideoCommand.Components(
            diffusion: URL(fileURLWithPath: "/m/d.gguf"),
            textEncoder: URL(fileURLWithPath: "/m/t.gguf"),
            vae: URL(fileURLWithPath: "/m/v.safetensors")
        )
        let arguments = try WanTextToVideoCommand.arguments(request, components: components, framePattern: URL(fileURLWithPath: "/w/frame_%03d.png"))
        let framesFlag = try XCTUnwrap(arguments.firstIndex(of: "--video-frames"))
        XCTAssertEqual(arguments[framesFlag + 1], "25")
    }

    func testDurationResolutionDoesNotAlterAspectRatioDimensions() throws {
        let capability = VideoCapabilityRegistry.wan22ImageToVideo
        var settings = capability.recommended
        settings.width = 448
        settings.height = 256
        settings.requestedDurationSeconds = 2.0
        _ = try VideoDurationResolver.apply(to: &settings, rule: capability.frames)
        XCTAssertEqual(settings.width, 448)
        XCTAssertEqual(settings.height, 256)
    }
}
