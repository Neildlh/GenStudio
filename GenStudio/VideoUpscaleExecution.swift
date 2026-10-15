import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bounded, sequential, frame-based video upscaling. Each frame reuses NativeUpscaleEngine unchanged; this
/// file only handles exact-timestamp extraction, per-frame sequencing, timestamp-preserving re-encoding and
/// audio muxing. There is no temporal model here — see NodeKind.videoUpscale's detail text.
enum VideoUpscaleBounds {
    /// Cap on total job length, not on process launches.
    ///
    /// The previous rationale — that each frame reloads the model from disk — was measured and is
    /// wrong: model loading is 0.20 s per frame while the Real-ESRGAN compute is 10.15 s, so process
    /// launch and model load together are about 9% of per-frame cost. Batching frames into one
    /// process would therefore recover very little, and the cap should be justified by wall time.
    ///
    /// Measured on Apple M1 Max / 64 GB, 18 Sep 2026 (docs/evidence/video-benchmark-m1max-2026-09-18.md):
    /// 320 × 192 → 1280 × 768 at 4× costs 11.15 s per frame, consistently (10.83–11.63 s over nine
    /// frames). 120 frames is therefore roughly 22 minutes, and covers the five-second social target
    /// at 24 fps that PRODUCT.md describes. Larger jobs are refused with their estimated duration
    /// rather than a flat number, so the limit is legible instead of arbitrary.
    static let maximumFrames = 120
    /// Measured seconds per frame for a 4× upscale, used only to make the refusal message
    /// predictive. Actual cost scales with source resolution.
    static let measuredSecondsPerFrame = 11.15
}

/// A decoded source frame's exact original presentation time; never resampled to a synthesized fixed-fps
/// grid (unlike MediaProcessor.extractVideoFrames, which intentionally resamples for reference-video adapters).
enum ExactFrameExtractor {
    struct Frame { let url: URL; let time: CMTime }
    struct Result { let frames: [Frame]; let width: Int; let height: Int; let hasAudio: Bool; let duration: CMTime; let nominalFPS: Double }

    /// Single decode pass: applies the track's own preferredTransform to each raw decoded pixel buffer
    /// (the same orientation-correction math MediaProcessing.rotateFlip uses), so orientation is exact
    /// without a second AVAssetImageGenerator pass. Aborts the moment the frame bound is exceeded so an
    /// oversized clip never pays for a full decode.
    static func extract(_ url: URL, maxFrames: Int, into directory: URL) async throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.validation("\(url.lastPathComponent) has no video track.") }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let display = try DisplayGeometry.resolve(size: size, transform: transform, source: url.lastPathComponent)
        let duration = try await asset.load(.duration)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StudioError.validation("\(url.lastPathComponent) cannot be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw StudioError.validation("\(url.lastPathComponent) cannot be decoded: \(reader.error?.localizedDescription ?? "")") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = Int(abs(display.width).rounded()), height = Int(abs(display.height).rounded())
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if frames.count >= maxFrames {
                reader.cancelReading()
                let estimate = Int((Double(maxFrames) * VideoUpscaleBounds.measuredSecondsPerFrame / 60).rounded())
                // String(format:) rather than .formatted(): this is a technical rate, and the
                // locale-aware formatter renders it "11,2" in comma-decimal locales.
                let rate = String(format: "%.1f", VideoUpscaleBounds.measuredSecondsPerFrame)
                throw StudioError.validation("This clip has more than \(maxFrames) frames. Video Upscale enlarges each frame separately at about \(rate) seconds per frame, so \(maxFrames) frames already takes roughly \(estimate) minutes — shorten the clip or lower its frame rate before retrying.")
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            var image = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            guard let cgImage = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
                throw StudioError.validation("Could not render decoded frame \(frames.count).")
            }
            let frameURL = directory.appending(path: String(format: "frame_%06d.png", frames.count))
            guard let destination = CGImageDestinationCreateWithURL(frameURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw StudioError.persistence("Could not create a frame artifact.") }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { throw StudioError.persistence("A frame artifact could not be validated.") }
            frames.append(.init(url: frameURL, time: time))
        }
        guard reader.status == .completed else { throw StudioError.validation("\(url.lastPathComponent) failed to decode: \(reader.error?.localizedDescription ?? "incomplete")") }
        guard !frames.isEmpty else { throw StudioError.validation("\(url.lastPathComponent) contains no decodable frames.") }
        return .init(frames: frames, width: width, height: height, hasAudio: hasAudio, duration: duration, nominalFPS: Double(rate))
    }
}

/// Re-encodes frames at their exact original presentation timestamps (normalized to start at zero), never a
/// synthesized fixed-fps grid — the fix for the frame-timing problem recorded in ENGINEERING_RESULT.md.
enum TimestampedFrameSequenceEncoder {
    static func encode(frames: [ExactFrameExtractor.Frame], width: Int, height: Int, duration: CMTime, to output: URL) async throws {
        guard !frames.isEmpty, width >= 16, height >= 16, width <= 16_384, height <= 16_384, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw StudioError.validation("Video encoding needs at least one frame and even dimensions from 16 to 16,384 pixels.")
        }
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 12), AVVideoAllowFrameReorderingKey: false]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw StudioError.validation("The video writer rejected the H.264 settings.") }
        writer.add(input)
        guard writer.startWriting() else { throw StudioError.validation("Could not start video encoding: \(writer.error?.localizedDescription ?? "unknown error")") }
        writer.startSession(atSourceTime: .zero)
        var succeeded = false
        defer { if !succeeded { writer.cancelWriting(); try? FileManager.default.removeItem(at: output) } }
        let origin = frames[0].time
        for frame in frames {
            try Task.checkCancellation()
            let buffer = try FrameSequenceEncoder.pixelBuffer(for: .file(frame.url), width: width, height: height)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw StudioError.validation("Video encoding failed: \(writer.error?.localizedDescription ?? "writer stopped")") }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(buffer, withPresentationTime: frame.time - origin) else {
                throw StudioError.validation("Video encoding failed at \(frame.time.seconds)s: \(writer.error?.localizedDescription ?? "append rejected")")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: duration - origin)
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.validation("Video encoding did not complete: \(writer.error?.localizedDescription ?? "unknown error")") }
        try Task.checkCancellation()
        succeeded = true
    }
}

struct VideoUpscaleOutput: Sendable { let url: URL; let probe: VideoProbe }

struct VideoUpscaleRunner: Sendable {
    let engine: any ImageUpscaleEngine
    let capabilities: [UpscaleCapability]
    let scratchRoot: URL

    func run(recipeID: String, scale: Int, tileSize: Int, allowsUnverifiedLocalRun: Bool, sourceVideo: URL) async throws -> VideoUpscaleOutput {
        _ = try UpscaleRequestPlanner.validateSettings(recipeID: recipeID, scale: scale, tileSize: tileSize, registry: capabilities)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        let staging = scratchRoot.appending(path: "video-upscale-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        GenerationProgressContext.report?(.init(stage: "Extracting frames"))
        let extracted = try await ExactFrameExtractor.extract(sourceVideo, maxFrames: VideoUpscaleBounds.maximumFrames, into: staging.appending(path: "source"))
        if extracted.hasAudio {
            let audioTrackCount = try await AVURLAsset(url: sourceVideo).loadTracks(withMediaType: .audio).count
            guard audioTrackCount <= 1 else { throw StudioError.validation("This clip has \(audioTrackCount) audio tracks. Video Upscale supports one audio track; mix the audio first.") }
        }

        let upscaledDirectory = staging.appending(path: "upscaled", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: upscaledDirectory, withIntermediateDirectories: true)
        var upscaledFrames: [ExactFrameExtractor.Frame] = []
        let total = extracted.frames.count
        for (index, frame) in extracted.frames.enumerated() {
            try Task.checkCancellation()
            GenerationProgressContext.report?(.init(stage: "Upscaling frame \(index + 1) of \(total)"))
            let identity = try MediaIdentity.of(frame.url)
            let (request, _) = try UpscaleRequestPlanner.makeRequest(recipeID: recipeID, scale: scale, tileSize: tileSize, sourceWidth: extracted.width, sourceHeight: extracted.height, registry: capabilities, allowsUnverifiedLocalRun: allowsUnverifiedLocalRun, sourceImage: frame.url, sourceIdentity: identity)
            let upscaled = try await engine.upscale(request)
            let moved = upscaledDirectory.appending(path: String(format: "frame_%06d.png", index))
            try FileManager.default.moveItem(at: upscaled, to: moved)
            upscaledFrames.append(.init(url: moved, time: frame.time))
        }

        let finalWidth = extracted.width * scale, finalHeight = extracted.height * scale
        let videoOnly = staging.appending(path: "video-only.mov")
        GenerationProgressContext.report?(.init(stage: "Encoding upscaled video"))
        try await TimestampedFrameSequenceEncoder.encode(frames: upscaledFrames, width: finalWidth, height: finalHeight, duration: extracted.duration, to: videoOnly)
        try Task.checkCancellation()

        let output = scratchRoot.appending(path: "\(UUID().uuidString).mov")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: output) } }
        if extracted.hasAudio {
            GenerationProgressContext.report?(.init(stage: "Muxing audio"))
            try await Self.mux(video: videoOnly, audioFrom: sourceVideo, to: output)
        } else {
            try FileManager.default.copyItem(at: videoOnly, to: output)
        }
        try Task.checkCancellation()
        let probe = try await VideoProbe.inspect(output)
        let expectedDuration = extracted.duration.seconds
        let tolerance = max(0.5 / max(extracted.nominalFPS, 1), 0.05)
        guard probe.width == finalWidth, probe.height == finalHeight, probe.frameCount == total,
              abs(probe.duration - expectedDuration) <= tolerance, probe.hasAudio == extracted.hasAudio else {
            throw StudioError.validation("Upscaled video validation failed: expected \(finalWidth)×\(finalHeight), \(total) frames, \(expectedDuration)s, audio \(extracted.hasAudio); decoded \(probe.width)×\(probe.height), \(probe.frameCount) frames, \(probe.duration)s, audio \(probe.hasAudio).")
        }
        success = true
        return .init(url: output, probe: probe)
    }

    /// Straight audio copy at the identical time range: upscaling never changes duration, so no rescale is
    /// needed. Mirrors ClipAssembler's proven single-clip audio-copy placement exactly.
    static func mux(video: URL, audioFrom source: URL, to output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: source)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else { throw StudioError.validation("The upscaled video has no video track.") }
        let videoRange = try await videoTrack.load(.timeRange)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw StudioError.validation("The source audio track is missing.") }
        let audioRange = try await audioTrack.load(.timeRange)
        let usable = CMTimeRangeGetIntersection(audioRange, otherRange: videoRange)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?.insertTimeRange(usable, of: audioTrack, at: usable.start - videoRange.start)
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw StudioError.validation("Could not create the export session.") }
        try await session.export(to: output, as: .mov)
    }
}
