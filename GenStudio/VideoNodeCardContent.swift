import AVKit
import SwiftUI

struct NodeAvailabilityBadge: View {
    let status: VideoPreflight.Availability
    var body: some View {
        switch status {
        case .runnable: EmptyView()
        case .needsModel: badge("Needs model", color: .yellow)
        case .unavailable: badge("Unavailable", color: .orange)
        }
    }
    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status: \(text)")
    }
}

/// Compact card body. Detailed controls stay in the inspector.
struct VideoNodeCardContent: View {
    let node: StudioNode
    let output: RuntimeValue?
    let images: [URL]
    let status: VideoPreflight.Availability?

    static func handles(_ kind: NodeKind) -> Bool { kind.videoTask != nil || kind == .frameInterpolate || kind == .instagramExport || kind == .shotSequence || kind == .animatic || kind == .assembleVideo || kind == .endCard || kind == .textOverlay || kind == .voiceover }
    static func icon(_ kind: NodeKind) -> String? {
        switch kind {
        case .textToVideo, .imageToVideo, .startEndVideo, .videoToVideo: "film"
        case .frameInterpolate: "waveform.path"
        case .instagramExport: "iphone.gen3"
        case .guidedShot: "film.stack"
        case .shotSequence: "square.stack.3d.forward.dottedline"
        case .animatic: "rectangle.on.rectangle"
        case .assembleVideo: "rectangle.split.3x1"
        case .endCard: "text.below.photo"
        case .textOverlay: "captions.bubble"
        case .voiceover: "waveform"
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status, status != .runnable {
                HStack { NodeAvailabilityBadge(status: status); Spacer() }
            }
            switch node.kind {
            case .shotSequence:
                let spec = node.sequence
                if spec.anchors.isEmpty {
                    Label("Add frames in the inspector", systemImage: "photo.badge.plus").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 3) {
                        ForEach(Array(images.prefix(6).enumerated()), id: \.offset) { LocalImageThumbnail(url: $0.element).frame(width: 44, height: 34) }
                        if spec.anchors.count > 6 { Text("+\(spec.anchors.count - 6)").font(.caption2) }
                    }
                    Text((try? SequenceTiming.resolve(spec)).map { "\(spec.anchors.count) frames · \($0.duration.formatted(.number.precision(.fractionLength(2)))) s · \($0.fps) fps" } ?? "\(spec.anchors.count) frames · timing needs attention")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .textToVideo, .imageToVideo:
                Text(generationSummary).font(.caption).foregroundStyle(.secondary)
                outputLabel
            case .startEndVideo, .videoToVideo:
                if status == .unavailable {
                    Text("No compatible adapter yet. Authoring only; will not run.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(generationSummary).font(.caption).foregroundStyle(.secondary)
                    outputLabel
                }
            case .endCard:
                let settings = node.endCardSettings ?? .init()
                Text("\(settings.width)×\(settings.height) · \(settings.durationSeconds.formatted(.number.precision(.fractionLength(1)))) s · \(settings.fps) fps")
                    .font(.caption).foregroundStyle(.secondary)
                if let preview = EndCardPreviewCache.image(settings) {
                    Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs))
                        .accessibilityLabel("End card design preview")
                }
            case .guidedShot:
                Text("Needs a native multi-keyframe adapter. Use Shot Sequence → Animatic for timing, or explicit Start/End transitions → Stitcher.").font(.caption).foregroundStyle(.secondary)
            default:
                outputLabel
            }
        }
        .padding(NodeLayout.bodyInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius).stroke(Color.white.opacity(0.2)))
    }

    private var generationSummary: String {
        guard let task = node.kind.videoTask,
              let capability = VideoCapabilityRegistry.capability(recipeID: node.model, task: task),
              let resolved = try? VideoDurationResolver.resolve(requestedSeconds: node.video.requestedDurationSeconds, fps: node.video.fps, rule: capability.frames) else {
            return "\(node.video.width)×\(node.video.height) · duration needs attention · \(node.video.fps) fps"
        }
        let digits = resolved.control.requestedFractionDigits
        let requested = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, resolved.requestedSeconds)
        return "\(node.video.width)×\(node.video.height) · \(requested) s · \(node.video.fps) fps"
    }

    /// A readable clip is drawn by `CanvasVideoPreview` across the whole preview, so
    /// this only marks where the render will appear, filling the card's shape.
    @ViewBuilder private var outputLabel: some View {
        VStack(spacing: 6) {
            Image(systemName: "play.rectangle").font(.system(size: 26, weight: .ultraLight)).foregroundStyle(.white.opacity(0.25))
            Text(missingOutput ? "Video is missing or unreadable" : "Run to render").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var missingOutput: Bool {
        if case .video = output { return true }
        return false
    }
}

/// Small design previews for End Card nodes, so canvas redraws reuse the last render of unchanged settings.
@MainActor
enum EndCardPreviewCache {
    private static var images: [EndCardSettings: CGImage] = [:]

    static func image(_ settings: EndCardSettings) -> CGImage? {
        if let cached = images[settings] { return cached }
        guard let rendered = EndCardRenderer.preview(settings, maxPixel: 240) else { return nil }
        if images.count >= 16 { images.removeAll() }
        images[settings] = rendered
        return rendered
    }
}
