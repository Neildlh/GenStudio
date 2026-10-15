import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

enum FrameSource: Sendable { case file(URL) }

/// Shared guard against non-finite or zero-area display geometry from a possibly malformed asset,
/// so downstream Double-to-Int conversions and scale divisions never trap or divide by zero.
enum DisplayGeometry {
    static func resolve(size: CGSize, transform: CGAffineTransform, source: String) throws -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw StudioError.validation("\(source) has invalid video dimensions.")
        }
        let display = CGRect(origin: .zero, size: size).applying(transform)
        guard display.width.isFinite, display.height.isFinite, display.width != 0, display.height != 0 else {
            throw StudioError.validation("\(source) has a degenerate display transform.")
        }
        return display
    }
}

/// Encodes still images into H.264 with AVAssetWriter. Composition alone cannot turn images into video.
enum FrameSequenceEncoder {
    /// `framesPerImage` repeats each source for that many output frames; nil means one frame per source.
    static func encode(frames: [FrameSource], width: Int, height: Int, fps: Int, framesPerImage: [Int]?, to output: URL) async throws {
        guard !frames.isEmpty else {
            throw StudioError.validation("Video encoding needs at least one frame, even dimensions from 16 to 4096 pixels and 1–120 fps.")
        }
        let counts = framesPerImage ?? Array(repeating: 1, count: frames.count)
        guard counts.count == frames.count, counts.allSatisfy({ $0 > 0 }) else { throw StudioError.validation("Every still must occupy at least one frame.") }
        var sourceForFrame: [Int] = []
        for (index, count) in counts.enumerated() {
            guard sourceForFrame.count + count <= 36_000 else { throw StudioError.validation("Encoded clips are limited to 36,000 frames.") }
            sourceForFrame += Array(repeating: index, count: count)
        }
        var cached: (source: Int, buffer: CVPixelBuffer)?
        try await encode(frameCount: sourceForFrame.count, width: width, height: height, fps: fps, to: output) { frame in
            let source = sourceForFrame[frame]
            if let cached, cached.source == source { return cached.buffer }
            let buffer = try pixelBuffer(for: frames[source], width: width, height: height)
            cached = (source, buffer)
            return buffer
        }
    }

    /// Encodes `frameCount` frames supplied in order by `buffer`; returning the same buffer again repeats a frame
    /// without redrawing it.
    static func encode(frameCount: Int, width: Int, height: Int, fps: Int, to output: URL, buffer: (Int) throws -> CVPixelBuffer) async throws {
        guard frameCount > 0, width >= 16, height >= 16, width <= 4096, height <= 4096, width.isMultiple(of: 2), height.isMultiple(of: 2), (1...120).contains(fps) else {
            throw StudioError.validation("Video encoding needs at least one frame, even dimensions from 16 to 4096 pixels and 1–120 fps.")
        }
        guard frameCount <= 36_000 else { throw StudioError.validation("Encoded clips are limited to 36,000 frames.") }
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(2_000_000, width * height * 12), AVVideoAllowFrameReorderingKey: false, AVVideoMaxKeyFrameIntervalKey: fps]
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
        for frameIndex in 0..<frameCount {
            try Task.checkCancellation()
            let frame = try buffer(frameIndex)
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw StudioError.validation("Video encoding failed: \(writer.error?.localizedDescription ?? "writer stopped")") }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: CMTimeScale(fps))) else {
                throw StudioError.validation("Video encoding failed at frame \(frameIndex): \(writer.error?.localizedDescription ?? "append rejected")")
            }
        }
        input.markAsFinished()
        // Duration is the sample count over fps; the last frame starts one frame earlier.
        writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: CMTimeScale(fps)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.validation("Video encoding did not complete: \(writer.error?.localizedDescription ?? "unknown error")") }
        try Task.checkCancellation()
        succeeded = true
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int, w * h <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary) else {
            throw StudioError.validation("Image \(url.lastPathComponent) cannot be decoded.")
        }
        return image
    }

    /// Aspect-fits the still onto a black frame; nothing is cropped or stretched.
    static func pixelBuffer(for source: FrameSource, width: Int, height: Int) throws -> CVPixelBuffer {
        guard case .file(let url) = source else { throw StudioError.validation("Unsupported frame source.") }
        let image = try loadImage(url)
        return try pixelBuffer(width: width, height: height) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
            let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }

    /// A BGRA frame drawn by `draw` in the same ITU-R BT.709 space the encoder tags the output with (see
    /// AVVideoColorPropertiesKey above), so the pixel bytes CoreGraphics produces match the declared colour space.
    static func pixelBuffer(width: Int, height: Int, draw: (CGContext) throws -> Void) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess, let buffer = created else {
            throw StudioError.validation("Could not allocate a video frame.")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw StudioError.validation("Could not draw a video frame.")
        }
        try draw(context)
        return buffer
    }
}

/// Facts obtained by actually decoding every video frame.
struct VideoProbe: Codable, Hashable, Sendable {
    struct Frame: Codable, Hashable, Sendable {
        let time: Double
        /// Mean BGRA-decoded RGB of the central 5×5 pixels.
        let centerRGB: [Int]
    }
    let width: Int
    let height: Int
    let duration: Double
    let nominalFPS: Double
    let frameCount: Int
    let distinctFrameCount: Int
    let hasAudio: Bool
    var frames: [Frame]
    var lastFrameTimestamp: Double { frames.last?.time ?? 0 }

    /// The AVAssetReader decode loop below retains one entry per frame; this bounds memory and runtime
    /// for pathologically long inputs. ClipAssembler checks its own aggregate estimate against this
    /// same limit before exporting, so a too-long assembly fails fast instead of after a full export.
    static let frameLimit = 40_000

    static func inspect(_ url: URL, frameLimit: Int = VideoProbe.frameLimit) async throws -> VideoProbe {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw StudioError.validation("Video \(url.lastPathComponent) is not readable.") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.validation("\(url.lastPathComponent) has no video track.") }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let display = try DisplayGeometry.resolve(size: size, transform: transform, source: url.lastPathComponent)
        let duration = try await asset.load(.duration).seconds
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw StudioError.validation("\(url.lastPathComponent) cannot be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw StudioError.validation("\(url.lastPathComponent) cannot be decoded: \(reader.error?.localizedDescription ?? "")") }
        var frames: [Frame] = [], signatures = Set<Int>()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image), row = CVPixelBufferGetBytesPerRow(image)
            guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { continue }
            var sum = [0, 0, 0], n = 0
            for y in max(0, h / 2 - 2)...min(h - 1, h / 2 + 2) { for x in max(0, w / 2 - 2)...min(w - 1, w / 2 + 2) {
                let p = base + y * row + x * 4; sum[0] += Int(p[2]); sum[1] += Int(p[1]); sum[2] += Int(p[0]); n += 1
            } }
            var hasher = Hasher()
            for y in Swift.stride(from: 0, to: h, by: max(1, h / 16)) { for x in Swift.stride(from: 0, to: w, by: max(1, w / 16)) { hasher.combine(base[y * row + x * 4 + 1] / 8) } }
            signatures.insert(hasher.finalize())
            frames.append(.init(time: time, centerRGB: sum.map { $0 / max(n, 1) }))
            guard frames.count <= frameLimit else { reader.cancelReading(); throw StudioError.validation("\(url.lastPathComponent) exceeds the \(frameLimit)-frame validation limit.") }
        }
        guard reader.status == .completed else { throw StudioError.validation("\(url.lastPathComponent) failed to decode: \(reader.error?.localizedDescription ?? "incomplete")") }
        guard !frames.isEmpty else { throw StudioError.validation("\(url.lastPathComponent) contains no decodable frames.") }
        return .init(width: Int(abs(display.width).rounded()), height: Int(abs(display.height).rounded()), duration: duration, nominalFPS: Double(rate), frameCount: frames.count, distinctFrameCount: signatures.count, hasAudio: hasAudio, frames: frames.sorted { $0.time < $1.time })
    }
}

enum AnimaticRenderer {
    /// Deterministic hard cuts: each anchor fills exactly its resolved frame range. No generated motion.
    static func render(_ sequence: ResolvedShotSequence, to output: URL) async throws -> VideoProbe {
        guard sequence.anchors.count == sequence.timing.anchors.count, zip(sequence.anchors, sequence.timing.anchors).allSatisfy({ $0.anchorID == $1.anchorID }) else {
            throw StudioError.validation("Animatic timing does not match the sequence frames.")
        }
        try await FrameSequenceEncoder.encode(frames: sequence.anchors.map { .file($0.image) }, width: sequence.width, height: sequence.height, fps: sequence.timing.fps, framesPerImage: sequence.timing.anchors.map(\.frameCount), to: output)
        let probe = try await VideoProbe.inspect(output)
        guard probe.frameCount == sequence.timing.frameCount, probe.width == sequence.width, probe.height == sequence.height,
              abs(probe.duration - sequence.timing.duration) < 0.5 / Double(sequence.timing.fps) else {
            try? FileManager.default.removeItem(at: output)
            throw StudioError.validation("Animatic validation failed: expected \(sequence.timing.frameCount) frames over \(sequence.timing.duration) s, decoded \(probe.frameCount) frames over \(probe.duration) s.")
        }
        return probe
    }
}
