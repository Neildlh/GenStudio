import AVFoundation
import Foundation

/// Pinned local speech models. Qwen3-TTS Voice Design takes a plain-language description of the voice
/// ("a warm South African woman in her thirties"), so a voice is chosen by describing it.
enum SpeechModelCatalog {
    static let qwen3VoiceDesignRecipeID = "mlx-qwen3-tts-voicedesign-17b-8bit"
    static let mlxAudioBuild = "mlx-audio@0.5.4"
    private static let repository = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
    private static let revision = "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee"

    private static func component(_ id: String, _ role: String, _ filename: String, _ bytes: Int64, _ sha256: String) -> ModelComponent {
        .init(id: id, role: role, repository: repository, revision: revision, filename: filename, byteSize: bytes, sha256: sha256, license: "Apache-2.0")
    }

    /// Complete package as published at the pinned revision (12 Oct 2026); README and .gitattributes omitted.
    static let qwen3VoiceDesign: ModelRecipe = .init(
        id: qwen3VoiceDesignRecipeID, name: "Qwen3-TTS 1.7B Voice Design · MLX 8-bit (voiceover)", kind: .speech, engineID: "mlx-audio", components: [
            component("config", "config", "config.json", 5_437, "b91c47798e77e259e6b86987e48d7a5eca8e703205e00afb63fe08ec5251f983"),
            component("generationConfig", "config", "generation_config.json", 245, "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
            component("merges", "tokenizer", "merges.txt", 1_671_839, "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
            component("model", "speechModel", "model.safetensors", 2_393_308_931, "1a84179d87c972353ccdd9b48f3c4422509b3d1b11030d32358312fb0f3800d7"),
            component("modelIndex", "speechModel", "model.safetensors.index.json", 71_786, "2551ed02dc288b90cd6b7ec98652433f08ef2ae98fb3eda5248a4b9e5b47d08b"),
            component("preprocessor", "config", "preprocessor_config.json", 127, "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
            component("tokenizerConfig", "tokenizer", "tokenizer_config.json", 7_344, "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
            component("vocab", "tokenizer", "vocab.json", 2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            component("codecConfig", "speechCodec", "speech_tokenizer/config.json", 2_336, "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
            component("codecConfiguration", "speechCodec", "speech_tokenizer/configuration.json", 76, "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
            component("codec", "speechCodec", "speech_tokenizer/model.safetensors", 682_293_092, "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
            component("codecPreprocessor", "speechCodec", "speech_tokenizer/preprocessor_config.json", 234, "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb")
        ], runtimeReady: false, minimumMemoryBytes: 16 * 1024 * 1024 * 1024,
        runtimeProfile: "mlx-audio", provider: "huggingface", sourceURL: URL(string: "https://huggingface.co/\(repository)")
    )

    static let recipes = [qwen3VoiceDesign]
}

struct SpeechRequest: Sendable {
    let recipeID: String
    /// Already in spoken form (see `VoiceoverSettings.spokenForm`).
    let text: String
    /// Plain-language voice description.
    let voice: String
    let outputDirectory: URL
}

struct GeneratedSpeech: Sendable {
    let url: URL
    let duration: Double
    let elapsedSeconds: Double
    let logTail: String
}

protocol SpeechGenerationEngine: Sendable {
    func speak(_ request: SpeechRequest) async throws -> GeneratedSpeech
}

/// Local text-to-speech through the app-owned runtime's narrow `genstudio-mlx-tts` launcher (mlx-audio,
/// offline). Only the exact pinned Voice Design package is accepted.
actor MLXSpeechEngine: SpeechGenerationEngine {
    private let library: ModelLibrary
    private let resourceRoot: URL?
    private let launcherOverride: URL?
    private let timeout: Duration

    init(library: ModelLibrary, resourceRoot: URL? = Bundle.main.resourceURL, launcherOverride: URL? = nil, timeout: Duration = .seconds(600)) {
        self.library = library; self.resourceRoot = resourceRoot; self.launcherOverride = launcherOverride; self.timeout = timeout
    }

    static func arguments(model: URL, text: String, voice: String, outputDirectory: URL, prefix: String) -> [String] {
        ["--model", model.path, "--text", text, "--instruct", voice, "--output_path", outputDirectory.path, "--file_prefix", prefix, "--audio_format", "wav", "--lang_code", "en"]
    }

    func speak(_ request: SpeechRequest) async throws -> GeneratedSpeech {
        guard request.recipeID == SpeechModelCatalog.qwen3VoiceDesignRecipeID else {
            throw StudioError.validation("Choose an installed voiceover model in the Voiceover node.")
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StudioError.validation("Voiceover needs a script.") }
        guard text.utf8.count <= 4_000 else { throw StudioError.validation("Voiceover scripts are limited to about 600 words; an advert needs far fewer.") }
        try await ManagedMLXRuntime.checkEnvironment(family: .speech, resourceRoot: resourceRoot)
        GenerationProgressContext.report?(.init(stage: "Checking the voice model"))
        let installed = try await library.resolveInstalledModel(id: request.recipeID)
        guard installed.recipeSnapshot == SpeechModelCatalog.qwen3VoiceDesign,
              let config = installed.components.first(where: { $0.source.filename == "config.json" }) else {
            throw StudioError.validation("The installed voice model is incomplete or does not match its pinned package. Reinstall it from Model Library.")
        }
        let launcher = try launcherOverride ?? ManagedMLXRuntime.launcher(named: "genstudio-mlx-tts", family: .speech, resourceRoot: resourceRoot)
        let work = request.outputDirectory.appending(path: "tts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let started = ProcessInfo.processInfo.systemUptime
        GenerationProgressContext.report?(.init(stage: "Speaking the script"))
        NativeRuntime.state("running", model: request.recipeID)
        defer { NativeRuntime.state("unloaded", model: request.recipeID) }
        let result = try await NativeProcessRunner().run(executable: launcher,
                                                         arguments: Self.arguments(model: config.fileURL.deletingLastPathComponent(), text: text, voice: request.voice, outputDirectory: work, prefix: "voice"),
                                                         timeout: timeout, onOutput: { _ in })
        try Task.checkCancellation()
        let tail = String((result.stdout + "\n" + result.stderr).suffix(4_000))
        guard result.status == 0 else { throw StudioError.validation("Local voiceover failed (exit \(result.status)): \(result.stderr.suffix(1_200))") }
        guard let wav = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "wav" }) else {
            throw StudioError.validation("The voice model finished without writing any audio.")
        }
        let duration = try Self.validate(wav)
        let final = request.outputDirectory.appending(path: "\(UUID().uuidString).wav")
        try FileManager.default.moveItem(at: wav, to: final)
        try? await library.markInferenceVerified(id: request.recipeID)
        return .init(url: final, duration: duration, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, logTail: tail)
    }

    /// Decodes the whole file and rejects silence: a successful exit is not proof of speech.
    static func validate(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { throw StudioError.validation("The voiceover is empty.") }
        try file.read(into: buffer)
        let duration = Double(frames) / file.processingFormat.sampleRate
        guard duration >= 0.3, let channel = buffer.floatChannelData?[0] else { throw StudioError.validation("The voiceover is too short to use.") }
        var sum = 0.0
        for i in 0..<Int(buffer.frameLength) { sum += Double(channel[i] * channel[i]) }
        guard sqrt(sum / Double(buffer.frameLength)) > 0.005 else { throw StudioError.validation("The voice model produced silence. Try the take again.") }
        return duration
    }
}

/// What the Voiceover node says, how it sounds and where it starts.
struct VoiceoverSettings: Codable, Hashable, Sendable {
    var script = ""
    var voice = VoiceoverSettings.voicePresets[0].description
    var startSeconds = 0.3
    var voiceVolume = 1.0
    /// Lower everything else (clip sound, music) while the voice speaks.
    var duckOthers = true

    static let voicePresets: [(title: String, description: String)] = [
        ("South African woman · warm", "A warm, friendly South African woman in her thirties, clear and upbeat, speaking like a local radio advert."),
        ("South African man · confident", "A confident, friendly South African man in his forties with a natural Johannesburg accent, warm and trustworthy, like a local radio advert."),
        ("Young and energetic", "An energetic young South African presenter in their twenties, quick and fun, like a social media advert."),
        ("Calm and premium", "A calm, polished South African woman with a soft, premium tone, unhurried and elegant, like a luxury brand advert."),
        ("Deep and authoritative", "A deep, authoritative South African man, slow and assured, like a television announcer.")
    ]
    /// Under the clip sound and music while the voice speaks.
    static let duckLevel = 0.25
    /// Unhurried advert delivery.
    static let wordsPerSecond = 2.6

    var estimatedSeconds: Double { Double(script.split(whereSeparator: \.isWhitespace).count) / Self.wordsPerSecond }

    /// Writes rand amounts the way they are said ("R150" → "150 rand"); everything else is left alone.
    static func spokenForm(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])R(\d(?:[\d ,.]*\d)?)"#) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1 rand")
    }

    /// Business name, offer and contact from the Brand Kit, one sentence each.
    static func starterScript(_ kit: BrandKit) -> String {
        [kit.businessName, kit.offer, kit.contact].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .map { "!?.".contains($0.last!) ? $0 : $0 + "." }.joined(separator: " ")
    }
}

extension VoiceoverSettings {
    private enum CodingKeys: String, CodingKey { case script, voice, startSeconds, voiceVolume, duckOthers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? voice
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? startSeconds
        voiceVolume = try c.decodeIfPresent(Double.self, forKey: .voiceVolume) ?? voiceVolume
        duckOthers = try c.decodeIfPresent(Bool.self, forKey: .duckOthers) ?? duckOthers
    }
}

/// Lays a spoken voice over a finished video: the picture is copied untouched, the existing sound dips
/// under the voice, and everything is mixed to one track. A voice that would run past the end is refused,
/// never cut off mid-word.
enum VoiceoverMixer {
    static func mix(video: URL, voice: URL, settings: VoiceoverSettings, to output: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: video), voiceAsset = AVURLAsset(url: voice)
        guard try await videoAsset.loadTracks(withMediaType: .video).first != nil else { throw StudioError.validation("Voiceover needs a video track.") }
        let duration = try await videoAsset.load(.duration).seconds
        guard let voiceTrack = try await voiceAsset.loadTracks(withMediaType: .audio).first else { throw StudioError.validation("The voiceover has no sound.") }
        let voiceRange = try await voiceTrack.load(.timeRange)
        let start = max(0, settings.startSeconds), spoken = voiceRange.duration.seconds
        guard start + spoken <= duration + 0.05 else {
            throw StudioError.validation(String(format: "The voiceover is %.1f s, but only %.1f s of video follow its start at %.1f s. Shorten the script, start it earlier, or add more video.", spoken, max(0, duration - start), start))
        }
        let timescale: CMTimeScale = 48_000
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }
        let sound = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        if let original = try await videoAsset.loadTracks(withMediaType: .audio).first, let track = sound.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = try await original.load(.timeRange)
            try track.insertTimeRange(range, of: original, at: range.start)
            let input = AVMutableAudioMixInputParameters(track: track)
            if settings.duckOthers {
                let duck = VoiceoverSettings.duckLevel, ramp = 0.3
                VolumeEnvelope(points: [(0, 1), (max(0, start - ramp), 1), (start, duck), (start + spoken, duck), (min(duration, start + spoken + ramp), 1), (duration, 1)]).apply(to: input)
            }
            parameters.append(input)
        }
        guard let voiceComposition = sound.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError.validation("Could not create the voiceover track.") }
        try voiceComposition.insert(voiceRange, of: voiceTrack, placedAt: time(start))
        let voiceInput = AVMutableAudioMixInputParameters(track: voiceComposition)
        voiceInput.setVolume(Float(min(1, max(0, settings.voiceVolume))), at: .zero)
        parameters.append(voiceInput)
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters

        let scratch = output.deletingLastPathComponent().appending(path: "voiceover-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let mixed = scratch.appending(path: "sound.m4a")
        try await ClipAssembler.mixDown(sound, mix: mix, duration: time(duration), to: mixed)
        try? FileManager.default.removeItem(at: output)
        try await VideoUpscaleRunner.mux(video: video, audioFrom: mixed, to: output)
        let probe = try await VideoProbe.inspect(output)
        guard probe.hasAudio, abs(probe.duration - duration) < 0.15 else {
            try? FileManager.default.removeItem(at: output)
            throw StudioError.validation("Voiceover validation failed: expected \(duration) s with sound; decoded \(probe.duration) s.")
        }
        return output
    }
}

extension VideoNodeRunner {
    func voiceover(node: StudioNode, video: URL, script: String, engine: any SpeechGenerationEngine, onProgress: @escaping @Sendable (EngineProgress) -> Void) async throws -> Output {
        try await media.validateVideo(video)
        let settings = node.voiceoverSettings ?? .init()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let speech = try await GenerationProgressContext.$report.withValue(onProgress) {
            try await engine.speak(.init(recipeID: node.model, text: VoiceoverSettings.spokenForm(script), voice: settings.voice, outputDirectory: scratch))
        }
        defer { try? FileManager.default.removeItem(at: speech.url) }
        onProgress(.init(stage: "Mixing the voice over the video"))
        let output = scratch.appending(path: "voiceover-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await VoiceoverMixer.mix(video: video, voice: speech.url, settings: settings, to: output)
        try Task.checkCancellation()
        let retained = try await media.retain(output)
        let probe = try await VideoProbe.inspect(retained)
        var provenance = RenderedMediaProvenance(operation: .voiceover, output: try MediaIdentity.of(retained), inputs: [try MediaIdentity.of(video)], width: probe.width, height: probe.height,
                                                 fps: Int(probe.nominalFPS.rounded()), frameCount: probe.frameCount, duration: probe.duration, lastFrameTimestamp: probe.lastFrameTimestamp, hasAudioTrack: true)
        provenance.elapsedSeconds = speech.elapsedSeconds
        return .init(value: .video(retained), provenance: provenance, run: nil)
    }
}
