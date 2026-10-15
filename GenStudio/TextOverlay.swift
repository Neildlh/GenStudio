import AVFoundation
import CoreImage
import CoreText
import Foundation

/// A caption over a clip: a main line (an offer, a price, "Book now") and an optional smaller line, at the
/// top, middle or lower third, for the whole clip or a time window. Rendered locally; sound is untouched.
struct TextOverlaySettings: Codable, Hashable, Sendable {
    enum Position: String, Codable, CaseIterable, Sendable {
        case top, middle, lowerThird
        var title: String { switch self { case .top: "Top"; case .middle: "Middle"; case .lowerThird: "Lower third" } }
    }
    enum Style: String, Codable, CaseIterable, Sendable {
        case darkBand, accentBand, plain
        var title: String { switch self { case .darkBand: "Dark band"; case .accentBand: "Accent band"; case .plain: "Text with shadow" } }
    }

    var text = ""
    var subtext = ""
    var position = Position.lowerThird
    var style = Style.darkBand
    var startSeconds = 0.0
    /// Zero shows the caption until the end of the clip.
    var durationSeconds = 0.0
    var textHex = "#FFFFFF"
    var accentHex = "#F5B700"
    /// Fades in and out over a quarter of a second.
    var fade = true

    static let fadeSeconds = 0.25

    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError.validation("Text Overlay needs a caption.") }
        guard startSeconds.isFinite, startSeconds >= 0, durationSeconds.isFinite, durationSeconds >= 0 else { throw StudioError.validation("Text Overlay timing must be zero or more seconds.") }
        guard EndCardSettings.color(textHex) != nil, EndCardSettings.color(accentHex) != nil else { throw StudioError.validation("Text Overlay colours must be six-digit hex values such as #F5B700.") }
    }

    /// 0…1 visibility at `time` in a clip of `clipDuration` seconds.
    func visibility(at time: Double, clipDuration: Double) -> Double {
        let end = durationSeconds > 0 ? min(clipDuration, startSeconds + durationSeconds) : clipDuration
        guard time >= startSeconds, time <= end else { return 0 }
        guard fade else { return 1 }
        let fadeIn = startSeconds > 0.001 ? min(1, (time - startSeconds) / Self.fadeSeconds) : 1
        let fadeOut = end < clipDuration - 0.001 ? min(1, (end - time) / Self.fadeSeconds) : 1
        return max(0, min(fadeIn, fadeOut))
    }
}

extension TextOverlaySettings {
    private enum CodingKeys: String, CodingKey { case text, subtext, position, style, startSeconds, durationSeconds, textHex, accentHex, fade }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        subtext = try c.decodeIfPresent(String.self, forKey: .subtext) ?? ""
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? .lowerThird
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? .darkBand
        startSeconds = try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        textHex = try c.decodeIfPresent(String.self, forKey: .textHex) ?? textHex
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? accentHex
        fade = try c.decodeIfPresent(Bool.self, forKey: .fade) ?? true
    }
}

extension BrandKit {
    func fill(_ caption: inout TextOverlaySettings) {
        if EndCardSettings.color(textHex) != nil { caption.textHex = textHex }
        if EndCardSettings.color(accentHex) != nil { caption.accentHex = accentHex }
    }
}

/// Where the caption band and its lines sit, in top-left-origin points, inside the same safe area as End Card.
struct TextOverlayLayout {
    let band: CGRect
    let headline: (frame: CGRect, text: NSAttributedString)
    let subline: (frame: CGRect, text: NSAttributedString)?
    let bandColor: CGColor?

    static func make(_ settings: TextOverlaySettings, size: CGSize) -> TextOverlayLayout {
        let safe = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.06, dy: size.height * 0.05)
        let short = min(size.width, size.height)
        let accent = EndCardSettings.color(settings.accentHex) ?? CGColor(gray: 1, alpha: 1)
        let bandColor: CGColor?, main: CGColor, secondary: CGColor
        switch settings.style {
        case .darkBand:
            bandColor = CGColor(gray: 0, alpha: 0.62); main = CGColor(gray: 1, alpha: 1); secondary = accent
        case .accentBand:
            let onAccent = EndCardRenderer.isLight(accent) ? CGColor(gray: 0.07, alpha: 1) : CGColor(gray: 1, alpha: 1)
            bandColor = accent; main = onAccent; secondary = onAccent
        case .plain:
            bandColor = nil; main = EndCardSettings.color(settings.textHex) ?? CGColor(gray: 1, alpha: 1); secondary = accent
        }
        let padding = short * 0.035
        let maxText = safe.width - padding * 2
        func fit(_ string: String, size design: CGFloat, weight: CGFloat, color: CGColor, lines limit: Int) -> (CGSize, NSAttributedString) {
            var point = short * design
            var text = EndCardLayout.attributed(string, size: point, weight: weight, color: color)
            var measured = EndCardLayout.measure(text, maxWidth: maxText)
            while measured.lines > limit, point > short * design * 0.5 {
                point *= 0.92
                text = EndCardLayout.attributed(string, size: point, weight: weight, color: color)
                measured = EndCardLayout.measure(text, maxWidth: maxText)
            }
            return (measured.size, text)
        }
        let head = fit(settings.text, size: 0.068, weight: 0.62, color: main, lines: 2)
        let sub = settings.subtext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : fit(settings.subtext, size: 0.042, weight: 0.3, color: secondary, lines: 2)
        let gap = sub == nil ? 0 : short * 0.012
        let contentHeight = head.0.height + gap + (sub?.0.height ?? 0)
        let contentWidth = max(head.0.width, sub?.0.width ?? 0)
        let bandSize = CGSize(width: min(safe.width, contentWidth + padding * 2), height: min(safe.height, contentHeight + padding * 2))
        let centreY: CGFloat = switch settings.position {
        case .top: safe.minY + bandSize.height / 2 + size.height * 0.04
        case .middle: size.height / 2
        case .lowerThird: safe.maxY - bandSize.height / 2 - size.height * 0.12
        }
        let band = CGRect(x: (size.width - bandSize.width) / 2, y: min(max(centreY - bandSize.height / 2, safe.minY), safe.maxY - bandSize.height), width: bandSize.width, height: bandSize.height)
        let headFrame = CGRect(x: (size.width - head.0.width) / 2, y: band.minY + padding, width: head.0.width, height: head.0.height)
        let subFrame = sub.map { CGRect(x: (size.width - $0.0.width) / 2, y: headFrame.maxY + gap, width: $0.0.width, height: $0.0.height) }
        return .init(band: band, headline: (headFrame, head.1), subline: sub.flatMap { s in subFrame.map { ($0, s.1) } }, bandColor: bandColor)
    }

    /// The caption alone on a transparent canvas of the clip's size.
    func image(size: CGSize, shadow: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height) }
        if let bandColor {
            context.setFillColor(bandColor)
            context.addPath(CGPath(roundedRect: flipped(band), cornerWidth: band.height * 0.18, cornerHeight: band.height * 0.18, transform: nil))
            context.fillPath()
        }
        if shadow { context.setShadow(offset: CGSize(width: 0, height: -2), blur: min(size.width, size.height) * 0.012, color: CGColor(gray: 0, alpha: 0.8)) }
        for line in [headline] + (subline.map { [$0] } ?? []) {
            let setter = CTFramesetterCreateWithAttributedString(line.text)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: flipped(line.frame), transform: nil), nil), context)
        }
        return context.makeImage()
    }
}

enum TextOverlayRenderer {
    /// Re-encodes `source` with the caption composited over its frames; audio passes through.
    static func render(_ settings: TextOverlaySettings, source: URL, to output: URL) async throws -> URL {
        try settings.validate()
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.validation("Text Overlay needs a video track.") }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = try DisplayGeometry.resolve(size: size, transform: transform, source: source.lastPathComponent)
        let canvas = CGSize(width: abs(display.width).rounded(), height: abs(display.height).rounded())
        let clipDuration = try await asset.load(.duration).seconds
        guard settings.startSeconds < clipDuration else {
            throw StudioError.validation("The caption starts at \(settings.startSeconds) s, after the clip ends (\(String(format: "%.1f", clipDuration)) s).")
        }
        let layout = TextOverlayLayout.make(settings, size: canvas)
        guard let captionImage = layout.image(size: canvas, shadow: settings.style == .plain) else { throw StudioError.validation("Could not draw the caption.") }
        let caption = CIImage(cgImage: captionImage)
        let composition = try await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage.clampedToExtent().cropped(to: request.sourceImage.extent)
            let alpha = CGFloat(settings.visibility(at: request.compositionTime.seconds, clipDuration: clipDuration))
            guard alpha > 0 else { request.finish(with: request.sourceImage, context: nil); return }
            let placed = caption.transformed(by: CGAffineTransform(translationX: request.sourceImage.extent.minX, y: request.sourceImage.extent.minY))
            let faded = alpha >= 1 ? placed : placed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
            ])
            request.finish(with: faded.composited(over: source), context: nil)
        })
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError.validation("Could not create the caption exporter.") }
        session.videoComposition = composition
        do { try await session.export(to: output, as: .mov) }
        catch is CancellationError { throw CancellationError() }
        catch { throw StudioError.validation("Text Overlay export failed: \(error.localizedDescription)") }
        let probe = try await VideoProbe.inspect(output)
        guard abs(probe.duration - clipDuration) < 0.15, Double(probe.width) == canvas.width, Double(probe.height) == canvas.height else {
            try? FileManager.default.removeItem(at: output)
            throw StudioError.validation("Text Overlay validation failed: expected \(Int(canvas.width))×\(Int(canvas.height)) over \(clipDuration) s.")
        }
        return output
    }
}

extension VideoNodeRunner {
    func textOverlay(node: StudioNode, video: URL) async throws -> Output {
        try await media.validateVideo(video)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let output = scratch.appending(path: "caption-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try await TextOverlayRenderer.render(node.textOverlaySettings ?? .init(), source: video, to: output)
        try Task.checkCancellation()
        let retained = try await media.retain(output)
        let probe = try await VideoProbe.inspect(retained)
        let provenance = RenderedMediaProvenance(operation: .textOverlay, output: try MediaIdentity.of(retained), inputs: [try MediaIdentity.of(video)], width: probe.width, height: probe.height,
                                                 fps: Int(probe.nominalFPS.rounded()), frameCount: probe.frameCount, duration: probe.duration, lastFrameTimestamp: probe.lastFrameTimestamp, hasAudioTrack: probe.hasAudio)
        return .init(value: .video(retained), provenance: provenance, run: nil)
    }
}
