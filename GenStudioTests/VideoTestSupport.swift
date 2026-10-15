import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GenStudio

enum VideoFixtures {
    static func root(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "GenStudio-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Solid-color PNG. Colors are 0–255 RGB.
    static func solidPNG(_ rgb: (Int, Int, Int), width: Int = 64, height: Int = 36, in directory: URL, name: String) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = directory.appending(path: "\(name).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Deterministic solid-color clip, encoded from stills. Not generation evidence.
    static func colorClip(_ rgb: (Int, Int, Int), frames: Int, fps: Int, width: Int = 160, height: Int = 90, in directory: URL, name: String) async throws -> URL {
        let still = try solidPNG(rgb, width: width, height: height, in: directory, name: "\(name)-still")
        let url = directory.appending(path: "\(name).mov")
        try await FrameSequenceEncoder.encode(frames: [.file(still)], width: width, height: height, fps: fps, framesPerImage: [frames], to: url)
        return url
    }

    /// Adds an AAC tone to a clip so audio policy can be checked on real decoded tracks.
    static func withTone(_ video: URL, seconds: Double, in directory: URL, name: String) async throws -> URL {
        let toneURL = directory.appending(path: "\(name)-tone.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: toneURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            let count = AVAudioFrameCount(seconds * 44_100)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
            buffer.frameLength = count
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<Int(count) { samples[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 44_100) * 0.3) }
            try file.write(from: buffer)
        }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: toneURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video), audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first), audioTrack = try XCTUnwrap(audioTracks.first)
        let range = try await videoTrack.load(.timeRange)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(range, of: videoTrack, at: .zero)
        let audioRange = CMTimeRangeGetIntersection(try await audioTrack.load(.timeRange), otherRange: range)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(audioRange, of: audioTrack, at: .zero)
        let output = directory.appending(path: "\(name).mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: output, as: .mov)
        return output
    }

    /// Creates a clip with multiple audio tracks by compositing two toned sources.
    static func withMultipleAudioTracks(_ video: URL, secondsPerTrack: Double, in directory: URL, name: String) async throws -> URL {
        let tone1URL = directory.appending(path: "\(name)-tone1.m4a")
        let tone2URL = directory.appending(path: "\(name)-tone2.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))

        for (url, frequency) in [(tone1URL, 440.0), (tone2URL, 880.0)] {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            let count = AVAudioFrameCount(secondsPerTrack * 44_100)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
            buffer.frameLength = count
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for i in 0..<Int(count) { samples[i] = Float(sin(2 * Double.pi * frequency * Double(i) / 44_100) * 0.3) }
            try file.write(from: buffer)
        }

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset1 = AVURLAsset(url: tone1URL), audioAsset2 = AVURLAsset(url: tone2URL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let range = try await videoTrack.load(.timeRange)

        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(range, of: videoTrack, at: .zero)

        for audioAsset in [audioAsset1, audioAsset2] {
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            if let audioTrack = audioTracks.first {
                let audioRange = CMTimeRangeGetIntersection(try await audioTrack.load(.timeRange), otherRange: range)
                try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(audioRange, of: audioTrack, at: .zero)
            }
        }

        let output = directory.appending(path: "\(name).mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: output, as: .mov)
        return output
    }

    static func close(_ rgb: [Int], _ expected: (Int, Int, Int), tolerance: Int = 28) -> Bool {
        rgb.count == 3 && abs(rgb[0] - expected.0) <= tolerance && abs(rgb[1] - expected.1) <= tolerance && abs(rgb[2] - expected.2) <= tolerance
    }

    static func edge(_ source: StudioNode, _ output: String, _ target: StudioNode, _ input: String, _ type: PortDataType) -> StudioEdge {
        .init(sourceID: source.id, sourcePortID: output, targetID: target.id, targetPortID: input, type: type)
    }

    static var verifiedRegistry: [VideoCapability] { [VideoCapabilityRegistry.wanTextToVideo.with(readiness: .verified(evidence: "test registry"))] }
}

/// Returns a pre-encoded clip in place of inference. Used only to test executor wiring, never as generation proof.
actor FixtureVideoEngine: VideoGenerationEngine {
    enum Behaviour: Sendable { case succeed(URL), fail, waitForCancellation }
    let behaviour: Behaviour
    private(set) var requests: [VideoGenerationRequest] = []
    init(_ behaviour: Behaviour) { self.behaviour = behaviour }
    func captured() -> [VideoGenerationRequest] { requests }
    func generate(_ request: VideoGenerationRequest) async throws -> GeneratedVideo {
        requests.append(request)
        switch behaviour {
        case .fail: throw StudioError.validation("fixture engine failure")
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60)); throw StudioError.timedOut
        case .succeed(let template):
            let copy = template.deletingLastPathComponent().appending(path: "\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: template, to: copy)
            return .init(url: copy, probe: try await VideoProbe.inspect(copy), elapsedSeconds: 0.01, logTail: "fixture")
        }
    }
}
