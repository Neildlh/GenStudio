import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The normalized-rectangle rule the crop node enforces, shared so the inspector can explain it before a run fails.
enum CropBounds {
    /// Absorbs binary rounding such as 0.7 + 0.3 landing a hair above 1.
    private static let tolerance = 1e-9
    static func issue(x: Double, y: Double, width: Double, height: Double) -> String? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return "Crop values must be numbers." }
        guard x >= 0, y >= 0 else { return "X and Y cannot be negative." }
        guard width > 0, height > 0 else { return "Width and Height must be greater than 0." }
        guard x + width <= 1 + tolerance else { return "X + Width is \((x + width).formatted(.number.precision(.fractionLength(0...3)))); it must not exceed 1." }
        guard y + height <= 1 + tolerance else { return "Y + Height is \((y + height).formatted(.number.precision(.fractionLength(0...3)))); it must not exceed 1." }
        return nil
    }
}

actor MediaProcessor {
    private let artifacts: URL
    init(root: URL) { artifacts = root.appending(path: "Artifacts", directoryHint: .isDirectory) }

    func validateImage(_ url: URL) throws -> CGImage {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight)] as CFDictionary) else {
            throw StudioError.validation("The selected image cannot be decoded.")
        }
        return image
    }

    func validateVideo(_ url: URL) async throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw StudioError.validation("The selected video is not readable.") }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw StudioError.validation("The selected file has no playable video track.") }
    }

    func resize(_ url: URL, width: Int, height: Int) throws -> URL {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 67_108_864 else { throw StudioError.validation("Resize dimensions must be positive and no larger than 67 megapixels or 16,384 pixels per side.") }
        let image = try validateImage(url)
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StudioError.validation("Could not create the resize canvas.") }
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw StudioError.validation("Resize produced no pixels.") }
        return try writePNG(output)
    }

    /// Scales to cover width × height, center-crops the overflow and drops alpha. Used to prepare start and init images
    /// so an adapter never receives an image whose size differs from the requested output.
    func aspectFill(_ url: URL, width: Int, height: Int) throws -> URL {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw StudioError.validation("Prepared image size must be 1–4096 pixels per side.") }
        let image = try validateImage(url)
        guard image.width > 0, image.height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw StudioError.validation("Could not create the image preparation canvas.") }
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        guard let output = context.makeImage() else { throw StudioError.validation("Image preparation produced no pixels.") }
        return try writePNG(output)
    }

    func crop(_ url: URL, x: Double, y: Double, width: Double, height: Double) throws -> URL {
        if let problem = CropBounds.issue(x: x, y: y, width: width, height: height) { throw StudioError.validation("Crop bounds are outside the image. \(problem)") }
        let image = try validateImage(url)
        let rect = CGRect(x: Double(image.width) * x, y: Double(image.height) * y, width: Double(image.width) * width, height: Double(image.height) * height).integral
        guard let output = image.cropping(to: rect), output.width > 0, output.height > 0 else { throw StudioError.validation("Crop produced no pixels.") }
        return try writePNG(output)
    }

    func blend(background: URL, foreground: URL, opacity: Double) throws -> URL {
        guard opacity.isFinite, (0...1).contains(opacity) else { throw StudioError.validation("Blend opacity must be finite and between zero and one.") }
        let bg = try validateImage(background), fg = try validateImage(foreground)
        guard bg.width == fg.width, bg.height == fg.height else { throw StudioError.validation("Blend images must have matching pixel dimensions.") }
        let backgroundImage = CIImage(cgImage: bg), foregroundImage = CIImage(cgImage: fg)
        let adjusted = foregroundImage.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
        let result = adjusted.composited(over: backgroundImage)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        guard let output = context.createCGImage(result, from: backgroundImage.extent, format: .RGBA8, colorSpace: colorSpace) else { throw StudioError.validation("Blend produced no pixels.") }
        return try writePNG(output)
    }

    func rotateFlip(_ url: URL, quarterTurns: Int, horizontal: Bool, vertical: Bool) throws -> URL {
        guard (0...3).contains(quarterTurns) else { throw StudioError.validation("Rotation must be 0, 90, 180 or 270 degrees.") }
        var image = CIImage(cgImage: try validateImage(url))
        image = image.transformed(by: CGAffineTransform(scaleX: horizontal ? -1 : 1, y: vertical ? -1 : 1))
        // Integer matrices avoid sin/cos residue expanding rectangular bounds by one pixel.
        let rotation: CGAffineTransform = switch quarterTurns {
        case 1: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 3: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        default: .identity
        }
        image = image.transformed(by: rotation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        return try render(image, bounds: image.extent.integral)
    }
    func blur(_ url: URL, radius: Double) throws -> URL {
        guard radius.isFinite, (0...100).contains(radius) else { throw StudioError.validation("Blur radius must be between 0 and 100 pixels.") }
        let image = CIImage(cgImage: try validateImage(url))
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
        return try render(blurred, bounds: image.extent)
    }
    func invert(_ url: URL) throws -> URL {
        let image = CIImage(cgImage: try validateImage(url))
        return try render(image.applyingFilter("CIColorInvert"), bounds: image.extent)
    }

    /// Matches the generated image's CIE Lab channel means and standard deviations to a source image.
    /// This is the global statistical colour-transfer method described by Reinhard et al. (2001): it
    /// adjusts colour and tonal distribution without requiring pixels in the two images to correspond.
    /// Fully transparent pixels do not influence the analysis and every output pixel retains its original
    /// alpha, so the operation is safe for rendered assets with transparency.
    func colourCorrect(source: URL, generated: URL) throws -> URL {
        let sourceImage = try validateImage(source)
        let generatedImage = try validateImage(generated)
        guard generatedImage.width > 0, generatedImage.height > 0,
              generatedImage.width * generatedImage.height <= 67_108_864 else {
            throw StudioError.validation("Colour Correct requires an image no larger than 67 megapixels.")
        }
        // This global operation needs only representative source statistics. Capping that analysis avoids
        // a second full-resolution bitmap allocation when a very large reference is connected.
        let sourceSample = try rgba8(sourceImage, maximumDimension: 2_048)
        let target = try rgba8(generatedImage)
        let sourceStatistics = try labStatistics(sourceSample.bytes)
        let targetStatistics = try labStatistics(target.bytes)
        guard let outputContext = CGContext(data: nil, width: target.width, height: target.height,
                                            bitsPerComponent: 8, bytesPerRow: target.width * 4,
                                            space: target.colorSpace,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let outputBytes = outputContext.data?.assumingMemoryBound(to: UInt8.self) else {
            throw StudioError.validation("Could not create the Colour Correct output canvas.")
        }

        for offset in stride(from: 0, to: target.bytes.count, by: 4) {
            let alpha = Double(target.bytes[offset + 3]) / 255
            guard alpha > 0 else {
                outputBytes[offset] = 0; outputBytes[offset + 1] = 0; outputBytes[offset + 2] = 0; outputBytes[offset + 3] = 0
                continue
            }
            let lab = Lab.fromSRGB(red: Double(target.bytes[offset]) / 255 / alpha,
                                   green: Double(target.bytes[offset + 1]) / 255 / alpha,
                                   blue: Double(target.bytes[offset + 2]) / 255 / alpha)
            let corrected = Lab(l: remap(lab.l, from: targetStatistics.l, to: sourceStatistics.l),
                                a: remap(lab.a, from: targetStatistics.a, to: sourceStatistics.a),
                                b: remap(lab.b, from: targetStatistics.b, to: sourceStatistics.b)).sRGB
            outputBytes[offset] = byte(corrected.red * alpha)
            outputBytes[offset + 1] = byte(corrected.green * alpha)
            outputBytes[offset + 2] = byte(corrected.blue * alpha)
            outputBytes[offset + 3] = target.bytes[offset + 3]
        }
        guard let output = outputContext.makeImage() else { throw StudioError.validation("Colour Correct produced no pixels.") }
        return try writePNG(output)
    }

    private struct RGBA8 { let bytes: [UInt8]; let width: Int; let height: Int; let colorSpace: CGColorSpace }
    private struct ChannelStatistics { let mean: Double; let standardDeviation: Double }
    private struct LabStatistics { let l: ChannelStatistics; let a: ChannelStatistics; let b: ChannelStatistics }
    private struct Lab {
        var l: Double; var a: Double; var b: Double
        var sRGB: (red: Double, green: Double, blue: Double) {
            let fy = (l + 16) / 116, fx = a / 500 + fy, fz = fy - b / 200
            let xyz = (x: 0.95047 * Lab.labInverse(fx), y: Lab.labInverse(fy), z: 1.08883 * Lab.labInverse(fz))
            let linear = (red: 3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
                          green: -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
                          blue: 0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z)
            return (Lab.encode(linear.red), Lab.encode(linear.green), Lab.encode(linear.blue))
        }
        static func fromSRGB(red: Double, green: Double, blue: Double) -> Lab {
            let r = decode(red), g = decode(green), b = decode(blue)
            let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
            let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
            let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
            let fx = labForward(x), fy = labForward(y), fz = labForward(z)
            return .init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
        }
        private static func decode(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        private static func encode(_ value: Double) -> Double { let value = min(1, max(0, value)); return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055 }
        private static func labForward(_ value: Double) -> Double { value > 0.008856451679 ? pow(value, 1 / 3) : 7.787037037 * value + 16 / 116 }
        private static func labInverse(_ value: Double) -> Double { let cube = value * value * value; return cube > 0.008856451679 ? cube : (value - 16 / 116) / 7.787037037 }
    }

    private func rgba8(_ image: CGImage, maximumDimension: Int? = nil) throws -> RGBA8 {
        let scale = maximumDimension.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw StudioError.validation("Could not decode pixels for Colour Correct.") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw StudioError.validation("Could not read pixels for Colour Correct.") }
        return .init(bytes: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)), width: width, height: height, colorSpace: space)
    }

    private func labStatistics(_ pixels: [UInt8]) throws -> LabStatistics {
        var count = 0.0, l = 0.0, a = 0.0, b = 0.0, l2 = 0.0, a2 = 0.0, b2 = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.01 else { continue }
            let lab = Lab.fromSRGB(red: Double(pixels[offset]) / 255 / alpha, green: Double(pixels[offset + 1]) / 255 / alpha, blue: Double(pixels[offset + 2]) / 255 / alpha)
            count += 1; l += lab.l; a += lab.a; b += lab.b; l2 += lab.l * lab.l; a2 += lab.a * lab.a; b2 += lab.b * lab.b
        }
        guard count > 0 else { throw StudioError.validation("Colour Correct cannot analyse an image with no visible pixels.") }
        func channel(_ total: Double, _ squares: Double) -> ChannelStatistics { let mean = total / count; return .init(mean: mean, standardDeviation: max(0.0001, sqrt(max(0, squares / count - mean * mean)))) }
        return .init(l: channel(l, l2), a: channel(a, a2), b: channel(b, b2))
    }
    private func remap(_ value: Double, from generated: ChannelStatistics, to source: ChannelStatistics) -> Double { (value - generated.mean) * source.standardDeviation / generated.standardDeviation + source.mean }
    private func byte(_ value: Double) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }

    /// Deterministic mask preparation: invert, grow/shrink (morphology) and feather (blur), in that fixed
    /// order, gated by an exact pixel-dimension match against an optional connected source image. This is
    /// the "validation against source size" the mask must pass before any future inpaint adapter uses it;
    /// GenStudio never lets a mismatched mask silently reach the runtime.
    func maskOperations(_ url: URL, invert: Bool, growOrShrink: Int, featherRadius: Double, matchingSize source: URL? = nil) throws -> URL {
        guard (-256...256).contains(growOrShrink) else { throw StudioError.validation("Mask grow/shrink must be between -256 and 256 pixels.") }
        guard featherRadius.isFinite, (0...100).contains(featherRadius) else { throw StudioError.validation("Mask feather must be between 0 and 100 pixels.") }
        let maskImage = try validateImage(url)
        if let source {
            let sourceImage = try validateImage(source)
            guard maskImage.width == sourceImage.width, maskImage.height == sourceImage.height else {
                throw StudioError.validation("Mask dimensions (\(maskImage.width)×\(maskImage.height)) must match the source image (\(sourceImage.width)×\(sourceImage.height)) exactly.")
            }
        }
        var image = CIImage(cgImage: maskImage)
        let bounds = image.extent
        if invert { image = image.applyingFilter("CIColorInvert") }
        if growOrShrink != 0 {
            let filterName = growOrShrink > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum"
            image = image.clampedToExtent().applyingFilter(filterName, parameters: [kCIInputRadiusKey: Double(abs(growOrShrink))]).cropped(to: bounds)
        }
        if featherRadius > 0 {
            image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: featherRadius]).cropped(to: bounds)
        }
        return try render(image, bounds: bounds)
    }
    private func render(_ image: CIImage, bounds: CGRect) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard bounds.width > 0, bounds.height > 0, bounds.width * bounds.height <= 67_108_864,
              let result = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space]).createCGImage(image, from: bounds, format: .RGBA8, colorSpace: space) else { throw StudioError.validation("Image transform could not produce bounded pixels.") }
        return try writePNG(result)
    }

    func extractFrame(_ url: URL, seconds: Double) async throws -> URL {
        guard seconds.isFinite, seconds >= 0 else { throw StudioError.validation("Frame time must be a finite nonnegative number.") }
        try await validateVideo(url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, seconds <= duration else { throw StudioError.validation("Frame time must be within the finite video duration of \(duration.formatted()) seconds.") }
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .init(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = .init(seconds: 0.1, preferredTimescale: 600)
        do {
            let (image, actual) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            guard actual.seconds.isFinite, abs(actual.seconds - seconds) <= 0.101 else { throw StudioError.validation("The decoder returned a frame outside the 0.1 second timing tolerance.") }
            return try writePNG(image)
        }
        catch { throw StudioError.validation("Could not decode the requested video frame: \(error.localizedDescription)") }
    }

    /// Decode a source clip into the lexicographically ordered PNG directory
    /// expected by MiniMax-H3 Ref2VA's `--ref-video` argument. H3 consumes these
    /// references at 24 fps; retaining the original movie itself is still useful
    /// provenance, but the runtime receives the deterministic frame sequence.
    func extractVideoFrames(_ url: URL, fps: Int = 24, maxFrames: Int = 600) async throws -> URL {
        guard (1...120).contains(fps), maxFrames > 0 else {
            throw StudioError.validation("Reference frame extraction needs a valid frame rate and frame limit.")
        }
        try await validateVideo(url)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw StudioError.validation("The reference video has no finite duration.") }
        let frameCount = max(1, Int(ceil(duration * Double(fps) - 0.000_001)))
        guard frameCount <= maxFrames else {
            throw StudioError.validation("Reference video is \(duration.formatted(.number.precision(.fractionLength(1)))) seconds (\(frameCount) frames at \(fps) fps). Shorten it to \(Double(maxFrames / fps).formatted(.number.precision(.fractionLength(1)))) seconds or less before using Video to Video.")
        }
        let directory = artifacts.appending(path: "reference-frames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .init(seconds: 0.05, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = .init(seconds: 0.05, preferredTimescale: 600)
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let time = Double(index) / Double(fps)
                do {
                    let (image, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                    guard actual.seconds.isFinite, abs(actual.seconds - time) <= 0.051 else {
                        throw StudioError.validation("The decoder returned reference frame \(index) outside the 0.05 second timing tolerance.")
                    }
                    let output = directory.appending(path: String(format: "frame_%06d.png", index))
                    try writePNG(image, to: output)
                } catch {
                    throw StudioError.validation("Could not decode reference frame \(index): \(error.localizedDescription)")
                }
            }
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func retain(_ url: URL) throws -> URL {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw StudioError.validation("The selected media file is not readable.") }
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let output = artifacts.appending(path: "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "bin" : url.pathExtension)")
        do { try FileManager.default.copyItem(at: url, to: output); return output } catch { throw StudioError.persistence(error.localizedDescription) }
    }

    private func writePNG(_ image: CGImage) throws -> URL {
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let output = artifacts.appending(path: "\(UUID().uuidString).png")
        try writePNG(image, to: output)
        return output
    }

    private func writePNG(_ image: CGImage, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw StudioError.persistence("Could not create an image artifact.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), FileManager.default.isReadableFile(atPath: output.path) else { throw StudioError.persistence("The image artifact could not be validated.") }
    }
}
