import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The closing card of an advert: an optional logo, a headline, the offer, how to get in touch and a web or
/// social handle, on a brand colour or a darkened picture. Rendered locally with Core Text; no model runs.
struct EndCardSettings: Codable, Hashable, Sendable {
    var headline = "Your business name"
    var offer = ""
    var contact = ""
    var website = ""
    var width = 1080
    var height = 1920
    var durationSeconds = 3.0
    var fps = 24
    var backgroundHex = "#111827"
    var textHex = "#FFFFFF"
    var accentHex = "#F5B700"
    /// How far a connected background picture is darkened so the text reads: 0 leaves it, 1 is black.
    var backgroundDim = 0.55
    /// Lines fade up in turn over the first second and the background drifts; off gives a still card.
    var animate = true

    static let sizes: [(title: String, width: Int, height: Int)] = [
        ("Vertical 9:16 · 1080×1920", 1080, 1920), ("Square 1:1 · 1080×1080", 1080, 1080), ("Landscape 16:9 · 1920×1080", 1920, 1080)
    ]
    static let palettes: [(title: String, background: String, text: String, accent: String)] = [
        ("Charcoal and gold", "#111827", "#FFFFFF", "#F5B700"),
        ("Navy and white", "#1E3A8A", "#FFFFFF", "#93C5FD"),
        ("Forest and lime", "#14532D", "#FFFFFF", "#A3E635"),
        ("Clean white", "#FFFFFF", "#111827", "#DC2626"),
        ("Sunset", "#7C2D12", "#FFF7ED", "#FDBA74")
    ]
    static let durationRange = 1.0...10.0
    static let frameRates = [24, 25, 30]

    var frameCount: Int { max(1, Int((durationSeconds * Double(fps)).rounded())) }

    func validate() throws {
        guard Self.durationRange.contains(durationSeconds) else { throw StudioError.validation("End Card length must be 1–10 seconds.") }
        guard Self.frameRates.contains(fps) else { throw StudioError.validation("End Card frame rate must be 24, 25 or 30 fps.") }
        guard (16...4096).contains(width), (16...4096).contains(height), width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw StudioError.validation("End Card size must be even and 16–4096 pixels per side.")
        }
        guard Self.color(backgroundHex) != nil, Self.color(textHex) != nil, Self.color(accentHex) != nil else {
            throw StudioError.validation("End Card colours must be six-digit hex values such as #F5B700.")
        }
        guard [headline, offer, contact, website].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw StudioError.validation("End Card needs at least one line of text.")
        }
    }

    /// sRGB colour from `#RRGGBB` or `RRGGBB`.
    static func color(_ hex: String, alpha: Double = 1) -> CGColor? {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

extension EndCardSettings {
    private enum CodingKeys: String, CodingKey { case headline, offer, contact, website, width, height, durationSeconds, fps, backgroundHex, textHex, accentHex, backgroundDim, animate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? headline
        offer = try c.decodeIfPresent(String.self, forKey: .offer) ?? offer
        contact = try c.decodeIfPresent(String.self, forKey: .contact) ?? contact
        website = try c.decodeIfPresent(String.self, forKey: .website) ?? website
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? height
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? durationSeconds
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? backgroundHex
        textHex = try c.decodeIfPresent(String.self, forKey: .textHex) ?? textHex
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? accentHex
        backgroundDim = try c.decodeIfPresent(Double.self, forKey: .backgroundDim) ?? backgroundDim
        animate = try c.decodeIfPresent(Bool.self, forKey: .animate) ?? animate
    }
}

/// Where each element of the card sits, in top-left-origin points of the output size. Everything is centred
/// in a safe area (6% side and 5% top/bottom margins, clear of Reels and Status overlays); lines wrap, and the
/// whole stack shrinks until it fits.
struct EndCardLayout {
    enum Role: String, Sendable { case logo, headline, offer, contact, website }
    struct Block {
        let role: Role
        let frame: CGRect
        /// Nil for the logo.
        let text: NSAttributedString?
    }
    let blocks: [Block]
    /// The short accent rule under the headline, when there is a line below it.
    let accentRule: CGRect?

    static func make(_ settings: EndCardSettings, size: CGSize, logoAspect: Double?) -> EndCardLayout {
        let safe = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.06, dy: size.height * 0.05)
        let short = min(size.width, size.height)
        var scale = 1.0
        for _ in 0..<12 {
            let layout = attempt(settings, size: size, safe: safe, short: short, scale: scale, logoAspect: logoAspect)
            if layout.height <= safe.height { return layout.layout }
            scale *= 0.88
        }
        return attempt(settings, size: size, safe: safe, short: short, scale: scale, logoAspect: logoAspect).layout
    }

    private static func attempt(_ settings: EndCardSettings, size: CGSize, safe: CGRect, short: CGFloat, scale: Double, logoAspect: Double?) -> (layout: EndCardLayout, height: CGFloat) {
        let text = EndCardSettings.color(settings.textHex) ?? CGColor(gray: 1, alpha: 1)
        let accent = EndCardSettings.color(settings.accentHex) ?? text
        let muted = text.copy(alpha: 0.82) ?? text
        let maxWidth = safe.width * 0.96
        typealias Line = (role: Role, string: String, size: CGFloat, weight: CGFloat, color: CGColor, maxLines: Int)
        let lines: [Line] = [
            (.headline, settings.headline, 0.092, 0.62, text, 3),
            (.offer, settings.offer, 0.062, 0.4, accent, 2),
            (.contact, settings.contact, 0.054, 0.4, text, 2),
            (.website, settings.website, 0.04, 0.0, muted, 2)
        ].filter { !$0.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var items: [(role: Role, size: CGSize, text: NSAttributedString?)] = []
        if let logoAspect, logoAspect.isFinite, logoAspect > 0 {
            let box = CGSize(width: size.width * 0.5 * scale, height: size.height * (size.height > size.width ? 0.16 : 0.24) * scale)
            let width = min(box.width, box.height * logoAspect)
            items.append((.logo, CGSize(width: width, height: width / logoAspect), nil))
        }
        for line in lines {
            var pointSize = short * line.size * scale
            var fitted = attributed(line.string, size: pointSize, weight: line.weight, color: line.color)
            var measured = measure(fitted, maxWidth: maxWidth)
            // Shrink a long line until it fits its line budget; never below half its design size.
            while measured.lines > line.maxLines, pointSize > short * line.size * scale * 0.5 {
                pointSize *= 0.92
                fitted = attributed(line.string, size: pointSize, weight: line.weight, color: line.color)
                measured = measure(fitted, maxWidth: maxWidth)
            }
            items.append((line.role, measured.size, fitted))
        }

        let gap = size.height * 0.028 * scale
        let logoGap = size.height * 0.05 * scale
        let ruleHeight = max(4, size.height * 0.005 * scale)
        let ruleGap = gap * 1.6 + ruleHeight
        let hasRule = items.contains { $0.role == .headline } && items.contains { $0.role != .headline && $0.role != .logo }
        var total: CGFloat = 0
        for (index, item) in items.enumerated() {
            total += item.size.height
            guard index + 1 < items.count else { continue }
            total += item.role == .logo ? logoGap : item.role == .headline && hasRule ? ruleGap : gap
        }
        var y = safe.minY + max(0, (safe.height - total) / 2)
        var blocks: [Block] = [], rule: CGRect?
        for (index, item) in items.enumerated() {
            let frame = CGRect(x: (size.width - item.size.width) / 2, y: y, width: item.size.width, height: item.size.height)
            blocks.append(.init(role: item.role, frame: frame, text: item.text))
            y += item.size.height
            guard index + 1 < items.count else { continue }
            if item.role == .headline && hasRule {
                let ruleWidth = size.width * 0.12
                rule = CGRect(x: (size.width - ruleWidth) / 2, y: y + gap * 0.8, width: ruleWidth, height: ruleHeight)
                y += ruleGap
            } else {
                y += item.role == .logo ? logoGap : gap
            }
        }
        return (.init(blocks: blocks, accentRule: rule), total)
    }

    private static func font(size: CGFloat, weight: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(weight > 0.3 ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    static func attributed(_ string: String, size: CGFloat, weight: CGFloat, color: CGColor) -> NSAttributedString {
        let paragraph: CTParagraphStyle = withUnsafeBytes(of: CTTextAlignment.center) { alignment in
            withUnsafeBytes(of: size * 0.08) { spacing in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: alignment.count, value: alignment.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: spacing.count, value: spacing.baseAddress!)
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        return NSAttributedString(string: string.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, weight: weight),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
    }

    static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> (size: CGSize, lines: Int) {
        let setter = CTFramesetterCreateWithAttributedString(text)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: maxWidth, height: suggested.height + 4), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CFArrayGetCount(CTFrameGetLines(frame))
        return (CGSize(width: min(maxWidth, ceil(suggested.width) + 2), height: ceil(suggested.height) + 2), lines)
    }
}

enum EndCardRenderer {
    struct Result: Sendable { let probe: VideoProbe }

    /// Renders the card as a silent H.264 clip and its final frame as a PNG (sRGB) for posters and Status.
    static func render(_ settings: EndCardSettings, logo: URL?, background: URL?, video: URL, still: URL) async throws -> Result {
        try settings.validate()
        let logoImage = try logo.map(FrameSequenceEncoder.loadImage)
        let backgroundImage = try background.map(FrameSequenceEncoder.loadImage)
        let size = CGSize(width: settings.width, height: settings.height)
        let layout = EndCardLayout.make(settings, size: size, logoAspect: logoImage.map { Double($0.width) / Double($0.height) })
        let total = settings.frameCount
        let duration = Double(total) / Double(settings.fps)
        // With animation off every frame is the same buffer; otherwise the background keeps drifting slowly.
        var stillFrame: CVPixelBuffer?
        try await FrameSequenceEncoder.encode(frameCount: total, width: settings.width, height: settings.height, fps: settings.fps, to: video) { index in
            if !settings.animate, let stillFrame { return stillFrame }
            let time = settings.animate ? Double(index) / Double(settings.fps) : duration
            let buffer = try FrameSequenceEncoder.pixelBuffer(width: settings.width, height: settings.height) { context in
                draw(settings, layout: layout, logo: logoImage, background: backgroundImage, time: time, duration: duration, in: context)
            }
            if !settings.animate { stillFrame = buffer }
            return buffer
        }
        try writeStill(settings, layout: layout, logo: logoImage, background: backgroundImage, duration: duration, to: still)
        let probe = try await VideoProbe.inspect(video)
        guard probe.width == settings.width, probe.height == settings.height, probe.frameCount == total else {
            try? FileManager.default.removeItem(at: video)
            throw StudioError.validation("End Card validation failed: expected \(settings.width)×\(settings.height) with \(total) frames; decoded \(probe.width)×\(probe.height) with \(probe.frameCount).")
        }
        return .init(probe: probe)
    }

    /// The finished card at any size, for the inspector preview.
    static func preview(_ settings: EndCardSettings, maxPixel: CGFloat) -> CGImage? {
        let scale = min(1, maxPixel / CGFloat(max(settings.width, settings.height)))
        var scaled = settings
        scaled.width = max(16, Int(CGFloat(settings.width) * scale)); scaled.height = max(16, Int(CGFloat(settings.height) * scale))
        let size = CGSize(width: scaled.width, height: scaled.height)
        guard let context = CGContext(data: nil, width: scaled.width, height: scaled.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(scaled, layout: EndCardLayout.make(scaled, size: size, logoAspect: nil), logo: nil, background: nil, time: scaled.durationSeconds, duration: scaled.durationSeconds, in: context)
        return context.makeImage()
    }

    private static func writeStill(_ settings: EndCardSettings, layout: EndCardLayout, logo: CGImage?, background: CGImage?, duration: Double, to url: URL) throws {
        guard let context = CGContext(data: nil, width: settings.width, height: settings.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StudioError.validation("Could not draw the End Card still.")
        }
        draw(settings, layout: layout, logo: logo, background: background, time: duration, duration: duration, in: context)
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StudioError.validation("Could not write the End Card still.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.validation("Could not write the End Card still.") }
    }

    static func isLight(_ color: CGColor) -> Bool {
        guard let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, rgb.count >= 3 else { return false }
        return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2] > 0.6
    }

    /// Eased 0→1 appearance of the n-th element: each starts 0.15 s after the previous and takes 0.45 s.
    static func appearance(order: Int, time: Double, animate: Bool) -> Double {
        guard animate else { return 1 }
        let t = min(1, max(0, (time - 0.1 - Double(order) * 0.15) / 0.45))
        return 1 - pow(1 - t, 3)
    }

    private static func draw(_ settings: EndCardSettings, layout: EndCardLayout, logo: CGImage?, background: CGImage?, time: Double, duration: Double, in context: CGContext) {
        let width = CGFloat(context.width), height = CGFloat(context.height)
        let progress = settings.animate && duration > 0 ? min(1, max(0, time / duration)) : 1
        let base = EndCardSettings.color(settings.backgroundHex) ?? CGColor(gray: 0.08, alpha: 1)
        context.setFillColor(base); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let background {
            // Aspect-fill with a slow push in (up to 6%) over the card.
            let zoom = 1 + 0.06 * progress
            let fill = max(width / CGFloat(background.width), height / CGFloat(background.height)) * zoom
            let drawn = CGSize(width: CGFloat(background.width) * fill, height: CGFloat(background.height) * fill)
            context.interpolationQuality = .high
            context.draw(background, in: CGRect(x: (width - drawn.width) / 2, y: (height - drawn.height) / 2, width: drawn.width, height: drawn.height))
            context.setFillColor(CGColor(gray: 0, alpha: min(1, max(0, settings.backgroundDim)))); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else if let accent = EndCardSettings.color(settings.accentHex),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let glow = CGGradient(colorsSpace: space, colors: [accent.copy(alpha: Self.isLight(base) ? 0.07 : 0.22) ?? accent, accent.copy(alpha: 0) ?? accent] as CFArray, locations: [0, 1]) {
            // A soft accent glow drifting across the lower card gives a solid colour some life; on a light
            // card it stays faint so white reads as white.
            let centre = CGPoint(x: width * (0.7 - 0.4 * progress), y: height * (0.25 + 0.1 * progress))
            context.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: max(width, height) * 0.55, options: [])
        }
        func rect(_ frame: CGRect, rise: CGFloat) -> CGRect { CGRect(x: frame.minX, y: height - frame.maxY - rise, width: frame.width, height: frame.height) }
        for (order, block) in layout.blocks.enumerated() {
            let shown = appearance(order: order, time: time, animate: settings.animate)
            guard shown > 0 else { continue }
            let rise = CGFloat(1 - shown) * height * 0.02
            context.saveGState()
            context.setAlpha(CGFloat(shown))
            if block.role == .logo, let logo {
                context.interpolationQuality = .high
                context.draw(logo, in: rect(block.frame, rise: rise))
            } else if let text = block.text {
                let setter = CTFramesetterCreateWithAttributedString(text)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect(block.frame, rise: rise), transform: nil), nil)
                CTFrameDraw(frame, context)
            }
            context.restoreGState()
            if block.role == .headline, let rule = layout.accentRule, let accent = EndCardSettings.color(settings.accentHex) {
                let ruleShown = appearance(order: order + 1, time: time, animate: settings.animate)
                let grown = CGRect(x: rule.midX - rule.width * CGFloat(ruleShown) / 2, y: rule.minY, width: rule.width * CGFloat(ruleShown), height: rule.height)
                context.setFillColor(accent)
                context.fill(rect(grown, rise: 0))
            }
        }
    }
}

extension VideoNodeRunner {
    /// Renders the End Card in scratch, validates it, then retains the clip and its still.
    func endCard(node: StudioNode, logo: URL?, background: URL?) async throws -> (video: Output, still: URL) {
        let settings = node.endCardSettings ?? .init()
        for image in [logo, background].compactMap({ $0 }) { _ = try await media.validateImage(image) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let video = scratch.appending(path: "end-card-\(UUID().uuidString).mov")
        let still = scratch.appending(path: "end-card-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: still) }
        let result = try await EndCardRenderer.render(settings, logo: logo, background: background, video: video, still: still)
        try Task.checkCancellation()
        let retainedVideo = try await media.retain(video)
        let retainedStill = try await media.retain(still)
        let inputs = try [logo, background].compactMap { $0 }.map { try MediaIdentity.of($0) }
        let provenance = RenderedMediaProvenance(operation: .endCard, output: try MediaIdentity.of(retainedVideo), inputs: inputs, width: result.probe.width, height: result.probe.height,
                                                 fps: settings.fps, frameCount: result.probe.frameCount, duration: result.probe.duration, lastFrameTimestamp: result.probe.lastFrameTimestamp)
        return (.init(value: .video(retainedVideo), provenance: provenance, run: nil), retainedStill)
    }
}
