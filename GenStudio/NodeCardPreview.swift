import AVFoundation
import ImageIO
import SwiftUI

struct NodeCardPreview: View {
    let node: StudioNode
    let output: RuntimeValue?
    var referenceImages: [URL] = []
    var modelName: String = ""
    /// A short line above the text, such as a Prompt Enhancer's destination.
    var caption: String? = nil
    var videoStatus: VideoPreflight.Availability? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
                .overlay(alignment: .topTrailing) {
                    FinalQualityBadge(recipeID: node.model, compact: true).padding(6).allowsHitTesting(false)
                }
            if PixelSizeBadge.isSupported(node.kind) {
                PixelSizeBadge(node: node, output: output, sourceImages: referenceImages)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The clip a card plays in place: its readable video output, or the file a Video
    /// Input holds before it has run. The card then takes clicks only on the player's
    /// own button.
    static func videoURL(node: StudioNode, output: RuntimeValue?) -> URL? {
        if case .video(let url) = output, FileManager.default.isReadableFile(atPath: url.path) { return url }
        if node.kind == .videoInput, let path = node.videoPath, FileManager.default.isReadableFile(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        if let videoURL = Self.videoURL(node: node, output: output) {
            CanvasVideoPreview(url: videoURL)
                .overlay(alignment: .topLeading) {
                    if let videoStatus, videoStatus != .runnable {
                        NodeAvailabilityBadge(status: videoStatus).padding(6)
                    }
                }
        } else if VideoNodeCardContent.handles(node.kind) {
            VideoNodeCardContent(node: node, output: output, images: referenceImages, status: videoStatus)
        } else if node.kind == .promptEnhancer || node.kind == .imageDescriber || node.kind == .characterSheet || node.kind == .imagePrompt || node.kind == .videoPrompt {
            ScrollView {
                if let caption {
                    Label(caption, systemImage: "arrow.turn.down.right")
                        .font(.system(size: CanvasType.label))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 6)
                }
                if node.kind == .characterSheet, !node.isLockedFinal {
                    Text(node.characterSheetBrief)
                        .font(.system(size: CanvasType.body))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                } else if case .text(let text) = output {
                    Text(text)
                        .font(.system(size: CanvasType.body))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                } else {
                    Text(emptyMessage)
                        .font(.system(size: CanvasType.body))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .contentMargins(NodeLayout.bodyInset, for: .scrollContent)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius).stroke(Color.white.opacity(0.2)))
        } else if NodeLayout.isImage(node) {
            ImageCardContent(node: node, output: output)
        } else { textContent }
    }

    private var emptyMessage: String {
        if node.kind == .imagePrompt {
            return node.imagePromptSettings?.compiledPrompt.isEmpty == false
                ? node.imagePromptSettings?.compiledPrompt ?? ""
                : "Select this node and describe the subject in the inspector."
        }
        if node.kind == .videoPrompt {
            return node.videoPromptSettings?.compiledPrompt.isEmpty == false
                ? node.videoPromptSettings?.compiledPrompt ?? ""
                : "Select this node and describe what happens in the shot."
        }
        if node.kind == .promptEnhancer {
            return caption?.hasPrefix("Connect") == false
                ? "Run this node to rewrite the connected prompt for where it is going."
                : "Connect a Prompt to Rough Prompt and Enhanced to an image or video node, then run this node."
        }
        if node.kind == .characterSheet {
            return node.characterSheetBrief
        }
        return referenceImages.isEmpty ? "Connect an image, then run the model to generate its description." : "Run the model to generate a description."
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if node.kind == .textModel {
                Label(node.model.isEmpty ? "Choose a text model" : node.model, systemImage: "cpu")
                    .font(.caption).lineLimit(1).help(node.model)
            }
            if node.kind == .imageInput, let path = node.imagePath {
                LocalImageThumbnail(url: URL(fileURLWithPath: path))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption2).lineLimit(1)
            } else if let output {
                Text("Last output").font(.caption2).foregroundStyle(.secondary)
                switch output {
                case .image(let url): LocalImageThumbnail(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let text): Text(text).font(.caption).lineLimit(3)
                case .textArray(let items): Text("\(items.count) items\n" + items.prefix(2).joined(separator: "\n")).font(.caption).lineLimit(3)
                case .number(let number): Text(number.formatted()).font(.title3.monospacedDigit())
                case .video(let url): Label(url.lastPathComponent, systemImage: "play.rectangle").font(.caption).lineLimit(2)
                case .shotSequence(let sequence): Label("\(sequence.anchors.count) frames", systemImage: "square.stack").font(.caption)
                }
            } else if node.kind == .prompt || node.kind == .promptTemplate || node.kind == .stickyNote {
                Text(node.prompt.isEmpty ? "Select to enter text" : node.prompt).font(.caption).lineLimit(3).foregroundStyle(node.prompt.isEmpty ? .secondary : .primary)
            } else if node.kind == .combineText {
                Text("Joins its connected text, top to bottom. Connect a Text Preview and run it to see the result.").font(.caption).foregroundStyle(.secondary)
            } else if node.hidesUpstreamOutputPlaceholder {
                Text("Its value appears once a connected node runs.").font(.caption).foregroundStyle(.secondary)
            } else if node.kind == .number {
                Text(node.numberValue.formatted()).font(.title3.monospacedDigit())
            } else if node.kind == .imageGenerator {
                Label(node.model.isEmpty ? "Choose an image model" : node.model, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            } else if node.kind == .imageInput {
                Label("Select to import an image", systemImage: "photo.badge.plus").font(.caption).foregroundStyle(.secondary)
            } else if node.kind == .videoInput {
                Label(node.videoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select to import a video", systemImage: "film").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Run to preview output").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(NodeLayout.bodyInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius).stroke(Color.white.opacity(0.2)))
    }
}

private extension StudioNode {
    /// Nodes that never show a Run button because a downstream node evaluates them. Telling the author to "run" one is a dead end.
    var hidesUpstreamOutputPlaceholder: Bool {
        kind.hidesCanvasRunControl && kind != .prompt && kind != .imagePrompt && kind != .videoPrompt && kind != .stickyNote && kind != .number
    }
}

private struct PixelSizeBadge: View {
    let node: StudioNode
    let output: RuntimeValue?
    let sourceImages: [URL]
    @State private var outputSize: CGSize?
    @State private var sourceSize: CGSize?

    static func isSupported(_ kind: NodeKind) -> Bool {
        kind == .imageGenerator || kind == .imageUpscale || kind == .videoUpscale || kind.videoTask != nil
    }

    private var mediaURL: URL? {
        switch output {
        case .image(let url), .video(let url): return url
        default: return nil
        }
    }

    private var configuredSize: CGSize? {
        if node.kind == .imageGenerator { return CGSize(width: node.width, height: node.height) }
        if node.kind.videoTask != nil {
            return CGSize(width: node.video.width, height: node.video.height)
        }
        if node.kind == .imageUpscale, let sourceSize {
            return CGSize(width: sourceSize.width * CGFloat(node.upscaleScale), height: sourceSize.height * CGFloat(node.upscaleScale))
        }
        return nil
    }

    private var size: CGSize? { outputSize ?? configuredSize }

    var body: some View {
        Group {
            if let size, size.width > 0, size.height > 0 {
                Text("\(Int(size.width)) × \(Int(size.height)) px")
                    .font(.system(size: CanvasType.label, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
                    .accessibilityLabel("Pixel dimensions: \(Int(size.width)) by \(Int(size.height)) pixels")
            } else {
                EmptyView()
            }
        }
        .task(id: taskKey) {
            outputSize = await readSize()
            sourceSize = await readSourceImageSize()
        }
    }

    @MainActor
    private func readSourceImageSize() async -> CGSize? {
        guard node.kind == .imageUpscale, let sourceURL = sourceImages.first,
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: width, height: height)
    }

    @MainActor
    private func readSize() async -> CGSize? {
        guard let mediaURL else { return nil }
        if node.kind.outputType == .image,
           let source = CGImageSourceCreateWithURL(mediaURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue {
            return CGSize(width: width, height: height)
        }
        guard node.kind.outputType == .video else { return nil }
        do {
            let asset = AVURLAsset(url: mediaURL)
            guard let track = try await asset.load(.tracks).first else { return nil }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform)
            return CGSize(width: abs(transformed.width), height: abs(transformed.height))
        } catch {
            return nil
        }
    }

    private var taskKey: String {
        let sourcePath = sourceImages.first?.standardizedFileURL.path ?? "no-source"
        return mediaURL?.standardizedFileURL.path ?? "configured-\(node.id)-\(node.width)-\(node.height)-\(node.video.width)-\(node.video.height)-\(node.upscaleScale)-\(sourcePath)"
    }
}


struct ImageCardContent: View {
    let node: StudioNode
    let output: RuntimeValue?
    private var url: URL? {
        if node.kind == .imageInput || node.kind == .maskInput, let path = node.imagePath { return URL(fileURLWithPath: path) }
        if case .image(let url) = output { return url }
        return nil
    }
    var body: some View {
        ZStack {
            Canvas { context, size in
                let step = 12.0
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Surface.control))
                for row in 0...Int(size.height / step) {
                    for column in 0...Int(size.width / step) where (row + column).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: Double(column) * step, y: Double(row) * step, width: step, height: step)), with: .color(Surface.controlElevated))
                    }
                }
            }
            if let url {
                LocalImageThumbnail(url: url).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.white.opacity(0.2))
            }
        }.clipShape(RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius))
    }
    static func footer(node: StudioNode, output: RuntimeValue?) -> String {
        if node.kind == .imageInput { return node.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select to import an image" }
        if node.kind == .maskInput { return node.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Select to import a mask" }
        if case .image(let url) = output { return "Last output · \(url.lastPathComponent)" }
        if node.kind == .imageGenerator || node.kind == .imageUpscale { return node.model.isEmpty ? "Choose a model" : node.model }
        return "No output yet"
    }
}
