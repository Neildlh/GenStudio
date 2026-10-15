import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import RifeMetal
import UniformTypeIdentifiers

enum VideoFinishingBounds {
    static let maximumInputFrames = 300
    static let maximumOutputFrames = 900
}

struct FrameInterpolationOutput: Sendable { let url: URL; let probe: VideoProbe }

/// Converts a low diffusion frame rate into a delivery frame rate with native Metal RIFE.
/// Source frames remain exact; only timestamps between source samples invoke the network.
struct FrameInterpolationRunner: @unchecked Sendable {
    let scratchRoot: URL

    func run(sourceVideo: URL, targetFPS: Int) async throws -> FrameInterpolationOutput {
        guard (12...60).contains(targetFPS) else { throw StudioError.validation("Delivery frame rate must be 12–60 fps.") }
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let staging = scratchRoot.appending(path: "frame-interpolate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        GenerationProgressContext.report?(.init(stage: "Extracting source frames"))
        let extracted = try await ExactFrameExtractor.extract(sourceVideo, maxFrames: VideoFinishingBounds.maximumInputFrames, into: staging.appending(path: "source"))
        guard targetFPS > Int(extracted.nominalFPS.rounded()) else {
            throw StudioError.validation("Frame Interpolation must raise the frame rate. The source is about \(Int(extracted.nominalFPS.rounded())) fps; choose a higher delivery rate.")
        }
        let outputCount = max(1, Int((extracted.duration.seconds * Double(targetFPS)).rounded()))
        guard outputCount <= VideoFinishingBounds.maximumOutputFrames else {
            throw StudioError.validation("Interpolation would create \(outputCount) frames, over the \(VideoFinishingBounds.maximumOutputFrames)-frame local safety limit. Shorten the clip.")
        }
        let outputDirectory = staging.appending(path: "interpolated", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let interpolator = try RifeInterpolator(configuration: .bundled(qualityTier: .balanced))
        let images = try extracted.frames.map { frame -> CGImage in
            guard let source = CGImageSourceCreateWithURL(frame.url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw StudioError.validation("Could not decode \(frame.url.lastPathComponent) for interpolation.")
            }
            return image
        }
        let times = extracted.frames.map { $0.time.seconds - extracted.frames[0].time.seconds }
        var outputs: [FrameSource] = []
        for index in 0..<outputCount {
            try Task.checkCancellation()
            let targetTime = Double(index) / Double(targetFPS)
            let upper = times.firstIndex(where: { $0 >= targetTime }) ?? (times.count - 1)
            let lower = max(0, upper - 1)
            let image: CGImage
            if upper == lower || abs(times[upper] - targetTime) < 0.000_1 {
                image = images[upper]
            } else {
                let span = times[upper] - times[lower]
                let t = min(1, max(0, (targetTime - times[lower]) / max(span, 0.000_001)))
                if t <= 0.000_1 { image = images[lower] }
                else if t >= 0.999_9 { image = images[upper] }
                else { image = try interpolator.interpolate(previous: images[lower], current: images[upper], timesteps: [Float(t)])[0] }
            }
            let url = outputDirectory.appending(path: String(format: "frame_%06d.png", index))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw StudioError.persistence("Could not create an interpolated frame.") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw StudioError.persistence("Could not write an interpolated frame.") }
            outputs.append(.file(url))
            GenerationProgressContext.report?(.init(stage: "Interpolating frame \(index + 1) of \(outputCount)"))
        }
        let videoOnly = staging.appending(path: "video-only.mov")
        try await FrameSequenceEncoder.encode(frames: outputs, width: extracted.width, height: extracted.height, fps: targetFPS, framesPerImage: nil, to: videoOnly)
        let output = scratchRoot.appending(path: "\(UUID().uuidString).mov")
        if extracted.hasAudio { try await VideoUpscaleRunner.mux(video: videoOnly, audioFrom: sourceVideo, to: output) }
        else { try FileManager.default.copyItem(at: videoOnly, to: output) }
        let probe = try await VideoProbe.inspect(output)
        guard probe.width == extracted.width, probe.height == extracted.height, probe.frameCount == outputCount else {
            try? FileManager.default.removeItem(at: output)
            throw StudioError.validation("Interpolated video failed output validation.")
        }
        return .init(url: output, probe: probe)
    }
}

/// Delivery shapes for social video. Nil on a saved node means vertical, the original behaviour.
enum DeliveryFormat: String, Codable, CaseIterable, Sendable {
    case vertical, feed, square, landscape
    var width: Int { self == .landscape ? 1920 : 1080 }
    var height: Int { switch self { case .vertical: 1920; case .feed: 1350; case .square, .landscape: 1080 } }
    var title: String {
        switch self {
        case .vertical: "9:16 · Reels, Stories, TikTok, WhatsApp Status"
        case .feed: "4:5 · Instagram and Facebook feed"
        case .square: "1:1 · Square post"
        case .landscape: "16:9 · YouTube, website"
        }
    }
}

enum InstagramReelExporter {
    /// Reels, Facebook and WhatsApp all accept 24, 25 and 30 fps, so a source at one of those rates keeps it:
    /// re-timing 24 fps to 30 would only duplicate frames. Lower draft rates need real interpolated frames first.
    static func deliveryFPS(sourceFPS: Double) -> Int? {
        [24, 25, 30].first { abs(sourceFPS - Double($0)) < 0.6 }
    }

    static func run(sourceVideo: URL, scratchRoot: URL, fps: Int = 30, format: DeliveryFormat = .vertical) async throws -> URL {
        let asset = AVURLAsset(url: sourceVideo)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.validation("Instagram Export needs a video track.") }
        let (naturalSize, preferredTransform, timeRange) = try await sourceTrack.load(.naturalSize, .preferredTransform, .timeRange)
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let sourceWidth = abs(transformed.width), sourceHeight = abs(transformed.height)
        guard sourceWidth > 0, sourceHeight > 0 else { throw StudioError.validation("The source video has invalid display dimensions.") }
        let renderSize = CGSize(width: format.width, height: format.height)
        let scale = max(renderSize.width / sourceWidth, renderSize.height / sourceHeight)
        var transform = preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let scaled = CGRect(origin: .zero, size: naturalSize).applying(transform)
        transform = transform.concatenating(CGAffineTransform(translationX: (renderSize.width - scaled.width) / 2 - scaled.minX, y: (renderSize.height - scaled.height) / 2 - scaled.minY))
        var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: sourceTrack)
        layerConfiguration.setTransform(transform, at: .zero)
        let layer = AVVideoCompositionLayerInstruction(configuration: layerConfiguration)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [layer],
            timeRange: timeRange
        ))
        let composition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            instructions: [instruction],
            renderSize: renderSize
        ))
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let output = scratchRoot.appending(path: "\(UUID().uuidString).mov")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError.validation("Could not create Instagram export session.") }
        session.videoComposition = composition
        // Sound ends with the picture.
        session.timeRange = CMTimeRange(start: .zero, end: timeRange.end)
        try await session.export(to: output, as: .mov)
        let probe = try await VideoProbe.inspect(output)
        guard probe.width == format.width, probe.height == format.height else { try? FileManager.default.removeItem(at: output); throw StudioError.validation("Export did not produce \(format.width)×\(format.height) video.") }
        return output
    }
}
