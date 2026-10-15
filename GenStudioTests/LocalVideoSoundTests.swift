import AVFoundation
import CryptoKit
import XCTest
@testable import GenStudio

/// Serves each pinned file by its name, so one install can fetch several different components.
private struct NamedFileTransport: ModelDownloadTransport {
    let files: [String: Data]
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let data = files[from.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
        try data.write(to: to); progress(Int64(data.count))
    }
}

/// LTX-2.3 makes sound with the picture. Its two pinned sound files (about 365 MB) are added to an
/// already-installed package in place, so the 30 GB of video weights are never downloaded again.
final class LTXSoundPackageTests: XCTestCase {
    private func safetensors(_ fill: UInt8, size: Int = 48) -> Data {
        var length = UInt64(2).littleEndian
        var data = Data(bytes: &length, count: 8)
        data.append(Data("{}".utf8)); data.append(Data(repeating: fill, count: size))
        return data
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func component(_ id: String, _ file: String, _ data: Data) -> ModelComponent {
        .init(id: id, role: id, repository: "test/ltx", revision: String(repeating: "b", count: 40), filename: file, byteSize: Int64(data.count), sha256: sha(data), license: "test")
    }
    private func recipe(_ components: [ModelComponent]) -> ModelRecipe {
        .init(id: "fixture-ltx", name: "Fixture LTX", kind: .video, engineID: "mlx-ltx", components: components, runtimeReady: false, minimumMemoryBytes: 0, runtimeProfile: "mlx-ltx", provider: "huggingface")
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "LTXSound-\(UUID())", directoryHint: .isDirectory) }

    private var files: (transformer: Data, audio: Data, vocoder: Data) { (safetensors(1), safetensors(2), safetensors(3, size: 64)) }

    func testAddingTheSoundFilesExtendsTheInstalledPackageInPlace() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let f = files
        let silent = recipe([component("transformer", "transformer.safetensors", f.transformer)])
        let withSound = recipe(silent.components + [component("audioVAE", "audio_vae.safetensors", f.audio), component("vocoder", "vocoder.safetensors", f.vocoder)])
        let transport = NamedFileTransport(files: ["transformer.safetensors": f.transformer, "audio_vae.safetensors": f.audio, "vocoder.safetensors": f.vocoder])
        let library = ModelLibrary(root: root, catalog: [silent, withSound], transport: transport, diskAvailable: { _ in Int64.max })
        let installed = try await library.install(recipe: silent)
        try await library.markInferenceVerified(id: silent.id, for: .imageToVideo)

        let extended = try await library.extendInstalledPackage(id: silent.id, to: withSound)

        XCTAssertEqual(extended.components.map(\.id), ["transformer", "audioVAE", "vocoder"])
        let package = installed.components[0].fileURL.deletingLastPathComponent()
        XCTAssertTrue(extended.components.allSatisfy { $0.fileURL.deletingLastPathComponent() == package }, "Sound files live beside the video weights the loader reads")
        XCTAssertEqual(extended.components[0].fileURL, installed.components[0].fileURL, "The existing weights are not moved or copied")
        let recorded = try await library.installedRecipe(id: silent.id)
        XCTAssertEqual(recorded, withSound)
        let resolved = try await library.resolveInstalledModel(id: silent.id)
        XCTAssertEqual(resolved.recipeSnapshot, withSound)
        XCTAssertTrue(resolved.hasVerifiedVideoTask(.imageToVideo), "Adding a sound decoder keeps the video proof already earned")

        let reopened = ModelLibrary(root: root, catalog: [silent, withSound])
        let reopenedRecipe = try await reopened.installedRecipe(id: silent.id)
        XCTAssertEqual(reopenedRecipe, withSound)
    }

    func testAPackageWhoseExistingFilesDifferIsNotExtended() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let f = files
        let silent = recipe([component("transformer", "transformer.safetensors", f.transformer)])
        let unrelated = recipe([component("transformer", "transformer.safetensors", safetensors(9)), component("audioVAE", "audio_vae.safetensors", f.audio)])
        let library = ModelLibrary(root: root, catalog: [silent, unrelated], transport: NamedFileTransport(files: ["transformer.safetensors": f.transformer, "audio_vae.safetensors": f.audio]), diskAvailable: { _ in Int64.max })
        let installed = try await library.install(recipe: silent)

        do { _ = try await library.extendInstalledPackage(id: silent.id, to: unrelated); XCTFail("A different package must be installed, not grafted on") }
        catch { XCTAssertTrue(error.localizedDescription.contains("existing files"), error.localizedDescription) }
        let recorded = try await library.installedRecipe(id: silent.id)
        XCTAssertEqual(recorded, silent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.components[0].fileURL.deletingLastPathComponent().appending(path: "audio_vae.safetensors").path))
    }

    func testACorruptSoundDownloadLeavesThePackageAsItWas() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let f = files
        let silent = recipe([component("transformer", "transformer.safetensors", f.transformer)])
        let withSound = recipe(silent.components + [component("audioVAE", "audio_vae.safetensors", f.audio), component("vocoder", "vocoder.safetensors", f.vocoder)])
        let library = ModelLibrary(root: root, catalog: [silent, withSound],
                                   transport: NamedFileTransport(files: ["transformer.safetensors": f.transformer, "audio_vae.safetensors": f.audio, "vocoder.safetensors": safetensors(7, size: 64)]),
                                   diskAvailable: { _ in Int64.max })
        let installed = try await library.install(recipe: silent)

        do { _ = try await library.extendInstalledPackage(id: silent.id, to: withSound); XCTFail("A corrupt sound file must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Checksum"), error.localizedDescription) }
        let recorded = try await library.installedRecipe(id: silent.id)
        XCTAssertEqual(recorded, silent)
        let models = try await library.installedModels()
        XCTAssertEqual(models.first?.components.count, 1)
        let package = installed.components[0].fileURL.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: package.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(contents, ["transformer.safetensors"], "No half-added sound file is left in the package")
    }

    func testTheShippedLTXRecipeIsTheSilentPackagePlusTwoPinnedSoundFiles() {
        let silent = MLXVideoModelCatalog.ltx23Q4Silent, full = MLXVideoModelCatalog.ltx23Q4
        XCTAssertEqual(full.id, silent.id); XCTAssertEqual(full.name, silent.name)
        XCTAssertEqual(Array(full.components.prefix(silent.components.count)), silent.components)
        let added = full.components.dropFirst(silent.components.count)
        XCTAssertEqual(added.map(\.filename), ["audio_vae.safetensors", "vocoder.safetensors"])
        XCTAssertEqual(added.map(\.byteSize), [106_509_048, 258_313_851])
        XCTAssertTrue(MLXVideoModelCatalog.isLTX23Package(silent) && MLXVideoModelCatalog.isLTX23Package(full))
        XCTAssertFalse(MLXVideoModelCatalog.hasSound(silent)); XCTAssertTrue(MLXVideoModelCatalog.hasSound(full))
    }
}

/// The sound choice travels with the request; only LTX makes sound, and only when its sound files are present.
final class LTXSoundRequestTests: XCTestCase {
    private func request(_ capability: VideoCapability, sound: Bool?) throws -> VideoGenerationRequest {
        var settings = capability.recommended
        settings.sound = sound
        let inputs: [VideoMediaInput] = capability.task == .imageToVideo ? [.init(role: .startImage, identity: .init(sha256: String(repeating: "c", count: 64), byteSize: 1), location: URL(fileURLWithPath: "/tmp/start.png"))] : []
        return try VideoRequestPlanner.makeRequest(settings: settings, task: capability.task, capability: capability, prompt: "A barber trims a beard.", negativePrompt: nil, mediaInputs: inputs)
    }

    func testLTXMakesSoundUnlessTheClipIsSetToSilent() throws {
        for capability in [VideoCapabilityRegistry.ltx23TextToVideo, VideoCapabilityRegistry.ltx23ImageToVideo, VideoCapabilityRegistry.ltx23FirstLastFrame] {
            XCTAssertTrue(capability.producesAudio, capability.id)
        }
        XCTAssertEqual(try request(VideoCapabilityRegistry.ltx23TextToVideo, sound: nil).sound, true, "Sound is on by default")
        XCTAssertNil(try request(VideoCapabilityRegistry.ltx23TextToVideo, sound: false).sound)
        XCTAssertFalse(VideoCapabilityRegistry.fastMetal5TextToVideo.producesAudio)
        XCTAssertNil(try request(VideoCapabilityRegistry.fastMetal5TextToVideo, sound: true).sound, "A silent model never claims sound")
    }

    func testTheLauncherSkipsSoundOnlyWhenItCannotOrShouldNotMakeIt() {
        XCTAssertEqual(MLXLTXVideoEngine.audioArguments(soundRequested: true, packageHasSound: true), [])
        XCTAssertEqual(MLXLTXVideoEngine.audioArguments(soundRequested: true, packageHasSound: false), ["--no-audio"])
        XCTAssertEqual(MLXLTXVideoEngine.audioArguments(soundRequested: false, packageHasSound: true), ["--no-audio"])
    }

    func testOlderDocumentsDecodeWithSoundUnset() throws {
        let legacy = try JSONDecoder().decode(VideoGenerationSettings.self, from: Data(#"{"width":768,"height":448,"frameCount":121,"fps":24}"#.utf8))
        XCTAssertNil(legacy.sound)
        var silent = legacy; silent.sound = false
        let roundTrip = try JSONDecoder().decode(VideoGenerationSettings.self, from: JSONEncoder().encode(silent))
        XCTAssertEqual(roundTrip.sound, false)
    }

    func testSwitchingModelsKeepsTheSoundChoice() {
        var previous = VideoCapabilityRegistry.ltx23ImageToVideo.recommended
        previous.sound = false
        XCTAssertEqual(VideoCapabilityRegistry.ltx23TextToVideo.recommendedSettings(preservingDurationFrom: previous).sound, false)
        XCTAssertNil(VideoCapabilityRegistry.fastMetal5TextToVideo.recommendedSettings(preservingDurationFrom: previous).sound)
    }
}

/// An ad is several LTX clips (each with sound), maybe a silent clip or end card, joined and exported.
/// The sound must stay with its pictures all the way to the exported file.
final class AdSoundDeliveryTests: XCTestCase {
    private func audioTracks(_ url: URL) async throws -> [AVAssetTrack] { try await AVURLAsset(url: url).loadTracks(withMediaType: .audio) }

    func testAssemblyKeepsEveryClipsSoundOnOneTrackInPlace() async throws {
        let root = try VideoFixtures.root("ad-sound"); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((200, 30, 30), frames: 10, fps: 10, in: root, name: "a"), seconds: 1, in: root, name: "a-tone")
        let silent = try await VideoFixtures.colorClip((30, 30, 200), frames: 10, fps: 10, in: root, name: "b")
        let third = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((30, 200, 30), frames: 10, fps: 10, in: root, name: "c"), seconds: 1, in: root, name: "c-tone")

        let result = try await ClipAssembler.assemble([first, silent, third], settings: .init(width: 160, height: 90, fps: 10, audio: .preserve), to: root.appending(path: "ad.mov"))

        XCTAssertEqual(result.clips.map(\.audioCopied), [true, false, true])
        let tracks = try await audioTracks(root.appending(path: "ad.mov"))
        XCTAssertEqual(tracks.count, 1, "Players and Instagram expect one sound track, not one per shot")
        let segments = try await tracks[0].load(.segments).filter { !$0.isEmpty }
        let starts = segments.map { $0.timeMapping.target.start.seconds }.sorted()
        XCTAssertEqual(starts.first ?? -1, 0, accuracy: 0.05, "Shot 1's sound starts with shot 1")
        XCTAssertTrue(starts.contains { abs($0 - 2.0) < 0.05 }, "Shot 3's sound starts with shot 3, after the silent shot: \(starts)")
    }

    func testInstagramExportKeepsTheSoundAndItsLength() async throws {
        let root = try VideoFixtures.root("ad-export"); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((200, 120, 30), frames: 20, fps: 10, width: 90, height: 160, in: root, name: "v"), seconds: 2, in: root, name: "v-tone")

        let exported = try await InstagramReelExporter.run(sourceVideo: clip, scratchRoot: root.appending(path: "out"))

        let probe = try await VideoProbe.inspect(exported)
        XCTAssertTrue(probe.hasAudio)
        XCTAssertEqual(probe.duration, 2.0, accuracy: 0.1)
        let tracks = try await audioTracks(exported)
        XCTAssertEqual(tracks.count, 1)
    }
}

/// The app offers the 365 MB sound decoder exactly when the installed LTX-2.3 package predates it.
@MainActor
final class LTXSoundFilesOfferTests: XCTestCase {
    private func installed(_ recipe: ModelRecipe) -> InstalledGenerationModel {
        .init(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
              components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/tmp/\($0.filename)"), source: $0) },
              installedAt: Date(), inferenceVerified: true, available: true, recipeSnapshot: recipe)
    }

    func testOnlyTheSilentPackageIsOfferedSoundFiles() {
        let store = ModelLibraryViewModel(library: ModelLibrary(root: FileManager.default.temporaryDirectory.appending(path: "sound-offer-\(UUID())")))
        XCTAssertFalse(store.ltxNeedsSoundFiles, "Nothing to add when LTX isn't installed")
        store.installed = [installed(MLXVideoModelCatalog.ltx23Q4Silent)]
        XCTAssertTrue(store.ltxNeedsSoundFiles)
        XCTAssertEqual(ModelLibraryViewModel.ltxSoundFilesBytes, 364_822_899)
        store.installed = [installed(MLXVideoModelCatalog.ltx23Q4)]
        XCTAssertFalse(store.ltxNeedsSoundFiles)
    }
}

/// macOS 26/27 can kill long MLX GPU work while the display is busy. That failure is not the take's fault,
/// so it is retried once; every other failure is reported as it happened.
final class GPUWatchdogRetryTests: XCTestCase {
    func testOnlyTheWatchdogFailureIsRetriedAndOnlyOnce() {
        let watchdog = "libc++abi: terminating due to uncaught exception [METAL] Command buffer execution failed: Impacting Interactivity (0000000e:kIOGPUCommandBufferCallbackErrorImpactingInteractivity)"
        XCTAssertTrue(MLXGPUWatchdog.shouldRetry(status: 134, output: watchdog, attempt: 1))
        XCTAssertFalse(MLXGPUWatchdog.shouldRetry(status: 134, output: watchdog, attempt: 2), "Never more than one retry")
        XCTAssertFalse(MLXGPUWatchdog.shouldRetry(status: 1, output: "ValueError: bad shape", attempt: 1))
        XCTAssertFalse(MLXGPUWatchdog.shouldRetry(status: 0, output: watchdog, attempt: 1), "A finished job is not retried")
    }
}
