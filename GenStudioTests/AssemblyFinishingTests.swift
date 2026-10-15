import AVFoundation
import XCTest
@testable import GenStudio

/// Assemble as an advert editor: dissolves between shots, fades from and to black, and one music track
/// under the whole ad that dips under each clip's own sound and fades out at the end.
final class AssemblyTimelineTests: XCTestCase {
    func testADissolveOverlapsNeighboursAndShortensTheAd() {
        let timeline = AssemblyTimeline(durations: [5, 5, 3], transition: .dissolve, seconds: 0.5)
        XCTAssertEqual(timeline.starts, [0, 4.5, 9.0])
        XCTAssertEqual(timeline.total, 12.0, accuracy: 0.0001)
        XCTAssertEqual(AssemblyTimeline(durations: [5, 5], transition: .cut, seconds: 0.5).total, 10)
    }

    func testADissolveNeverEatsMoreThanAShortClipCanGive() {
        let timeline = AssemblyTimeline(durations: [4, 1, 4], transition: .dissolve, seconds: 2)
        XCTAssertLessThanOrEqual(timeline.overlap, 0.45, "Each clip keeps a moment of its own between dissolves")
    }

    func testMusicDipsUnderClipSoundAndFadesOut() {
        let envelope = VolumeEnvelope.music(total: 10, level: 0.8, duck: true, clipSound: [2...4], fadeOut: 1.5)
        XCTAssertEqual(envelope.volume(at: 1), 0.8, accuracy: 0.01)
        XCTAssertEqual(envelope.volume(at: 3), 0.8 * VolumeEnvelope.duckFactor, accuracy: 0.01)
        XCTAssertEqual(envelope.volume(at: 6), 0.8, accuracy: 0.01)
        XCTAssertEqual(envelope.volume(at: 10), 0, accuracy: 0.01)
        XCTAssertGreaterThan(envelope.volume(at: 9), 0.2)
        let flat = VolumeEnvelope.music(total: 10, level: 0.8, duck: false, clipSound: [2...4], fadeOut: 1.5)
        XCTAssertEqual(flat.volume(at: 3), 0.8, accuracy: 0.01)
    }

    func testOlderAssembliesOpenAsPlainCuts() throws {
        let saved = try JSONDecoder().decode(AssemblySettings.self, from: Data(#"{"width":0,"height":0,"fps":24,"audio":"preserve"}"#.utf8))
        XCTAssertEqual(saved.transition, .cut); XCTAssertFalse(saved.fadeIn); XCTAssertFalse(saved.fadeOut); XCTAssertNil(saved.musicPath)
        XCTAssertFalse(saved.needsMixdown)
    }
}

final class AssemblyFinishingRenderTests: XCTestCase {
    private func tone(_ frequency: Double, seconds: Double, amplitude: Double = 0.3, in root: URL, name: String) throws -> URL {
        let url = root.appending(path: "\(name).m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        let count = AVAudioFrameCount(seconds * 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)); buffer.frameLength = count
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(count) { samples[i] = Float(sin(2 * .pi * frequency * Double(i) / 48_000) * amplitude) }
        try file.write(from: buffer)
        return url
    }

    /// Mono samples of the output's single audio track.
    private func samples(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                                                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var all: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0; var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer?.withMemoryRebound(to: Float.self, capacity: length / 4) { all.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) }
        }
        return all
    }

    /// Strength of one frequency in a time window (Goertzel), so music and clip sound can be told apart.
    private func strength(_ samples: [Float], frequency: Double, from start: Double, to end: Double) -> Double {
        let a = max(0, Int(start * 48_000)), b = min(samples.count, Int(end * 48_000))
        guard b > a else { return 0 }
        let k = 2 * cos(2 * .pi * frequency / 48_000)
        var s1 = 0.0, s2 = 0.0
        for i in a..<b { let s0 = Double(samples[i]) + k * s1 - s2; s2 = s1; s1 = s0 }
        return sqrt(max(0, s1 * s1 + s2 * s2 - k * s1 * s2)) / Double(b - a)
    }

    func testADissolveBlendsTheShotsAndFadesUseBlack() async throws {
        let root = try VideoFixtures.root("dissolve"); defer { try? FileManager.default.removeItem(at: root) }
        let red = try await VideoFixtures.colorClip((230, 20, 20), frames: 10, fps: 10, in: root, name: "red")
        let blue = try await VideoFixtures.colorClip((20, 20, 230), frames: 10, fps: 10, in: root, name: "blue")
        var settings = AssemblySettings(width: 160, height: 90, fps: 10, audio: .preserve)
        settings.transition = .dissolve; settings.transitionSeconds = 0.4; settings.fadeIn = true; settings.fadeOut = true

        let result = try await ClipAssembler.assemble([red, blue], settings: settings, to: root.appending(path: "ad.mov"))

        XCTAssertEqual(result.probe.duration, 1.6, accuracy: 0.11, "1 s + 1 s − 0.4 s of overlap")
        func colour(_ time: Double) -> [Int] { result.probe.frames.min { abs($0.time - time) < abs($1.time - time) }!.centerRGB }
        XCTAssertTrue(colour(0).allSatisfy { $0 < 60 }, "Opens from black: \(colour(0))")
        XCTAssertTrue(VideoFixtures.close(colour(0.5), (230, 20, 20)), "\(colour(0.5))")
        let middle = colour(0.8)
        XCTAssertTrue(middle[0] > 50 && middle[2] > 50, "Mid-dissolve shows both shots: \(middle)")
        XCTAssertTrue(VideoFixtures.close(colour(1.1), (20, 20, 230)), "\(colour(1.1))")
        XCTAssertTrue(colour(1.55).allSatisfy { $0 < 80 }, "Ends on black: \(colour(1.55))")
        XCTAssertFalse(result.hasAudioTrack, "No sound in, no track out")
    }

    func testMusicPlaysUnderTheWholeAdDuckedUnderClipSound() async throws {
        let root = try VideoFixtures.root("music"); defer { try? FileManager.default.removeItem(at: root) }
        let talking = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((200, 30, 30), frames: 20, fps: 10, in: root, name: "a"), seconds: 2, in: root, name: "a-tone")
        let quiet = try await VideoFixtures.colorClip((30, 30, 200), frames: 20, fps: 10, in: root, name: "b")
        // A short music file loops to fill the ad.
        let music = try tone(1_000, seconds: 1.5, in: root, name: "music")
        var settings = AssemblySettings(width: 160, height: 90, fps: 10, audio: .preserve)
        settings.musicPath = music.path; settings.musicVolume = 0.8; settings.duckMusic = true

        let result = try await ClipAssembler.assemble([talking, quiet], settings: settings, music: music, to: root.appending(path: "ad.mov"))

        XCTAssertTrue(result.hasAudioTrack)
        let soundTracks = try await AVURLAsset(url: root.appending(path: "ad.mov")).loadTracks(withMediaType: .audio)
        XCTAssertEqual(soundTracks.count, 1)
        XCTAssertEqual(result.probe.duration, 4, accuracy: 0.11)
        let audio = try await samples(root.appending(path: "ad.mov"))
        let musicUnderClip = strength(audio, frequency: 1_000, from: 0.6, to: 1.6)
        let musicAlone = strength(audio, frequency: 1_000, from: 2.4, to: 3.0)
        XCTAssertGreaterThan(strength(audio, frequency: 440, from: 0.6, to: 1.6), 0.02, "The clip's own sound is kept")
        XCTAssertLessThan(musicUnderClip, musicAlone * 0.6, "Music dips under the clip's sound")
        XCTAssertGreaterThan(musicAlone, 0.02, "Music plays on (looped) under the silent shot")
        XCTAssertLessThan(strength(audio, frequency: 1_000, from: 3.8, to: 3.98), musicAlone * 0.5, "Music fades out at the end")
    }

    func testMutedClipsStillGetTheMusic() async throws {
        let root = try VideoFixtures.root("music-muted"); defer { try? FileManager.default.removeItem(at: root) }
        let talking = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((200, 30, 30), frames: 20, fps: 10, in: root, name: "a"), seconds: 2, in: root, name: "a-tone")
        let music = try tone(1_000, seconds: 3, in: root, name: "music")
        var settings = AssemblySettings(width: 160, height: 90, fps: 10, audio: .silent)
        settings.musicPath = music.path

        let result = try await ClipAssembler.assemble([talking], settings: settings, music: music, to: root.appending(path: "ad.mov"))

        let audio = try await samples(root.appending(path: "ad.mov"))
        XCTAssertTrue(result.hasAudioTrack)
        XCTAssertLessThan(strength(audio, frequency: 440, from: 0.5, to: 1.5), 0.005, "Clip sound is muted")
        XCTAssertGreaterThan(strength(audio, frequency: 1_000, from: 0.5, to: 1.5), 0.02, "Music remains")
    }
}
