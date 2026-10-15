import AVFoundation
import XCTest
@testable import GenStudio

/// Stands in for the local speech model in graph tests: a 1 kHz tone whose length follows the script.
private actor ToneSpeechEngine: SpeechGenerationEngine {
    let secondsPerWord: Double
    private(set) var requests: [SpeechRequest] = []
    init(secondsPerWord: Double = 0.25) { self.secondsPerWord = secondsPerWord }
    func speak(_ request: SpeechRequest) async throws -> GeneratedSpeech {
        requests.append(request)
        let words = Double(request.text.split(separator: " ").count)
        let url = request.outputDirectory.appending(path: "voice-\(UUID()).wav")
        try VoiceFixtures.tone(1_000, seconds: max(0.4, words * secondsPerWord), to: url)
        return .init(url: url, duration: max(0.4, words * secondsPerWord), elapsedSeconds: 0.01, logTail: "fixture")
    }
}

enum VoiceFixtures {
    static func tone(_ frequency: Double, seconds: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let count = AVAudioFrameCount(seconds * 24_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!; buffer.frameLength = count
        for i in 0..<Int(count) { buffer.floatChannelData![0][i] = Float(sin(2 * .pi * frequency * Double(i) / 24_000) * 0.4) }
        try file.write(from: buffer)
    }

    static func samples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                                                                 AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(output); _ = reader.startReading()
        var all: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0; var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer?.withMemoryRebound(to: Float.self, capacity: length / 4) { all.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) }
        }
        return all
    }

    static func strength(_ samples: [Float], frequency: Double, from start: Double, to end: Double) -> Double {
        let a = max(0, Int(start * 48_000)), b = min(samples.count, Int(end * 48_000))
        guard b > a else { return 0 }
        let k = 2 * cos(2 * .pi * frequency / 48_000)
        var s1 = 0.0, s2 = 0.0
        for i in a..<b { let s0 = Double(samples[i]) + k * s1 - s2; s2 = s1; s1 = s0 }
        return sqrt(max(0, s1 * s1 + s2 * s2 - k * s1 * s2)) / Double(b - a)
    }
}

final class VoiceoverScriptTests: XCTestCase {
    func testRandAmountsAreWrittenTheWayTheyAreSaid() {
        XCTAssertEqual(VoiceoverSettings.spokenForm("Fresh cuts from R150, WhatsApp 082 123 4567."), "Fresh cuts from 150 rand, WhatsApp 082 123 4567.")
        XCTAssertEqual(VoiceoverSettings.spokenForm("Logos from R1 500 and websites from R12,000"), "Logos from 1 500 rand and websites from 12,000 rand")
        XCTAssertEqual(VoiceoverSettings.spokenForm("R&B nights at Rand Club"), "R&B nights at Rand Club", "Only amounts change")
    }

    func testTheBrandKitWritesAStarterScript() {
        var kit = BrandKit(); kit.businessName = "Thabo's Barbershop"; kit.offer = "Fresh cuts from R150"; kit.contact = "WhatsApp 082 123 4567"
        XCTAssertEqual(VoiceoverSettings.starterScript(kit), "Thabo's Barbershop. Fresh cuts from R150. WhatsApp 082 123 4567.")
        XCTAssertEqual(VoiceoverSettings.starterScript(BrandKit()), "")
    }

    func testTheLauncherGetsOnlyTheScriptVoiceAndPaths() {
        let arguments = MLXSpeechEngine.arguments(model: URL(fileURLWithPath: "/m"), text: "Book now.", voice: "A warm South African woman", outputDirectory: URL(fileURLWithPath: "/o"), prefix: "take")
        XCTAssertEqual(arguments, ["--model", "/m", "--text", "Book now.", "--instruct", "A warm South African woman", "--output_path", "/o", "--file_prefix", "take", "--audio_format", "wav", "--lang_code", "en"])
    }

    func testTheVoiceModelIsAPinnedLocalPackage() {
        let recipe = SpeechModelCatalog.qwen3VoiceDesign
        XCTAssertEqual(recipe.kind, .speech); XCTAssertEqual(recipe.engineID, "mlx-audio"); XCTAssertEqual(recipe.runtimeProfile, "mlx-audio")
        XCTAssertEqual(recipe.components.count, 12)
        XCTAssertTrue(recipe.components.contains { $0.filename == "speech_tokenizer/model.safetensors" })
        XCTAssertTrue(recipe.components.allSatisfy { $0.sha256.count == 64 && $0.revision == "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee" })
        XCTAssertTrue(ModelCatalog.recipes.contains(recipe))
    }

    func testOlderDocumentsAndNewVoiceoversDecode() throws {
        let node = StudioNode(kind: .voiceover, label: "Voiceover", position: .init(x: 0, y: 0))
        XCTAssertEqual(node.inputPorts.map(\.id), ["video", "script"])
        XCTAssertEqual(node.inputPorts.map(\.required), [true, false])
        XCTAssertEqual(node.outputPorts.map(\.id), ["video"])
        XCTAssertTrue(node.kind.usesModel)
        let partial = try JSONDecoder().decode(VoiceoverSettings.self, from: Data(#"{"script":"Book now"}"#.utf8))
        XCTAssertEqual(partial.script, "Book now"); XCTAssertFalse(partial.voice.isEmpty)
    }
}

final class VoiceoverMixTests: XCTestCase {
    func testTheVoiceIsLaidOverTheVideoAndTheOriginalSoundDips() async throws {
        let root = try VideoFixtures.root("voiceover-mix"); defer { try? FileManager.default.removeItem(at: root) }
        let video = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((90, 90, 90), frames: 30, fps: 10, in: root, name: "v"), seconds: 3, in: root, name: "v-tone")
        let voice = root.appending(path: "voice.wav"); try VoiceFixtures.tone(1_000, seconds: 1.2, to: voice)
        var settings = VoiceoverSettings(); settings.startSeconds = 0.5

        let output = try await VoiceoverMixer.mix(video: video, voice: voice, settings: settings, to: root.appending(path: "out.mov"))

        let probe = try await VideoProbe.inspect(output)
        XCTAssertEqual(probe.duration, 3, accuracy: 0.1, "The picture is untouched")
        let audio = try await VoiceFixtures.samples(output)
        XCTAssertLessThan(VoiceFixtures.strength(audio, frequency: 1_000, from: 0.0, to: 0.4), 0.01, "No voice before its start")
        XCTAssertGreaterThan(VoiceFixtures.strength(audio, frequency: 1_000, from: 0.7, to: 1.5), 0.05, "The voice speaks")
        let underVoice = VoiceFixtures.strength(audio, frequency: 440, from: 0.8, to: 1.5)
        let afterVoice = VoiceFixtures.strength(audio, frequency: 440, from: 2.2, to: 2.9)
        XCTAssertLessThan(underVoice, afterVoice * 0.6, "Music and clip sound dip under the voice")
        XCTAssertGreaterThan(afterVoice, 0.05, "and come back afterwards")
    }

    func testAVoiceLongerThanTheVideoIsRefusedNotCutOff() async throws {
        let root = try VideoFixtures.root("voiceover-long"); defer { try? FileManager.default.removeItem(at: root) }
        let video = try await VideoFixtures.colorClip((90, 90, 90), frames: 20, fps: 10, in: root, name: "short")
        let voice = root.appending(path: "voice.wav"); try VoiceFixtures.tone(1_000, seconds: 3, to: voice)
        do { _ = try await VoiceoverMixer.mix(video: video, voice: voice, settings: VoiceoverSettings(), to: root.appending(path: "out.mov")); XCTFail("Words must not be cut off") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Shorten the script"), error.localizedDescription) }
    }

    func testASilentVideoGetsTheVoiceAlone() async throws {
        let root = try VideoFixtures.root("voiceover-silent"); defer { try? FileManager.default.removeItem(at: root) }
        let video = try await VideoFixtures.colorClip((90, 90, 90), frames: 30, fps: 10, in: root, name: "silent")
        let voice = root.appending(path: "voice.wav"); try VoiceFixtures.tone(1_000, seconds: 1, to: voice)
        let output = try await VoiceoverMixer.mix(video: video, voice: voice, settings: VoiceoverSettings(), to: root.appending(path: "out.mov"))
        let probe = try await VideoProbe.inspect(output)
        XCTAssertTrue(probe.hasAudio)
    }
}

@MainActor
final class VoiceoverGraphTests: XCTestCase {
    func testTheNodeSpeaksAConnectedScriptOverTheVideo() async throws {
        let root = try VideoFixtures.root("voiceover-graph"); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.colorClip((90, 90, 90), frames: 40, fps: 10, in: root, name: "ad")
        let input = StudioNode(kind: .videoInput, label: "Ad", position: .init(x: 0, y: 0), videoPath: clip.path)
        let script = StudioNode(kind: .prompt, label: "Script", position: .init(x: 0, y: 1), prompt: "Fresh cuts from R150. Book now.")
        var voice = StudioNode(kind: .voiceover, label: "Voiceover", position: .init(x: 1, y: 0), model: SpeechModelCatalog.qwen3VoiceDesignRecipeID)
        voice.voiceoverSettings?.voice = "A calm South African man"
        let project = WorkflowProject(name: "vo", nodes: [input, script, voice], edges: [
            VideoFixtures.edge(input, "video", voice, "video", .video), VideoFixtures.edge(script, "text", voice, "script", .text)
        ])
        let engine = ToneSpeechEngine()
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root), speechEngine: engine).execute(project: project, targetID: voice.id)

        let requests = await engine.requests
        XCTAssertEqual(requests.first?.text, "Fresh cuts from 150 rand. Book now.", "The connected script wins, in its spoken form")
        XCTAssertEqual(requests.first?.voice, "A calm South African man")
        guard case .video(let url)? = result.values[.init(nodeID: voice.id, portID: "video")] else { return XCTFail("Voiceover output") }
        let probe = try await VideoProbe.inspect(url)
        XCTAssertTrue(probe.hasAudio); XCTAssertEqual(probe.duration, 4, accuracy: 0.1)
    }

    func testAVoiceoverWithNoScriptIsCaughtBeforeRunning() async throws {
        let root = try VideoFixtures.root("voiceover-empty"); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try await VideoFixtures.colorClip((90, 90, 90), frames: 10, fps: 10, in: root, name: "ad")
        let input = StudioNode(kind: .videoInput, label: "Ad", position: .init(x: 0, y: 0), videoPath: clip.path)
        let voice = StudioNode(kind: .voiceover, label: "Closing voice", position: .init(x: 1, y: 0), model: SpeechModelCatalog.qwen3VoiceDesignRecipeID)
        let project = WorkflowProject(name: "vo", nodes: [input, voice], edges: [VideoFixtures.edge(input, "video", voice, "video", .video)])
        XCTAssertThrowsError(try GraphValidator().validate(project, requireRunnableInputs: true)) {
            XCTAssertTrue($0.localizedDescription.contains("Closing voice"), $0.localizedDescription)
        }
    }

    func testStartVideoAdAddsAVoiceoverOnlyWhenTheVoiceModelIsInstalled() throws {
        func model(installed: [ModelRecipe]) throws -> StudioModel {
            let root = FileManager.default.temporaryDirectory.appending(path: "vo-template-\(UUID())")
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            var kit = BrandKit(); kit.businessName = "Lerato's Salon"; kit.offer = "Braids from R350"
            try kit.save(root: root)
            let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
            model.libraryStore.installed = installed.map { recipe in
                InstalledGenerationModel(id: recipe.id, name: recipe.name, kind: recipe.kind, engineID: recipe.engineID,
                                         components: recipe.components.map { .init(id: $0.id, role: $0.role, fileURL: URL(fileURLWithPath: "/tmp/\($0.id)"), source: $0) },
                                         installedAt: Date(), inferenceVerified: true, available: true, recipeSnapshot: recipe)
            }
            return model
        }
        let without = try model(installed: [])
        without.createLocalVideoAdWorkflow()
        XCTAssertFalse(without.currentProject!.nodes.contains { $0.kind == .voiceover })

        let with = try model(installed: [SpeechModelCatalog.qwen3VoiceDesign])
        with.createLocalVideoAdWorkflow()
        let project = try XCTUnwrap(with.currentProject)
        let voice = try XCTUnwrap(project.nodes.first { $0.kind == .voiceover })
        XCTAssertEqual(voice.voiceoverSettings?.script, "Lerato's Salon. Braids from R350.")
        let assemble = try XCTUnwrap(project.nodes.first { $0.kind == .assembleVideo })
        let export = try XCTUnwrap(project.nodes.first { $0.kind == .instagramExport })
        XCTAssertTrue(project.edges.contains { $0.sourceID == assemble.id && $0.targetID == voice.id })
        XCTAssertTrue(project.edges.contains { $0.sourceID == voice.id && $0.targetID == export.id })
    }
}
