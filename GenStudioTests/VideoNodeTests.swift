import AVFoundation
import CoreGraphics
import XCTest
@testable import GenStudio

final class VideoNodeContractTests: XCTestCase {
    private func node(_ kind: NodeKind, model: String = "") -> StudioNode { StudioNode(kind: kind, label: kind.title, position: .init(x: 0, y: 0), model: model) }

    func testAspectRatioPresetsFitRecipeQuantisation() {
        let width = IntegerBounds(minimum: 256, maximum: 1024, multiple: 64)
        let height = IntegerBounds(minimum: 256, maximum: 1024, multiple: 64)
        let size = AspectRatioPreset.widescreen.dimensions(width: width, height: height)
        XCTAssertNotNil(size)
        XCTAssertEqual(size?.0, 1024)
        XCTAssertEqual(size?.1, 576)
        XCTAssertTrue(width.contains(size!.0) && height.contains(size!.1))
    }

    func testAspectRatioPresetsUseMaximumSupportedCanvasForImageRecipes() {
        let klein = IntegerBounds(minimum: 512, maximum: 1024, multiple: 16)
        XCTAssertEqual(AspectRatioPreset.widescreen.dimensions(width: klein, height: klein, preferLargestCanvas: true)?.0, 1024)
        XCTAssertEqual(AspectRatioPreset.widescreen.dimensions(width: klein, height: klein, preferLargestCanvas: true)?.1, 576)
        XCTAssertEqual(AspectRatioPreset.vertical.dimensions(width: klein, height: klein, preferLargestCanvas: true)?.0, 576)
        XCTAssertEqual(AspectRatioPreset.vertical.dimensions(width: klein, height: klein, preferLargestCanvas: true)?.1, 1024)

        let sd15 = IntegerBounds(minimum: 256, maximum: 768, multiple: 64)
        XCTAssertEqual(AspectRatioPreset.widescreen.dimensions(width: sd15, height: sd15, preferLargestCanvas: true)?.0, 768)
        XCTAssertEqual(AspectRatioPreset.widescreen.dimensions(width: sd15, height: sd15, preferLargestCanvas: true)?.1, 448)
        XCTAssertEqual(AspectRatioPreset.vertical.dimensions(width: sd15, height: sd15, preferLargestCanvas: true)?.0, 448)
        XCTAssertEqual(AspectRatioPreset.vertical.dimensions(width: sd15, height: sd15, preferLargestCanvas: true)?.1, 768)
    }

    /// A four-corner heuristic can miss a quantized ratio's true best fit entirely: the ideal
    /// companion value for each corner rounds to a different multiple than the one that actually
    /// lands closest to the target. A full bounded-multiple search must still resolve 16:9 to
    /// 448×256 in these bounds (the closest 64-multiple pair to 16:9 available here).
    func testFittedDimensionsRobustSearchCoversQuantizedSixteenByNine() {
        let width = IntegerBounds(minimum: 256, maximum: 512, multiple: 64)
        let height = IntegerBounds(minimum: 256, maximum: 512, multiple: 64)
        let size = fittedDimensions(ratio: 16.0 / 9.0, width: width, height: height)
        XCTAssertEqual(size?.0, 448); XCTAssertEqual(size?.1, 256)
    }

    func testSourceAspectFitKeepsTheRequestedPreviewScaleInsteadOfJumpingToMaximumResolution() {
        let bounds = IntegerBounds(minimum: 256, maximum: 832, multiple: 16)
        let size = fittedDimensions(ratio: 16.0 / 9.0, width: bounds, height: bounds, preferredLongestEdge: 512)
        XCTAssertEqual(size?.0, 512)
        XCTAssertEqual(size?.1, 288)
    }

    /// The search must prefer the closer aspect-ratio match over a larger area. For 9:16 in
    /// 256–512 (multiple 64) bounds, (256, 512) is a bigger canvas but only an 11% ratio match;
    /// (256, 448) is a worse-looking area but a 1.6% match. Optimizing area first (the old
    /// behavior) would silently pick the visibly-wrong-aspect (256, 512).
    func testFittedDimensionsPrioritizesAspectErrorOverArea() {
        let bounds = IntegerBounds(minimum: 256, maximum: 512, multiple: 64)
        let size = fittedDimensions(ratio: 9.0 / 16.0, width: bounds, height: bounds)
        XCTAssertEqual(size?.0, 256); XCTAssertEqual(size?.1, 448)
        let achieved = Double(size!.0) / Double(size!.1)
        XCTAssertLessThan(abs(achieved - 9.0 / 16.0) / (9.0 / 16.0), 0.02, "The chosen pair must be a close ratio match, not just the largest area within a loose tolerance")
    }

    /// Nil stays reserved for genuinely impossible bounds — a ratio that cannot come within 8%
    /// of any combination the bounds and quantisation allow.
    func testFittedDimensionsReturnsNilOnlyWhenNoCombinationIsWithinTolerance() {
        let square = IntegerBounds(minimum: 256, maximum: 256, multiple: 1)
        XCTAssertNil(fittedDimensions(ratio: 21.0 / 9.0, width: square, height: square), "A fixed square canvas cannot approximate a 21:9 ratio")
        XCTAssertNotNil(fittedDimensions(ratio: 1.0, width: square, height: square))
    }

    /// The Aspect Ratio picker must reflect the node's actual current canvas instead of always
    /// showing 1:1 — it derives its displayed selection from the passed-in dimensions.
    func testAspectRatioSelectionIsDerivedFromCurrentDimensionsNotAlwaysSquare() {
        XCTAssertEqual(AspectRatioSelection.matching(width: 1024, height: 576), .preset(.widescreen))
        XCTAssertEqual(AspectRatioSelection.matching(width: 512, height: 512), .preset(.square))
        XCTAssertEqual(AspectRatioSelection.matching(width: 480, height: 832), .preset(.vertical), "480×832 is Wan's near-9:16 canvas")
    }

    /// Quantised canvases close to a named ratio should retain that preset, while a genuinely
    /// different source ratio must display Custom instead of misreporting the nearest preset.
    func testAspectRatioSelectionIsCustomWhenNoPresetIsCloseEnough() {
        XCTAssertEqual(AspectRatioSelection.matching(width: 448, height: 256), .preset(.widescreen), "A quantised 16:9 canvas should still display 16:9")
        XCTAssertEqual(AspectRatioSelection.matching(width: 500, height: 400), .custom, "5:4 is not close enough to a supported preset")
        XCTAssertEqual(AspectRatioSelection.matching(width: 0, height: 100), .custom)
        XCTAssertEqual(AspectRatioSelection.matching(width: 100, height: 0), .custom)
    }

    /// Connecting a portrait Image Input as a Start Image must adopt its aspect ratio instead of
    /// leaving the node at the recipe's landscape default, where execution would center-crop the
    /// source into the wrong framing (VideoExecution.imageToVideo's aspectFill).
    @MainActor
    func testConnectingStartImageAdoptsItsAspectRatioInsteadOfTheRecipeDefault() throws {
        let root = try VideoFixtures.root("dimension-sync-connect"); defer { try? FileManager.default.removeItem(at: root) }
        let capability = VideoCapabilityRegistry.animateDiffImageToVideo
        XCTAssertEqual(capability.recommended.width, 512); XCTAssertEqual(capability.recommended.height, 512, "Recipe default starts square")
        let portrait = try VideoFixtures.solidPNG((10, 200, 10), width: 90, height: 160, in: root, name: "portrait")
        let expected = try XCTUnwrap(fittedDimensions(ratio: 90.0 / 160.0, width: capability.width, height: capability.height))
        let source = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: portrait.path)
        var i2v = StudioNode(kind: .imageToVideo, label: "I2V", position: .init(x: 1, y: 0), model: capability.recipeID)
        i2v.video = capability.recommended
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [WorkflowProject(name: "Sync", nodes: [source, i2v], edges: [])]; model.currentProjectID = model.projects[0].id
        model.connect(sourceID: source.id, sourcePortID: "image", targetID: i2v.id, targetPortID: "startImage")
        let synced = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == i2v.id })
        XCTAssertEqual(synced.video.width, expected.0, "The node's canvas now matches the connected source, not the recipe default")
        XCTAssertEqual(synced.video.height, expected.1)
    }

    /// Switching to a recipe whose bounds no longer fit the current size must re-derive it from
    /// the still-connected source image, instead of leaving a stale mismatched canvas behind.
    @MainActor
    func testChangingRecipeResyncsDimensionsToTheConnectedSource() throws {
        let root = try VideoFixtures.root("dimension-sync-recipe-switch"); defer { try? FileManager.default.removeItem(at: root) }
        let wide = try VideoFixtures.solidPNG((200, 10, 10), width: 320, height: 180, in: root, name: "wide")
        let source = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: wide.path)
        var i2v = StudioNode(kind: .imageToVideo, label: "I2V", position: .init(x: 1, y: 0), model: VideoCapabilityRegistry.animateDiffImageToVideo.recipeID)
        i2v.video = VideoCapabilityRegistry.animateDiffImageToVideo.recommended
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [WorkflowProject(name: "Sync", nodes: [source, i2v], edges: [VideoFixtures.edge(source, "image", i2v, "startImage", .image)])]
        model.currentProjectID = model.projects[0].id

        let wan = VideoCapabilityRegistry.wan22ImageToVideo
        let expected = try XCTUnwrap(fittedDimensions(ratio: 320.0 / 180.0, width: wan.width, height: wan.height, preferredLongestEdge: max(wan.recommended.width, wan.recommended.height)))
        model.editGraph { project in
            guard let index = project.nodes.firstIndex(where: { $0.id == i2v.id }) else { return }
            project.nodes[index].model = wan.recipeID
            project.nodes[index].video = wan.recommended
            VideoDimensionSync.resyncNode(i2v.id, in: &project)
        }
        let synced = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == i2v.id })
        XCTAssertEqual(synced.video.width, expected.0)
        XCTAssertEqual(synced.video.height, expected.1)
        XCTAssertTrue(synced.video.width != wan.recommended.width || synced.video.height != wan.recommended.height, "Must not be left at the new recipe's own default when a source is connected")
    }

    /// Re-choosing which file an already-connected Image Input node points to must re-fit every
    /// downstream video node's canvas, not just a freshly made connection.
    func testChoosingADifferentSourceFileResyncsAlreadyConnectedTargets() throws {
        let root = try VideoFixtures.root("dimension-sync-refile"); defer { try? FileManager.default.removeItem(at: root) }
        let capability = VideoCapabilityRegistry.animateDiffImageToVideo
        let square = try VideoFixtures.solidPNG((10, 10, 200), width: 100, height: 100, in: root, name: "square")
        let portrait = try VideoFixtures.solidPNG((10, 200, 10), width: 90, height: 160, in: root, name: "portrait2")
        var source = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: square.path)
        var i2v = StudioNode(kind: .imageToVideo, label: "I2V", position: .init(x: 1, y: 0), model: capability.recipeID)
        i2v.video = capability.recommended
        var project = WorkflowProject(name: "Sync", nodes: [source, i2v], edges: [VideoFixtures.edge(source, "image", i2v, "startImage", .image)])
        VideoDimensionSync.resyncNode(i2v.id, in: &project)
        let afterSquare = project.nodes.first { $0.id == i2v.id }!.video
        XCTAssertEqual(afterSquare.width, afterSquare.height, "Square source: square canvas")

        source.imagePath = portrait.path
        project.nodes[project.nodes.firstIndex(where: { $0.id == source.id })!] = source
        VideoDimensionSync.resyncTargets(of: source.id, in: &project)
        let afterPortrait = project.nodes.first { $0.id == i2v.id }!.video
        let expected = try XCTUnwrap(fittedDimensions(ratio: 90.0 / 160.0, width: capability.width, height: capability.height))
        XCTAssertEqual(afterPortrait.width, expected.0, "Re-choosing the file re-fits the already-connected node")
        XCTAssertEqual(afterPortrait.height, expected.1)
    }

    func testStartEndVideoRejectsDifferentSourceAspectsInsteadOfSilentlyCroppingAnEndpoint() async throws {
        let root = try VideoFixtures.root("flf-aspect-mismatch"); defer { try? FileManager.default.removeItem(at: root) }
        let start = try VideoFixtures.solidPNG((200, 20, 20), width: 160, height: 90, in: root, name: "landscape")
        let end = try VideoFixtures.solidPNG((20, 20, 200), width: 90, height: 160, in: root, name: "portrait")
        let capability = VideoCapabilityRegistry.minimaxH3FirstLastFrame
        var node = StudioNode(kind: .startEndVideo, label: "Transition", position: .init(x: 0, y: 0), model: capability.recipeID)
        node.video = capability.recommended
        let runner = VideoNodeRunner(media: MediaProcessor(root: root), persistence: StudioPersistence(root: root), engine: nil, capabilities: [capability])
        do {
            _ = try await runner.firstLastFrame(node: node, projectID: UUID(), prompt: "transition", startImage: start, endImage: end, onProgress: { _ in })
            XCTFail("Mismatched endpoint aspects must fail before the model loads")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("same aspect ratio"), error.localizedDescription)
        }
    }

    func testSeparateKindsHaveTaskSpecificTypedPorts() {
        func inputs(_ kind: NodeKind) -> [String] { node(kind).inputPorts.map { "\($0.id):\($0.type.rawValue):\($0.required)" } }
        XCTAssertEqual(inputs(.textToVideo), ["prompt:text:true", "negativePrompt:text:false"])
        XCTAssertEqual(inputs(.imageToVideo), ["startImage:image:true", "prompt:text:true"])
        XCTAssertEqual(inputs(.startEndVideo), ["startImage:image:true", "endImage:image:true", "prompt:text:true"])
        XCTAssertEqual(inputs(.guidedShot), ["sequence:shotSequence:true", "prompt:text:true"])
        XCTAssertEqual(inputs(.videoToVideo), ["sourceVideo:video:true", "prompt:text:true"])
        XCTAssertEqual(inputs(.animatic), ["sequence:shotSequence:true"])
        XCTAssertEqual(node(.assembleVideo).inputPorts.map(\.type), [.video, .video])
        XCTAssertEqual(node(.shotSequence).outputPorts.map(\.type), [.shotSequence])
        for kind in [NodeKind.textToVideo, .imageToVideo, .startEndVideo, .guidedShot, .videoToVideo, .animatic, .assembleVideo] { XCTAssertEqual(node(kind).outputPorts.map(\.type), [.video]) }
        XCTAssertEqual(Set(VideoTask.allCases.map(\.nodeKind)).count, VideoTask.allCases.count, "Each task has its own node kind")
        XCTAssertEqual(NodeKind.textToVideo.category, "Video Generation"); XCTAssertEqual(NodeKind.assembleVideo.category, "Video Editing & Delivery")
    }

    func testOnlyWanTextToVideoIsVerifiedAndUnprovenOrMissingModesCannotRun() {
        XCTAssertEqual(VideoCapabilityRegistry.shipped.filter(\.readiness.proven).map(\.recipeID), [VideoCapabilityRegistry.wanT2VRecipeID])
        XCTAssertTrue(VideoCapabilityRegistry.shipped.contains { $0.recipeID == MediaModelCatalog.animateDiffRecipeID }, "Rejected descriptors remain diagnosable for saved workflows")
        XCTAssertFalse(VideoCapabilityRegistry.selectableCapabilities(for: .textToVideo).contains { $0.recipeID == MediaModelCatalog.animateDiffRecipeID }, "A recipe proven to emit static repeated frames must not appear in video-node choices")
        XCTAssertFalse(VideoCapabilityRegistry.selectableCapabilities(for: .imageToVideo).contains { $0.recipeID == MediaModelCatalog.animateDiffRecipeID })
        XCTAssertFalse(VideoCapabilityRegistry.selectableCapabilities(for: .textToVideo).contains { $0.recipeID == MediaModelCatalog.ltx25RecipeID }, "The CPU-offloaded LTX route must not be presented as a runnable Apple-Silicon backend")
        XCTAssertFalse(VideoCapabilityRegistry.hasUsableAdapter(MediaModelCatalog.ltx25RecipeID))
        XCTAssertThrowsError(try VideoRequestPlanner.makeRequest(settings: VideoCapabilityRegistry.ltx25TextToVideo.recommended, task: .textToVideo, capability: VideoCapabilityRegistry.ltx25TextToVideo, prompt: "a slow pan", negativePrompt: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("disabled"), $0.localizedDescription)
        }
        XCTAssertFalse(VideoCapabilityRegistry.capabilities(for: .imageToVideo).isEmpty, "Image-to-video adapters exist")
        XCTAssertEqual(VideoPreflight.availability(.imageToVideo, installed: []), .needsModel, "Adapters without an installed exact recipe need a model")
        XCTAssertFalse(VideoCapabilityRegistry.capabilities(for: .firstLastFrame).isEmpty)
        XCTAssertEqual(VideoPreflight.availability(.startEndVideo, installed: []), .needsModel)
        XCTAssertTrue(VideoCapabilityRegistry.capabilities(for: .timedKeyframes).isEmpty)
        XCTAssertEqual(VideoPreflight.availability(VideoTask.timedKeyframes.nodeKind, installed: []), .unavailable)
        XCTAssertFalse(VideoCapabilityRegistry.capabilities(for: .videoToVideo).isEmpty, "MiniMax-H3 Ref2VA provides a reference-video adapter")
        XCTAssertEqual(VideoPreflight.availability(VideoTask.videoToVideo.nodeKind, installed: []), .needsModel)
        XCTAssertNil(VideoCapabilityRegistry.capability(recipeID: VideoCapabilityRegistry.wanT2VRecipeID, task: .firstLastFrame), "T2V weights are never offered for FLF2V")
    }

    func testInstalledVideoAdapterIsRunnableWithoutFirstRunAuthorization() {
        let capability = VideoCapabilityRegistry.lingBotImageToVideo
        var installed = FitFixtures.installed(capability.recipeID)
        installed.inferenceVerified = false
        installed.verifiedVideoTasks = []
        var node = StudioNode(kind: .imageToVideo, label: "LingBot I2V", position: .init(x: 0, y: 0), model: capability.recipeID)
        node.video = capability.recommended
        XCTAssertNil(node.experimentalVideoRecipeID)
        XCTAssertNil(NodeModelCompatibility.issue(for: node, installed: [installed]))
        XCTAssertEqual(VideoPreflight.availability(node, installed: [installed]), .runnable)
        XCTAssertNil(VideoPreflight.generationIssue(node, connectedPorts: ["startImage", "prompt"], installed: [installed], registry: [capability]))
    }

    func testNodeCardDoesNotTreatMiniMaxRef2VAAsInstalledFL2VA() {
        let fl2va = VideoCapabilityRegistry.minimaxH3ImageToVideo
        var node = StudioNode(kind: .imageToVideo, label: "MiniMax I2V", position: .init(x: 0, y: 0), model: fl2va.recipeID)
        node.video = fl2va.recommended
        let ref2va = FitFixtures.installed(MediaModelCatalog.minimaxH3Ref2VARecipeID)
        XCTAssertEqual(VideoPreflight.availability(node, installed: [ref2va]), .needsModel, "Ref2VA is a different transformer and cannot satisfy an FL2VA node")
    }

    @MainActor
    func testNewImageToVideoNodePrefersInstalledLingBotOverFailedAnimateDiffAndHeavyMiniMax() throws {
        let root = try VideoFixtures.root("i2v-recommendation"); defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.libraryStore.installed = [FitFixtures.installed(MediaModelCatalog.animateDiffRecipeID), FitFixtures.installed(MediaModelCatalog.lingBotRecipeID)]
        model.createProject()
        model.addNode(.imageToVideo)
        XCTAssertEqual(model.currentProject?.nodes.first(where: { $0.kind == .imageToVideo })?.model, MediaModelCatalog.lingBotRecipeID)
    }

    func testConnectedUnsupportedImageInputRejectsBeforeUpstreamInference() async throws {
        let root = try VideoFixtures.root("unsupported"); defer { try? FileManager.default.removeItem(at: root) }
        let still = try VideoFixtures.solidPNG((200, 0, 0), in: root, name: "start")
        let image = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: still.path)
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 1), prompt: "idea")
        let text = StudioNode(kind: .textModel, label: "Writer", position: .init(x: 1, y: 1), model: "stub")
        let i2v = node(.imageToVideo)
        let project = WorkflowProject(name: "I2V", nodes: [image, prompt, text, i2v], edges: [VideoFixtures.edge(image, "image", i2v, "startImage", .image), VideoFixtures.edge(prompt, "text", text, "prompt", .text), VideoFixtures.edge(text, "text", i2v, "prompt", .text)])
        let textEngine = StubEngine(); let video = FixtureVideoEngine(.fail)
        do {
            _ = try await ExecutionQueue(engine: textEngine, persistence: StudioPersistence(root: root), videoEngine: video, videoCapabilities: VideoFixtures.verifiedRegistry).execute(project: project, targetID: i2v.id, installedModels: ["stub"])
            XCTFail("Image to Video has no adapter and must not run")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Image to video is unavailable"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("not run or substituted"), error.localizedDescription)
        }
        let prompts = await textEngine.capturedPrompts(); XCTAssertTrue(prompts.isEmpty, "Upstream inference must not start")
        let requests = await video.captured(); XCTAssertTrue(requests.isEmpty, "Must not substitute Text to Video")
        let runs = try await StudioPersistence(root: root).loadRuns(); XCTAssertTrue(runs.isEmpty)
    }

    func testTextToVideoPreflightRejectsInvalidSettingsButAllowsUnmeasuredCapability() throws {
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "a pinwheel")
        func project(_ change: (inout VideoGenerationSettings) -> Void) -> WorkflowProject {
            var t2v = node(.textToVideo, model: VideoCapabilityRegistry.wanT2VRecipeID); change(&t2v.videoSettings!)
            return WorkflowProject(name: "T2V", nodes: [prompt, t2v], edges: [VideoFixtures.edge(prompt, "text", t2v, "prompt", .text)])
        }
        let validator = GraphValidator(videoCapabilities: VideoFixtures.verifiedRegistry)
        XCTAssertNoThrow(try validator.validate(project { _ in }))
        let invalid: [(String, (inout VideoGenerationSettings) -> Void)] = [
            ("Duration", { $0.requestedDurationSeconds = 0 }), ("Duration", { $0.requestedDurationSeconds = .nan }), ("Video size", { $0.width = 321 }),
            ("Video size", { $0.height = 2000 }), ("Frame rate", { $0.fps = 0 }), ("Sampling steps", { $0.steps = 0 }),
            ("Guidance", { $0.cfgScale = .nan }), ("Flow shift", { $0.flowShift = .infinity }), ("Seed", { $0.seed = -2 })
        ]
        for (message, change) in invalid {
            XCTAssertThrowsError(try validator.validate(project(change))) { XCTAssertTrue($0.localizedDescription.contains(message), $0.localizedDescription) }
        }
        XCTAssertNoThrow(try GraphValidator(videoCapabilities: [VideoCapabilityRegistry.wanTextToVideo.with(readiness: .awaitingProof)]).validate(project { _ in }))
        var missing = project { _ in }; missing.edges = []
        XCTAssertThrowsError(try validator.validate(missing)) { XCTAssertTrue($0.localizedDescription.contains("prompt"), $0.localizedDescription) }
    }

    func testTextToVideoRequestMapsExactlyToPinnedSdCppArguments() throws {
        var settings = VideoGenerationSettings(); settings.seed = -1
        let request = try VideoRequestPlanner.makeRequest(settings: settings, task: .textToVideo, capability: VideoFixtures.verifiedRegistry[0], prompt: "a red pinwheel", negativePrompt: nil, randomSeed: { 77 })
        XCTAssertEqual(request.seed, 77, "Random seed is resolved and recorded before launch")
        XCTAssertEqual(request.frameCount, 9); XCTAssertEqual(request.fps, 8)
        XCTAssertEqual(request.duration, 1.125); XCTAssertEqual(request.lastFrameTimestamp, 1.0)
        let components = WanTextToVideoCommand.Components(diffusion: URL(fileURLWithPath: "/m/d.gguf"), textEncoder: URL(fileURLWithPath: "/m/t.gguf"), vae: URL(fileURLWithPath: "/m/v.safetensors"))
        let args = try WanTextToVideoCommand.arguments(request, components: components, framePattern: URL(fileURLWithPath: "/w/frame_%03d.png"))
        XCTAssertEqual(args, ["-M", "vid_gen", "--diffusion-model", "/m/d.gguf", "--t5xxl", "/m/t.gguf", "--vae", "/m/v.safetensors", "-p", "a red pinwheel", "-n", settings.negativePrompt,
                              "-W", "320", "-H", "192", "--steps", "20", "--cfg-scale", "6.0", "--sampling-method", "euler", "--video-frames", "9", "--fps", "8", "--flow-shift", "3.0", "--diffusion-fa", "--seed", "77", "-o", "/w/frame_%03d.png"])
        let flf = VideoGenerationRequest(task: .firstLastFrame, recipeID: request.recipeID, engineBuild: request.engineBuild, prompt: "x", negativePrompt: "", width: 320, height: 192, frameCount: 9, fps: 8, steps: 20, cfgScale: 6, flowShift: 3, sampler: "euler", seed: 1, mediaInputs: [])
        XCTAssertThrowsError(try WanTextToVideoCommand.arguments(flf, components: components, framePattern: URL(fileURLWithPath: "/w/f.png")))
    }

    func testDisplayGeometryRejectsNonFiniteOrDegenerateInputBeforeIntConversion() throws {
        XCTAssertThrowsError(try DisplayGeometry.resolve(size: CGSize(width: CGFloat.nan, height: 10), transform: .identity, source: "clip.mov"))
        XCTAssertThrowsError(try DisplayGeometry.resolve(size: CGSize(width: 10, height: CGFloat.infinity), transform: .identity, source: "clip.mov"))
        XCTAssertThrowsError(try DisplayGeometry.resolve(size: CGSize(width: -1, height: 10), transform: .identity, source: "clip.mov"))
        XCTAssertThrowsError(try DisplayGeometry.resolve(size: CGSize(width: 0, height: 10), transform: .identity, source: "clip.mov"))
        XCTAssertThrowsError(try DisplayGeometry.resolve(size: CGSize(width: 10, height: 10), transform: CGAffineTransform(scaleX: 0, y: 1), source: "clip.mov"), "A degenerate transform must not silently produce a zero-width display rect")
        let rotated = try DisplayGeometry.resolve(size: CGSize(width: 10, height: 20), transform: CGAffineTransform(rotationAngle: .pi / 2), source: "clip.mov")
        XCTAssertEqual(abs(rotated.width).rounded(), 20)
        XCTAssertEqual(abs(rotated.height).rounded(), 10)
    }

    func testProgressParserUsesObservedPinnedLogLines() {
        let parser = WanProgressParser(steps: 2)
        XCTAssertTrue(parser.consume("  |######| 243/242 - 1.0GB/s\r").isEmpty, "Tensor loading bars are not sampling progress")
        XCTAssertEqual(parser.consume("[INFO   ] video.cpp:1102 - get_learned_condition completed, taking 7.68s\n").map(\.stage), ["Sampling 0/2"])
        XCTAssertTrue(parser.consume("  |#####| 245/825 - 979.46MB/s\r").isEmpty)
        XCTAssertEqual(parser.consume("  |=====>   | 1/2 - 1.28s/it\r").first?.fraction, 0.5)
        XCTAssertEqual(parser.consume("[INFO   ] video.cpp:1581 - sampling completed, taking 1.66s\n").map(\.stage), ["Decoding frames (VAE)"])
        XCTAssertEqual(parser.stage, .decoding)
    }
}

final class VideoPersistenceAndSequenceTests: XCTestCase {
    func testExistingV2ProjectDecodesUnchangedAndNewNodesRoundtrip() throws {
        let promptID = UUID(), modelID = UUID(), edgeID = UUID()
        let json = """
        {"schemaVersion":2,"id":"\(UUID())","name":"existing","nodes":[{"id":"\(promptID)","kind":"prompt","label":"P","position":{"x":0,"y":0},"prompt":"hello"},{"id":"\(modelID)","kind":"textModel","label":"M","position":{"x":1,"y":1},"model":"stub"}],"edges":[{"id":"\(edgeID)","sourceID":"\(promptID)","sourcePortID":"text","targetID":"\(modelID)","targetPortID":"prompt","type":"text"}]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let old = try decoder.decode(WorkflowProject.self, from: Data(json.utf8))
        XCTAssertEqual(old.nodes.map(\.id), [promptID, modelID]); XCTAssertEqual(old.edges.map(\.id), [edgeID])
        let reencoded = String(decoding: try encoder.encode(old), as: UTF8.self)
        XCTAssertNil(reencoded.range(of: "videoSettings")); XCTAssertNil(reencoded.range(of: "sequenceSpec")); XCTAssertNil(reencoded.range(of: "assemblySettings"))

        var sequence = StudioNode(kind: .shotSequence, label: "Seq", position: .init(x: 0, y: 0))
        sequence.sequence.anchors = [ShotAnchor(id: "anchor-a", label: "A", holdSeconds: 1.5, transitionNote: "push in", boundaryToNext: .continuous), ShotAnchor(id: "anchor-b", label: "B")]
        sequence.sequence.finalHoldSeconds = 3; sequence.sequence.fps = 12
        var t2v = StudioNode(kind: .textToVideo, label: "T2V", position: .init(x: 1, y: 0), model: VideoCapabilityRegistry.wanT2VRecipeID); t2v.video.seed = 99
        var assemble = StudioNode(kind: .assembleVideo, label: "Asm", position: .init(x: 2, y: 0)); assemble.assembly.audio = .silent
        let image = StudioNode(kind: .imageInput, label: "I", position: .init(x: -1, y: 0))
        let project = WorkflowProject(name: "new", nodes: old.nodes + [sequence, t2v, assemble, image, StudioNode(kind: .guidedShot, label: "G", position: .init(x: 3, y: 0))],
                                      edges: old.edges + [VideoFixtures.edge(image, "image", sequence, "anchor-b", .image)])
        let reopened = try decoder.decode(WorkflowProject.self, from: encoder.encode(project))
        XCTAssertEqual(reopened.nodes, project.nodes); XCTAssertEqual(reopened.edges, project.edges)
        XCTAssertEqual(reopened.nodes[2].sequence.anchors.map(\.id), ["anchor-a", "anchor-b"])
        XCTAssertEqual(reopened.nodes[2].sequence.anchors[0].transitionNote, "push in")
        XCTAssertEqual(reopened.nodes[3].video.seed, 99); XCTAssertEqual(reopened.nodes[4].assembly.audio, .silent)
    }

    @MainActor
    func testReorderRemoveKeepEdgesOnTheirImagesAndUndoRestores() async throws {
        let root = try VideoFixtures.root("sequence-edit"); defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.createProject()
        model.addNode(.shotSequence)
        let sequenceID = try XCTUnwrap(model.selectedNodeID)
        model.addSequenceFrames(nodeID: sequenceID, imagePaths: [nil, nil, nil, nil, nil])
        var images: [UUID] = []
        for index in 0..<5 { model.addNode(.imageInput); images.append(try XCTUnwrap(model.selectedNodeID)); _ = index }
        let anchors = try XCTUnwrap(model.currentProject?.nodes.first { $0.id == sequenceID }?.sequence.anchors)
        XCTAssertEqual(anchors.count, 5)
        for (image, anchor) in zip(images, anchors) { model.connect(sourceID: image, sourcePortID: "image", targetID: sequenceID, targetPortID: anchor.id) }
        func wiring() -> [String: UUID] { Dictionary(uniqueKeysWithValues: model.currentProject!.edges.filter { $0.targetID == sequenceID }.map { ($0.targetPortID, $0.sourceID) }) }
        let original = wiring()
        XCTAssertEqual(original.count, 5)

        model.moveSequenceFrame(nodeID: sequenceID, anchorID: anchors[3].id, by: -1)
        model.moveSequenceFrame(nodeID: sequenceID, anchorID: anchors[3].id, by: -1)
        let order = model.currentProject!.nodes.first { $0.id == sequenceID }!.sequence.anchors.map(\.id)
        // Two single-step moves: D swaps with C, then with B.
        XCTAssertEqual(order, [anchors[0].id, anchors[3].id, anchors[1].id, anchors[2].id, anchors[4].id])
        XCTAssertEqual(wiring(), original, "Reordering keeps every connection on the same image slot")
        XCTAssertEqual(model.currentProject!.nodes.first { $0.id == sequenceID }!.inputPorts.map(\.id), order)

        model.removeSequenceFrame(nodeID: sequenceID, anchorID: anchors[2].id)
        var expected = original; expected[anchors[2].id] = nil
        XCTAssertEqual(wiring(), expected)
        XCTAssertNoThrow(try GraphValidator().validate(model.currentProject!, requireRunnableInputs: false))

        model.undo()
        XCTAssertEqual(wiring(), original, "Undo restores the removed frame with its edge")
        XCTAssertEqual(model.currentProject!.nodes.first { $0.id == sequenceID }!.sequence.anchors.map(\.id), order)
        model.undo(); model.undo()
        XCTAssertEqual(model.currentProject!.nodes.first { $0.id == sequenceID }!.sequence.anchors.map(\.id), anchors.map(\.id))
        model.redo(); model.redo()
        XCTAssertEqual(model.currentProject!.nodes.first { $0.id == sequenceID }!.sequence.anchors.map(\.id), order)

        await model.flushProjectWrites()
        let reloaded = try await StudioPersistence(root: root).loadProjects()
        XCTAssertEqual(reloaded.first?.nodes.first { $0.id == sequenceID }?.sequence.anchors.map(\.id), order)
    }

    func testTimingSeparatesLastFrameTimestampFromDurationAndRejectsCollisions() throws {
        var spec = ShotSequenceSpec(fps: 24)
        spec.anchors = (0..<5).map { ShotAnchor(label: "F\($0)", holdSeconds: 2) }
        spec.finalHoldSeconds = 2
        let timing = try SequenceTiming.resolve(spec)
        XCTAssertEqual(timing.anchors.map(\.startFrame), [0, 48, 96, 144, 192])
        XCTAssertEqual(timing.frameCount, 240); XCTAssertEqual(timing.duration, 10); XCTAssertEqual(timing.lastFrameTimestamp, 239.0 / 24)
        spec.finalHoldSeconds = 3
        XCTAssertEqual(try SequenceTiming.resolve(spec).duration, 11, "Final hold on the last frame extends duration")
        spec.anchors[1].holdSeconds = 0.01
        XCTAssertThrowsError(try SequenceTiming.resolve(spec)) { XCTAssertTrue($0.localizedDescription.contains("no frames"), $0.localizedDescription) }
        spec.anchors[1].holdSeconds = .nan
        XCTAssertThrowsError(try SequenceTiming.resolve(spec))
        spec.anchors[1].holdSeconds = 2; spec.finalHoldSeconds = -1
        XCTAssertThrowsError(try SequenceTiming.resolve(spec))
    }
}

final class AnimaticAndAssemblyMediaTests: XCTestCase {
    static let colors: [(Int, Int, Int)] = [(230, 20, 20), (20, 200, 30), (20, 40, 230), (240, 220, 20), (230, 30, 220)]

    func testFiveColorAnimaticDecodesExactOrderTimingAndFinalHold() async throws {
        let root = try VideoFixtures.root("animatic"); defer { try? FileManager.default.removeItem(at: root) }
        let stills = try Self.colors.enumerated().map { try VideoFixtures.solidPNG($0.element, width: 64, height: 36, in: root, name: "c\($0.offset)") }
        var sequence = StudioNode(kind: .shotSequence, label: "Sequence", position: .init(x: 0, y: 0))
        let holds = [0.3, 0.5, 0.2, 0.4, 0]
        sequence.sequence.anchors = stills.enumerated().map { ShotAnchor(label: "C\($0.offset)", holdSeconds: holds[$0.offset] == 0 ? 9 : holds[$0.offset], transitionNote: "note \($0.offset)", imagePath: $0.element.path) }
        // The first four are file-backed; the fifth is connected to prove both sources resolve.
        let connected = StudioNode(kind: .imageInput, label: "E", position: .init(x: -1, y: 0), imagePath: stills[4].path)
        sequence.sequence.anchors[4].imagePath = nil
        sequence.sequence.finalHoldSeconds = 0.6; sequence.sequence.fps = 10; sequence.sequence.width = 160; sequence.sequence.height = 90
        let animatic = StudioNode(kind: .animatic, label: "Animatic", position: .init(x: 1, y: 0))
        let project = WorkflowProject(name: "Animatic", nodes: [connected, sequence, animatic], edges: [
            VideoFixtures.edge(connected, "image", sequence, sequence.sequence.anchors[4].id, .image), VideoFixtures.edge(sequence, "sequence", animatic, "sequence", .shotSequence)])
        let store = StudioPersistence(root: root)
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: project, targetID: animatic.id)
        guard case .video(let url)? = result.values[.init(nodeID: animatic.id, portID: "video")] else { return XCTFail("Expected animatic video") }
        XCTAssertTrue(url.path.contains("/Artifacts/"), "Output is retained")
        let probe = try await VideoProbe.inspect(url)
        XCTAssertEqual(probe.width, 160); XCTAssertEqual(probe.height, 90)
        XCTAssertEqual(probe.frameCount, 20, "3+5+2+4 frames plus a 6-frame final hold at 10 fps")
        XCTAssertEqual(probe.duration, 2.0, accuracy: 0.001)
        XCTAssertEqual(probe.lastFrameTimestamp, 1.9, accuracy: 0.001)
        let expectedIndex = [0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4]
        for (frame, colorIndex) in zip(probe.frames, expectedIndex) {
            XCTAssertTrue(VideoFixtures.close(frame.centerRGB, Self.colors[colorIndex]), "frame at \(frame.time) decoded \(frame.centerRGB), expected color \(colorIndex)")
        }
        XCTAssertEqual(probe.frames.map { ($0.time * 10).rounded() }, (0..<20).map(Double.init))

        let artifacts = try await StudioPersistence(root: root).loadExecutionArtifacts()
        let provenance = try XCTUnwrap(artifacts.first?.mediaProvenance?[animatic.id])
        XCTAssertEqual(provenance.operation, .animatic); XCTAssertEqual(provenance.frameCount, 20)
        XCTAssertEqual(provenance.inputs.count, 5); XCTAssertEqual(provenance.lastFrameTimestamp ?? 0, 1.9, accuracy: 0.0001)
        XCTAssertEqual(provenance.output, try MediaIdentity.of(url))
        guard case .shotSequence(let resolved)? = artifacts.first?.values[.init(nodeID: sequence.id, portID: "sequence")] else { return XCTFail("Sequence value persists") }
        XCTAssertEqual(resolved.anchors.map(\.transitionNote), (0..<5).map { "note \($0)" })
        XCTAssertTrue(resolved.anchors.allSatisfy { $0.image.path.contains("/Artifacts/") }, "Chosen files are retained, not referenced in place")

        // Modifying a retained still in place is detected by content identity, not accepted by URL.
        try Data("tampered".utf8).write(to: resolved.anchors[0].image)
        do { _ = try await VideoNodeRunner(media: MediaProcessor(root: root), persistence: store, engine: nil, capabilities: []).animatic(resolved); XCTFail("Changed content must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed on disk"), error.localizedDescription) }
    }

    func testAssemblyKeepsOrderDurationAndExplicitAudioPolicy() async throws {
        let root = try VideoFixtures.root("assembly"); defer { try? FileManager.default.removeItem(at: root) }
        let red = try await VideoFixtures.colorClip((230, 20, 20), frames: 10, fps: 10, in: root, name: "red")
        let blueSilent = try await VideoFixtures.colorClip((20, 40, 230), frames: 5, fps: 10, width: 320, height: 180, in: root, name: "blue")
        let blue = try await VideoFixtures.withTone(blueSilent, seconds: 0.5, in: root, name: "blue-tone")
        let green = try await VideoFixtures.colorClip((20, 200, 30), frames: 14, fps: 20, in: root, name: "green")
        let inputs = [red, blue, green].enumerated().map { StudioNode(kind: .videoInput, label: "V\($0.offset)", position: .init(x: 0, y: Double($0.offset)), videoPath: $0.element.path) }
        for policy in AssemblyAudioPolicy.allCases {
            var assemble = StudioNode(kind: .assembleVideo, label: "Assemble", position: .init(x: 1, y: 0))
            assemble.dynamicInputs = [.init(id: "clip-a", label: "Clip 1", type: .video), .init(id: "clip-b", label: "Clip 2", type: .video), .init(id: "clip-c", label: "Clip 3", type: .video)]
            assemble.assembly = .init(width: 160, height: 90, fps: 10, audio: policy)
            let project = WorkflowProject(name: "Assemble", nodes: inputs + [assemble], edges: zip(inputs, ["clip-a", "clip-b", "clip-c"]).map { VideoFixtures.edge($0.0, "video", assemble, $0.1, .video) })
            let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root)).execute(project: project, targetID: assemble.id)
            guard case .video(let url)? = result.values[.init(nodeID: assemble.id, portID: "video")] else { return XCTFail("Expected assembly") }
            let probe = try await VideoProbe.inspect(url)
            XCTAssertEqual(probe.duration, 2.2, accuracy: 0.11, "1.0 + 0.5 + 0.7 seconds")
            XCTAssertEqual(probe.width, 160); XCTAssertEqual(probe.height, 90)
            func color(at time: Double) -> [Int] { probe.frames.min { abs($0.time - time) < abs($1.time - time) }!.centerRGB }
            XCTAssertTrue(VideoFixtures.close(color(at: 0.5), (230, 20, 20)), "\(color(at: 0.5))")
            XCTAssertTrue(VideoFixtures.close(color(at: 1.2), (20, 40, 230)), "\(color(at: 1.2))")
            XCTAssertTrue(VideoFixtures.close(color(at: 1.9), (20, 200, 30)), "\(color(at: 1.9))")
            XCTAssertEqual(probe.hasAudio, policy == .preserve)
            if policy == .preserve {
                let audio = try await AVURLAssetAudioRange.range(url), source = try await AVURLAssetAudioRange.range(blue)
                XCTAssertEqual(audio.start, 1.0 + source.start, accuracy: 0.05, "Audio stays aligned with its clip")
                XCTAssertEqual(audio.duration, source.duration, accuracy: 0.05)
                XCTAssertGreaterThan(audio.duration, 0.3)
            }
            let artifacts = try await StudioPersistence(root: root).loadExecutionArtifacts()
            let provenance = try XCTUnwrap(artifacts.first { $0.values[.init(nodeID: assemble.id, portID: "video")] == .video(url) }?.mediaProvenance?[assemble.id])
            XCTAssertEqual(provenance.audio, policy); XCTAssertEqual(provenance.hasAudioTrack, policy == .preserve); XCTAssertEqual(provenance.inputs.count, 3)
        }
        var empty = StudioNode(kind: .assembleVideo, label: "Empty slots", position: .init(x: 0, y: 0))
        empty.assembly.fps = 10
        XCTAssertThrowsError(try GraphValidator().validate(WorkflowProject(name: "e", nodes: [empty], edges: []))) { XCTAssertTrue($0.localizedDescription.contains("empty"), $0.localizedDescription) }
    }

    /// A clip's own asset can carry an audio track that is never actually copied into the assembly,
    /// either because the policy is Silent or because the track doesn't overlap the played range.
    /// `AssemblyClipReport` must distinguish "the source has audio" from "audio was inserted."
    func testAssemblyReportDistinguishesSourceAudioFromCopiedAudio() async throws {
        let root = try VideoFixtures.root("assembly-audio-report"); defer { try? FileManager.default.removeItem(at: root) }
        let silentBase = try await VideoFixtures.colorClip((10, 10, 10), frames: 5, fps: 10, in: root, name: "silent")
        let tonedBase = try await VideoFixtures.colorClip((200, 10, 10), frames: 5, fps: 10, in: root, name: "toned-base")
        let toned = try await VideoFixtures.withTone(tonedBase, seconds: 0.5, in: root, name: "toned")

        let preserved = try await ClipAssembler.assemble([toned, silentBase], settings: .init(width: 160, height: 90, fps: 10, audio: .preserve), to: root.appending(path: "preserve.mov"))
        XCTAssertEqual(preserved.clips.map(\.sourceHasAudio), [true, false])
        XCTAssertEqual(preserved.clips.map(\.audioCopied), [true, false], "Only the toned clip actually contributed audio")

        let silenced = try await ClipAssembler.assemble([toned, silentBase], settings: .init(width: 160, height: 90, fps: 10, audio: .silent), to: root.appending(path: "silent.mov"))
        XCTAssertEqual(silenced.clips.map(\.sourceHasAudio), [true, false], "Source metadata is reported regardless of policy")
        XCTAssertEqual(silenced.clips.map(\.audioCopied), [false, false], "Silent policy must not report audio as copied")
        XCTAssertFalse(silenced.hasAudioTrack)
    }

    /// Multi-track audio clips are rejected by Preserve policy but accepted by Silent with metadata
    /// distinction (sourceHasAudio=true, audioCopied=false).
    func testAssemblyRejectsMultiTrackAudioUnderPreserveAndAcceptsUnderSilent() async throws {
        let root = try VideoFixtures.root("assembly-multi-audio"); defer { try? FileManager.default.removeItem(at: root) }
        let videoBase = try await VideoFixtures.colorClip((150, 100, 50), frames: 5, fps: 10, in: root, name: "video-base")
        let multiTrack = try await VideoFixtures.withMultipleAudioTracks(videoBase, secondsPerTrack: 0.5, in: root, name: "multi")

        do {
            _ = try await ClipAssembler.assemble([multiTrack], settings: .init(width: 160, height: 90, fps: 10, audio: .preserve), to: root.appending(path: "rejected.mov"))
            XCTFail("Expected Preserve policy to reject multi-track audio")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("2 audio tracks"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("one audio track per clip"), error.localizedDescription)
        }

        let silentResult = try await ClipAssembler.assemble([multiTrack], settings: .init(width: 160, height: 90, fps: 10, audio: .silent), to: root.appending(path: "silent-multi.mov"))
        XCTAssertEqual(silentResult.clips[0].sourceHasAudio, true, "Source has audio even though policy is Silent")
        XCTAssertEqual(silentResult.clips[0].audioCopied, false, "Silent policy must not copy audio")
        XCTAssertFalse(silentResult.hasAudioTrack)
    }

    /// A full AVAssetExportSession pass is expensive; an assembly whose aggregate duration would decode
    /// past VideoProbe.frameLimit must be rejected before export starts, not after re-decoding the result.
    func testAssemblyRejectsAggregateFrameEstimateOverDecodeLimitBeforeExport() async throws {
        let root = try VideoFixtures.root("assembly-frame-limit"); defer { try? FileManager.default.removeItem(at: root) }
        // One still repeated 1400 times at 1 fps is a cheap encode (no per-frame decode) but a real 1400 s clip;
        // at 30 fps output that is ~42,000 estimated frames, over VideoProbe.frameLimit (40,000).
        let long = try await VideoFixtures.colorClip((80, 80, 80), frames: 1400, fps: 1, width: 64, height: 36, in: root, name: "long")
        let output = root.appending(path: "out.mov")
        do {
            _ = try await ClipAssembler.assemble([long], settings: .init(width: 64, height: 36, fps: 30, audio: .silent), to: output)
            XCTFail("Expected a pre-export rejection for an over-limit aggregate frame estimate")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("decode-validation limit"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "No export should have been attempted")
    }

    /// The pixel buffer used to encode still frames is drawn in ITU-R BT.709 to match the H.264 track's
    /// declared AVVideoColorPropertiesKey tag (see VideoEncoding.swift). Known primaries and a midtone
    /// gray must still round-trip through encode/decode without gross drift.
    func testKnownColorsRoundTripThroughDeclaredColorSpaceTagging() async throws {
        let root = try VideoFixtures.root("color-tagging"); defer { try? FileManager.default.removeItem(at: root) }
        let samples: [(Int, Int, Int)] = [(128, 128, 128), (255, 0, 0), (0, 255, 0), (0, 0, 255)]
        for (index, rgb) in samples.enumerated() {
            let still = try VideoFixtures.solidPNG(rgb, width: 64, height: 36, in: root, name: "swatch\(index)")
            let output = root.appending(path: "swatch\(index).mov")
            try await FrameSequenceEncoder.encode(frames: [.file(still)], width: 64, height: 36, fps: 10, framesPerImage: [3], to: output)
            let probe = try await VideoProbe.inspect(output)
            let decoded = try XCTUnwrap(probe.frames.first?.centerRGB)
            XCTAssertTrue(VideoFixtures.close(decoded, rgb, tolerance: 20), "swatch \(rgb) decoded as \(decoded)")
        }
    }
}

enum AVURLAssetAudioRange {
    static func range(_ url: URL) async throws -> (start: Double, duration: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        let start = segments.map { $0.timeMapping.target.start.seconds }.min() ?? 0
        let end = segments.map { $0.timeMapping.target.end.seconds }.max() ?? 0
        return (start, end - start)
    }
}

final class VideoRunFailureTests: XCTestCase {
    func testCancelledAssemblyLeavesNoOutputOrPartialFile() async throws {
        let root = try VideoFixtures.root("assembly-cancel"); defer { try? FileManager.default.removeItem(at: root) }
        let clips = try await (0..<6).asyncMap { try await VideoFixtures.colorClip((40 * $0, 80, 120), frames: 240, fps: 24, width: 640, height: 360, in: root, name: "c\($0)") }
        let output = root.appending(path: "cancelled.mov")
        let task = Task { try await ClipAssembler.assemble(clips, settings: .init(width: 1280, height: 720, fps: 24, audio: .preserve), to: output) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { _ = try await task.value; throw XCTSkip("Export finished before cancellation could be delivered on this machine.") }
        catch is CancellationError {} catch let skip as XCTSkip { throw skip } catch { XCTAssertTrue(error.localizedDescription.contains("cancel") || error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "No partial assembly is left behind")
    }

    private func t2vProject() -> (WorkflowProject, StudioNode) {
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "a pinwheel")
        let t2v = StudioNode(kind: .textToVideo, label: "T2V", position: .init(x: 1, y: 0), model: VideoCapabilityRegistry.wanT2VRecipeID)
        let preview = StudioNode(kind: .videoPreview, label: "Preview", position: .init(x: 2, y: 0))
        return (WorkflowProject(name: "T2V", nodes: [prompt, t2v, preview], edges: [VideoFixtures.edge(prompt, "text", t2v, "prompt", .text), VideoFixtures.edge(t2v, "video", preview, "video", .video)]), t2v)
    }

    func testSuccessfulFixtureRunRetainsClipAndRecordsResolvedProvenance() async throws {
        let root = try VideoFixtures.root("t2v-wiring"); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.colorClip((100, 100, 100), frames: 9, fps: 8, width: 320, height: 192, in: root, name: "fixture")
        let (project, t2v) = t2vProject()
        let engine = FixtureVideoEngine(.succeed(clip))
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), videoEngine: engine, videoCapabilities: VideoFixtures.verifiedRegistry).execute(project: project, targetID: project.nodes[2].id)
        guard case .video(let retained)? = result.values[.init(nodeID: project.nodes[2].id, portID: "video")] else { return XCTFail("Expected downstream video") }
        XCTAssertTrue(retained.path.contains("/Artifacts/"))
        let requests = await engine.captured()
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.prompt, "a pinwheel")
        let runs = try await StudioPersistence(root: root).loadRuns()
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.snapshot.videoRequest?.frameCount, 9); XCTAssertEqual(run.snapshot.videoRequest?.fps, 8); XCTAssertEqual(run.snapshot.videoRequest?.seed, requests.first?.seed)
        XCTAssertEqual(run.snapshot.videoRequest?.requestedDurationSeconds, 1.125)
        let artifacts = try await StudioPersistence(root: root).loadExecutionArtifacts()
        XCTAssertEqual(artifacts.first?.graphSnapshot.nodes.first(where: { $0.id == t2v.id })?.video.seed, requests.first.map { Int($0.seed) })
        XCTAssertEqual(run.snapshot.outputMedia?.output, try MediaIdentity.of(retained))
        XCTAssertEqual(run.snapshot.outputMedia?.requestedDurationSeconds, 1.125)
        XCTAssertEqual(run.snapshot.nodeID, t2v.id)
    }

    func testFailedAndCancelledRunsEmitNoMediaAndRecordAttempt() async throws {
        let root = try VideoFixtures.root("t2v-failure"); defer { try? FileManager.default.removeItem(at: root) }
        let (project, _) = t2vProject()
        let store = StudioPersistence(root: root)
        do {
            _ = try await ExecutionQueue(engine: StubEngine(), persistence: store, videoEngine: FixtureVideoEngine(.fail), videoCapabilities: VideoFixtures.verifiedRegistry).execute(project: project, targetID: project.nodes[2].id)
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("fixture engine failure")) }
        let queue = ExecutionQueue(engine: StubEngine(), persistence: store, videoEngine: FixtureVideoEngine(.waitForCancellation), videoCapabilities: VideoFixtures.verifiedRegistry)
        let task = Task { try await queue.execute(project: project, targetID: project.nodes[2].id) }
        try await Task.sleep(for: .milliseconds(300)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let runs = try await store.loadRuns()
        XCTAssertEqual(Set(runs.map(\.status)), [.failed, .cancelled])
        XCTAssertTrue(runs.allSatisfy { $0.snapshot.videoRequest?.frameCount == 9 && $0.snapshot.outputMedia == nil }, "Attempts are kept with their request, without output")
        let artifacts = try await store.loadExecutionArtifacts()
        XCTAssertTrue(artifacts.isEmpty, "No execution result is published for failed or cancelled runs")
        let retained = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Artifacts").path)) ?? []
        XCTAssertTrue(retained.isEmpty, "No media is retained: \(retained)")
    }

    func testFailedAttemptSupersedesEarlierDisplayedResult() {
        let (project, t2v) = t2vProject()
        var progress = WorkflowProgress(runID: UUID(), project: project, target: project.nodes[2].id)
        progress.receive(.started(project.nodes[0].id)); progress.receive(.completed(project.nodes[0].id))
        progress.receive(.started(t2v.id))
        progress.failActive(error: StudioError.validation("boom"))
        XCTAssertEqual(StaleResultPolicy.unfinishedNodes(progress), [t2v.id, project.nodes[2].id])
    }

    /// An installed adapter runs after the ordinary long-workflow confirmation without mutating
    /// the old per-node authorization field or adding an unverified-run flag to provenance.
    @MainActor
    func testRunAnywayExecutesInstalledUnmeasuredVideoRecipeWithoutManualOptIn() async throws {
        let root = try VideoFixtures.root("run-anyway-optin"); defer { try? FileManager.default.removeItem(at: root) }
        let capability = VideoCapabilityRegistry.minimaxH3FirstLastFrame
        let recipe = try XCTUnwrap(ModelCatalog.recipes.first { $0.id == capability.recipeID })
        let installedModel = InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
            components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: root.appending(path: $0.id), source: $0) },
            installedAt: Date(), inferenceVerified: false, available: true, recipeSnapshot: recipe)
        let startFile = try VideoFixtures.solidPNG((200, 20, 20), in: root, name: "start")
        let endFile = try VideoFixtures.solidPNG((20, 20, 200), in: root, name: "end")
        let clip = try await VideoFixtures.colorClip((90, 90, 90), frames: capability.recommended.frameCount, fps: capability.recommended.fps, width: capability.recommended.width, height: capability.recommended.height, in: root, name: "fixture")
        let startNode = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: startFile.path)
        let endNode = StudioNode(kind: .imageInput, label: "End", position: .init(x: 0, y: 1), imagePath: endFile.path)
        let promptNode = StudioNode(kind: .prompt, label: "Transition", position: .init(x: 0, y: 2), prompt: "warm the light")
        var flf = StudioNode(kind: .startEndVideo, label: "MiniMax FLF", position: .init(x: 1, y: 0), model: capability.recipeID)
        flf.video = capability.recommended
        XCTAssertNil(flf.experimentalVideoRecipeID, "Only picked from the recipe list; never manually opted in")
        let project = WorkflowProject(name: "FLF Run Anyway", nodes: [startNode, endNode, promptNode, flf], edges: [
            VideoFixtures.edge(startNode, "image", flf, "startImage", .image),
            VideoFixtures.edge(endNode, "image", flf, "endImage", .image),
            VideoFixtures.edge(promptNode, "text", flf, "prompt", .text)
        ])
        let engine = FixtureVideoEngine(.succeed(clip))
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine(), videoEngine: engine)
        model.libraryStore.installed = [installedModel]
        model.projects = [project]; model.currentProjectID = project.id
        model.selectedNodeID = flf.id

        model.runSelected()
        _ = try XCTUnwrap(model.pendingRun, "Video generation always confirms before running")
        model.confirmPendingRun()

        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isRunning)
        let captured = await engine.captured()
        let request = try XCTUnwrap(captured.first, "Run Anyway must actually run the node, not just dismiss the dialog")
        XCTAssertNil(request.allowsUnverifiedLocalRun)
        XCTAssertNil(model.currentProject?.nodes.first { $0.id == flf.id }?.experimentalVideoRecipeID)
    }

    /// Removing the proof gate must not weaken the model-installation requirement.
    @MainActor
    func testRunAnywayNeverAuthorizesANotInstalledRecipe() throws {
        let capability = VideoCapabilityRegistry.minimaxH3FirstLastFrame
        var flf = StudioNode(kind: .startEndVideo, label: "MiniMax FLF", position: .init(x: 1, y: 0), model: capability.recipeID)
        flf.video = capability.recommended
        let root = try VideoFixtures.root("run-anyway-not-installed"); defer { try? FileManager.default.removeItem(at: root) }
        let startFile = try VideoFixtures.solidPNG((200, 20, 20), in: root, name: "start")
        let endFile = try VideoFixtures.solidPNG((20, 20, 200), in: root, name: "end")
        let start = StudioNode(kind: .imageInput, label: "Start", position: .init(x: 0, y: 0), imagePath: startFile.path)
        let end = StudioNode(kind: .imageInput, label: "End", position: .init(x: 0, y: 1), imagePath: endFile.path)
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 2), prompt: "transition")
        let project = WorkflowProject(name: "Blocked before confirmation", nodes: [start, end, prompt, flf], edges: [
            VideoFixtures.edge(start, "image", flf, "startImage", .image),
            VideoFixtures.edge(end, "image", flf, "endImage", .image),
            VideoFixtures.edge(prompt, "text", flf, "prompt", .text)
        ])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id; model.selectedNodeID = flf.id
        model.runSelected()
        XCTAssertNil(model.pendingRun, "A missing recipe must be reported before the timing confirmation")
        XCTAssertTrue(model.alertMessage?.localizedCaseInsensitiveContains("not installed") == true, model.alertMessage ?? "missing error")
    }

    @MainActor
    func testModelKeepsSuccessfulTakeAfterFailedRun() async throws {
        let root = try VideoFixtures.root("stale"); defer { try? FileManager.default.removeItem(at: root) }
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine(), videoEngine: FixtureVideoEngine(.fail))
        let (project, t2v) = t2vProject()
        model.libraryStore.installed = [FitFixtures.installed(VideoCapabilityRegistry.wanT2VRecipeID)]
        model.projects = [project]; model.currentProjectID = project.id
        let old = URL(fileURLWithPath: "/tmp/old-take.mov")
        model.executionArtifacts = [.init(id: UUID(), projectID: project.id, targetID: t2v.id, graphSnapshot: project, values: [.init(nodeID: t2v.id, portID: "video"): .video(old)], createdAt: Date())]
        XCTAssertEqual(model.displayedValue(for: t2v), .video(old))
        model.selectedNodeID = t2v.id
        model.runSelected()
        if model.pendingRun != nil { model.confirmPendingRun() }
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.displayedValue(for: t2v), .video(old), "Failed attempts must preserve the selected successful take")
        XCTAssertNotNil(model.supersededAttempts[t2v.id])
        XCTAssertEqual(model.executionArtifacts.count, 1, "The earlier result is preserved, not destroyed")
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
