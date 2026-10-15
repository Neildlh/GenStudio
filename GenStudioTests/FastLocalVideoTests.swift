import XCTest
@testable import GenStudio

/// Contracts behind fast local video production: FastMetal drafts that reuse their prompt
/// encoding across takes, the opt-in interpolated fast draft, and LTX's float16 compute.
final class FastLocalVideoTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/genstudio-fast-video-tests", isDirectory: true)

    private func fastMetalRequest(prompt: String = "a greenhouse at dawn", seed: Int, fastDraft: Bool? = nil) throws -> VideoGenerationRequest {
        var settings = VideoCapabilityRegistry.fastMetal5TextToVideo.recommended
        settings.seed = seed
        settings.fastDraft = fastDraft
        return try VideoRequestPlanner.makeRequest(settings: settings, task: .textToVideo, capability: VideoCapabilityRegistry.fastMetal5TextToVideo, prompt: prompt, negativePrompt: nil)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    private func fastMetalArguments(_ request: VideoGenerationRequest) -> [String] {
        MLXFastVideoEngine.arguments(request, modelRoot: root.appending(path: "model"), output: root.appending(path: "out.mp4"),
                                     metrics: root.appending(path: "metrics.json"), cacheRoot: root.appending(path: "cache"))
    }

    func testFastMetalReusesThePromptEncodingAcrossSeeds() throws {
        // The UMT5 prompt embedding does not depend on the seed; keying the cache by seed made every
        // fresh-seed take pay ~37 s of CPU text encoding again on this Mac.
        let first = fastMetalArguments(try fastMetalRequest(seed: 1))
        let second = fastMetalArguments(try fastMetalRequest(seed: 2))
        XCTAssertEqual(value(after: "--prompt-embeds-cache", in: first), value(after: "--prompt-embeds-cache", in: second))
        XCTAssertNotEqual(value(after: "--seed", in: first), value(after: "--seed", in: second))
    }

    func testFastMetalPromptCacheSeparatesDifferentPrompts() throws {
        let greenhouse = fastMetalArguments(try fastMetalRequest(prompt: "a greenhouse at dawn", seed: 1))
        let harbour = fastMetalArguments(try fastMetalRequest(prompt: "a harbour at dusk", seed: 1))
        XCTAssertNotEqual(value(after: "--prompt-embeds-cache", in: greenhouse), value(after: "--prompt-embeds-cache", in: harbour))
    }

    func testFastDraftRequestsInterpolatedGenerationOnlyWhenChosen() throws {
        let fast = try fastMetalRequest(seed: 7, fastDraft: true)
        XCTAssertEqual(fast.fastDraft, true)
        XCTAssertTrue(fastMetalArguments(fast).contains("--fast"))

        let normal = try fastMetalRequest(seed: 7)
        XCTAssertNil(normal.fastDraft)
        XCTAssertFalse(fastMetalArguments(normal).contains("--fast"))
    }

    func testFastDraftIsNotRecordedForRoutesWithoutIt() throws {
        var settings = VideoCapabilityRegistry.ltx23TextToVideo.recommended
        settings.fastDraft = true
        let request = try VideoRequestPlanner.makeRequest(settings: settings, task: .textToVideo, capability: VideoCapabilityRegistry.ltx23TextToVideo, prompt: "a harbour", negativePrompt: nil)
        XCTAssertNil(request.fastDraft, "A route without an interpolated draft mode must not record one in provenance")
        XCTAssertFalse(VideoCapabilityRegistry.ltx23TextToVideo.supportsFastDraft)
        XCTAssertTrue(VideoCapabilityRegistry.fastMetal5TextToVideo.supportsFastDraft)
        XCTAssertTrue(VideoCapabilityRegistry.fastMetal5TextToVideo.with(readiness: .awaitingProof).supportsFastDraft,
                      "Recording proof must not silently drop the route's fast-draft mode")
    }

    func testFastDraftSettingRoundTripsAndOlderDocumentsStayUnchanged() throws {
        var settings = VideoGenerationSettings()
        settings.fastDraft = true
        let decoded = try JSONDecoder().decode(VideoGenerationSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.fastDraft, true)

        let legacy = try JSONDecoder().decode(VideoGenerationSettings.self, from: Data(#"{"width":832,"height":480}"#.utf8))
        XCTAssertNil(legacy.fastDraft)
        let reencoded = try XCTUnwrap(String(data: JSONEncoder().encode(legacy), encoding: .utf8))
        XCTAssertFalse(reencoded.contains("fastDraft"), "An untouched older document must not gain a new key")
    }

    func testFastMetalRecommendsUpstreamLandscapeDraftSize() {
        // Upstream's default is 832 wide × 448 tall; GenStudio's earlier preset had width and height transposed.
        let recommended = VideoCapabilityRegistry.fastMetal5TextToVideo.recommended
        XCTAssertEqual(recommended.width, 832)
        XCTAssertEqual(recommended.height, 480)
        XCTAssertEqual(recommended.frameCount, 121)
        XCTAssertNotNil(VideoCapabilityRegistry.fastMetal5TextToVideo.measuredBaseline, "Measured on this Mac on 12 October 2026")
    }

    func testLTXRunsTheDiTInFloat16() {
        // M1-generation GPUs have no native bfloat16; upstream measured 701 s → 563 s on an M1 Max.
        XCTAssertEqual(MLXLTXVideoEngine.processEnvironment, ["LTX2_COMPUTE_DTYPE": "float16"])
    }

    func testProcessRunnerAddsNamedVariablesWithoutReplacingTheMinimalBase() async throws {
        let result = try await NativeProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], timeout: .seconds(3),
            environment: ["LTX2_COMPUTE_DTYPE": "float16", "PATH": "/tmp/untrusted", "PYTHONNOUSERSITE": "0"])
        XCTAssertEqual(result.status, 0)
        let lines = Set(result.stdout.split(separator: "\n").map(String.init))
        XCTAssertTrue(lines.contains("LTX2_COMPUTE_DTYPE=float16"))
        XCTAssertTrue(lines.contains("PATH=/usr/bin:/bin"), "A caller cannot widen the child's search path")
        XCTAssertTrue(lines.contains("PYTHONNOUSERSITE=1"), "A caller cannot re-enable the user site")
    }
}

/// FastMetal prints none of stable-diffusion.cpp's progress lines and is silent for the whole denoise,
/// so the node showed "Validating FastMetal model files" for minutes. Its own status lines drive the stage.
final class FastMetalProgressTests: XCTestCase {
    func testStagesFollowFastMetalsOwnStatusLines() {
        let parser = FastMetalProgressParser(fastDraft: false, estimate: "about 1½ min")
        XCTAssertEqual(parser.consume("[5B] latent 48x31x30x52\n").map(\.stage), [])
        XCTAssertEqual(parser.consume("[5B] prompt encoded (1, 512, 4096) in 37.3s\n").map(\.stage), ["Denoising 3 steps · this take about 1½ min on this Mac"])
        XCTAssertEqual(parser.consume("[5B] DiT loaded in 0.1s\n").map(\.stage), [])
        XCTAssertEqual(parser.consume("[5B] denoise 3 steps in 77.5s, peak 8.54 GiB\n").map(\.stage), ["Decoding frames"])
        XCTAssertEqual(parser.consume("[5B] decoded via taehv in 1.9s → /tmp/x.mp4\n").map(\.stage), ["Writing video"])
    }

    func testFastDraftNamesTheInterpolationAndSplitLinesStillParse() {
        let parser = FastMetalProgressParser(fastDraft: true, estimate: nil)
        XCTAssertEqual(parser.consume("[5B] prompt enc").map(\.stage), [])
        XCTAssertEqual(parser.consume("oded (1, 512, 4096) in 0.0s\n").map(\.stage), ["Denoising 3 steps (fast draft)"])
        XCTAssertEqual(parser.consume("[5B] denoise 3 steps in 32.7s, peak 6.98 GiB\r\n").map(\.stage), ["Decoding and interpolating frames"])
    }
}

/// LTX-2.3 start/end-frame video through ltx-2-mlx ≥ 0.16 (`--image END last`): the fast alternative to
/// MiniMax-H3 FL2VA, which takes about 25 minutes per clip on the reference Mac.
final class LTXFirstLastFrameTests: XCTestCase {
    private func media(_ role: VideoInputRole, _ path: String) -> VideoMediaInput {
        VideoMediaInput(role: role, identity: MediaIdentity(sha256: String(repeating: "0", count: 64), byteSize: 1), location: URL(fileURLWithPath: path))
    }

    func testLTXOffersStartAndEndFrameVideo() throws {
        let capability = try XCTUnwrap(VideoCapabilityRegistry.capability(recipeID: MLXVideoModelCatalog.ltx23Q4RecipeID, task: .firstLastFrame))
        XCTAssertEqual(capability.engineID, "mlx-ltx")
        XCTAssertEqual(capability.requiredRoles, [.startImage, .endImage, .prompt])
        XCTAssertFalse(capability.speedAnchors.isEmpty, "Timed on this Mac")
        XCTAssertTrue(VideoCapabilityRegistry.selectableCapabilities(for: .firstLastFrame).contains { $0.recipeID == MLXVideoModelCatalog.ltx23Q4RecipeID })
    }

    func testTheEndImageIsPinnedToTheLastFrame() {
        let arguments = MLXLTXVideoEngine.imageArguments(task: .firstLastFrame, mediaInputs: [media(.endImage, "/tmp/end.png"), media(.startImage, "/tmp/start.png")])
        XCTAssertEqual(arguments, ["--image", "/tmp/start.png", "0", "1.0", "--image", "/tmp/end.png", "last", "1.0"])
    }

    func testImageToVideoKeepsItsSingleStartImage() {
        XCTAssertEqual(MLXLTXVideoEngine.imageArguments(task: .imageToVideo, mediaInputs: [media(.startImage, "/tmp/start.png")]), ["--image", "/tmp/start.png"])
        XCTAssertEqual(MLXLTXVideoEngine.imageArguments(task: .textToVideo, mediaInputs: []), [])
    }
}
