import Foundation
import ImageIO
import Observation

struct CanvasPoint: Codable, Hashable, Sendable { var x: Double; var y: Double }
struct CanvasViewport: Codable, Hashable, Sendable { var offset = CanvasPoint(x: 0, y: 0); var zoom = 1.0 }

struct CanvasWireRoute: Equatable {
    let source: CGPoint
    let sourceStub: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let targetStub: CGPoint
    let target: CGPoint
}

enum NodeInsertionSide: Equatable, Sendable {
    case left
    case right
}

struct AutomaticNodeConnection: Equatable, Sendable {
    let side: NodeInsertionSide
    let sourcePortID: String
    /// An empty target port means that the destination should create its next
    /// repeatable input (for example, a new Shot Sequence frame slot).
    let targetPortID: String
}

enum CanvasInteraction {
    /// Large workflows need a useful overview during ordinary pinch and
    /// keyboard zooming, not only when using Fit Workflow.
    static let minimumZoom = 0.1
    /// Fit commands may zoom farther out than manual navigation when a graph
    /// is exceptionally large, while keeping the regular canvas readable.
    static let fitMinimumZoom = 0.05
    static let maximumZoom = 4.0
    static let wireStubLength = 10.0

    /// Socket cards are transformed with the canvas, but the pointer is not.
    /// Keep a socket's effective hit radius usable as cards shrink, without
    /// making a distant socket accidentally win in a dense overview.
    static func socketHitRadius(for viewportZoom: Double) -> Double {
        min(60, max(22, 22 / max(viewportZoom, fitMinimumZoom)))
    }

    /// Chooses the most useful typed connection when a new node is added next
    /// to a selected node. Downstream attachment wins when both directions are
    /// possible; this makes adding an Image Upscale after an Image Generator
    /// predictable while still allowing Prompt and Image Input to attach before
    /// it. Repeatable inputs may be occupied because the model layer can create
    /// their next dynamic slot.
    static func automaticConnection(newNode: StudioNode, selectedNode: StudioNode, selectedInputPortIDs: Set<String> = []) -> AutomaticNodeConnection? {
        func input(for node: StudioNode, type: PortDataType, occupied: Set<String>, allowDynamic: Bool) -> PortDescriptor? {
            if let port = node.inputPorts.first(where: { $0.type == type && (!occupied.contains($0.id) || (allowDynamic && $0.repeatable)) }) { return port }
            if node.kind == .shotSequence, type == .image { return .init(id: "", label: "Frame", direction: .input, type: .image, required: false, repeatable: true) }
            if node.kind.supportsDynamicTextInputs && type == .text { return .init(id: "", label: "Text", direction: .input, type: .text, required: false, repeatable: true) }
            if node.kind.supportsDynamicImageInputs && type == .image { return .init(id: "", label: "Image", direction: .input, type: .image, required: false, repeatable: true) }
            if node.kind.supportsDynamicVideoInputs && type == .video { return .init(id: "", label: "Clip", direction: .input, type: .video, required: false, repeatable: true) }
            return nil
        }

        for output in selectedNode.outputPorts {
            if let target = input(for: newNode, type: output.type, occupied: [], allowDynamic: false) {
                return .init(side: .right, sourcePortID: output.id, targetPortID: target.id)
            }
        }
        for output in newNode.outputPorts {
            if let target = input(for: selectedNode, type: output.type, occupied: selectedInputPortIDs, allowDynamic: true) {
                return .init(side: .left, sourcePortID: output.id, targetPortID: target.id)
            }
        }
        return nil
    }

    static func translated(origin: CanvasPoint, horizontal: Double, vertical: Double, scale: Double = 1) -> CanvasPoint {
        let safeScale = max(scale, 0.0001)
        return .init(x: origin.x + horizontal / safeScale, y: origin.y + vertical / safeScale)
    }
    static func fittedViewport(nodes: [StudioNode], canvasWidth: Double, canvasHeight: Double, padding: Double = 40) -> CanvasViewport {
        fittedViewport(
            bounds: nodes.map { node in
                CGRect(
                    x: node.position.x - NodeLayout.leadingOverflow(node),
                    y: node.position.y,
                    width: NodeLayout.leadingOverflow(node) + NodeLayout.cardWidth(node) + NodeLayout.trailingOverflow(node),
                    height: NodeLayout.cardHeight(node)
                )
            },
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            padding: padding
        )
    }
    static func fittedViewport(bounds: [CGRect], canvasWidth: Double, canvasHeight: Double, padding: Double = 40, minimumZoom: Double = CanvasInteraction.minimumZoom, maximumZoom: Double = CanvasInteraction.maximumZoom) -> CanvasViewport {
        guard let first = bounds.first else { return CanvasViewport() }
        let union = bounds.dropFirst().reduce(first) { $0.union($1) }
        let zoom = min(maximumZoom, max(minimumZoom, min(
            max(canvasWidth - padding * 2, 1) / max(union.width, 1),
            max(canvasHeight - padding * 2, 1) / max(union.height, 1)
        )))
        return .init(
            offset: .init(
                x: (canvasWidth - union.width * zoom) / 2 - union.minX * zoom,
                y: (canvasHeight - union.height * zoom) / 2 - union.minY * zoom
            ),
            zoom: zoom
        )
    }
    static func zoomedViewport(_ viewport: CanvasViewport, to requestedZoom: Double, anchor: CanvasPoint) -> CanvasViewport {
        let oldZoom = max(viewport.zoom, 0.0001)
        let zoom = min(maximumZoom, max(minimumZoom, requestedZoom))
        let worldX = (anchor.x - viewport.offset.x) / oldZoom
        let worldY = (anchor.y - viewport.offset.y) / oldZoom
        return .init(
            offset: .init(x: anchor.x - worldX * zoom, y: anchor.y - worldY * zoom),
            zoom: zoom
        )
    }
    static func wireRoute(from source: CGPoint, to target: CGPoint) -> CanvasWireRoute {
        let sourceStub = CGPoint(x: source.x + wireStubLength, y: source.y)
        let targetStub = CGPoint(x: target.x - wireStubLength, y: target.y)
        let bend = max(60, abs(targetStub.x - sourceStub.x) * 0.45)
        return .init(
            source: source,
            sourceStub: sourceStub,
            control1: .init(x: sourceStub.x + bend, y: sourceStub.y),
            control2: .init(x: targetStub.x - bend, y: targetStub.y),
            targetStub: targetStub,
            target: target
        )
    }
    static func navigationOrder(nodes: [StudioNode], edges: [StudioEdge]) -> [UUID] {
        let ids = Set(nodes.map(\.id))
        let positions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        func ordered(_ values: some Sequence<UUID>) -> [UUID] {
            values.sorted {
                let lhs = positions[$0] ?? .init(x: 0, y: 0)
                let rhs = positions[$1] ?? .init(x: 0, y: 0)
                if lhs.x != rhs.x { return lhs.x < rhs.x }
                if lhs.y != rhs.y { return lhs.y < rhs.y }
                return $0.uuidString < $1.uuidString
            }
        }
        var incoming = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        var outgoing: [UUID: [UUID]] = [:]
        for edge in edges where ids.contains(edge.sourceID) && ids.contains(edge.targetID) {
            incoming[edge.targetID, default: 0] += 1
            outgoing[edge.sourceID, default: []].append(edge.targetID)
        }
        var ready = ordered(ids.filter { incoming[$0] == 0 })
        var result: [UUID] = []
        while !ready.isEmpty {
            let next = ready.removeFirst()
            result.append(next)
            for target in outgoing[next] ?? [] {
                incoming[target, default: 0] -= 1
                if incoming[target] == 0 { ready.append(target); ready = ordered(ready) }
            }
        }
        if result.count < ids.count {
            result.append(contentsOf: ordered(ids.subtracting(result)))
        }
        return result
    }
}

enum NodeLayout {
    private static let imageAspectRatios = MediaAspectRatioCache()
    /// Measured video shapes. Filled asynchronously by the canvas player, and observable,
    /// so a card re-lays out to its clip's real proportions once they are known.
    static let videoAspectRatios = VideoAspectRatioStore()
    // Keep canvas geometry in one place. Node content can vary, but the
    // chrome around it should feel like one family of controls.
    static let bodyInset = 12.0
    static let promptInset = 16.0
    static let compactHeaderHeight = 40.0
    static let prominentHeaderHeight = 52.0
    static let actionRowHeight = 40.0
    static let footerReserve = 52.0
    static let footerOffset = 46.0
    static let previewCornerRadius = Radius.sm
    static let cardCornerRadius = Radius.md
    static let prominentCardCornerRadius = Radius.lg
    static let socketRowHeight = 24.0
    static let socketLabelWidth = 102.0
    static let socketRailWidth = 124.0
    /// The visible socket remains aligned to the rail, while its transparent
    /// interaction target is deliberately larger for fast trackpad wiring.
    static let socketHitTargetWidth = 148.0
    static let socketHitTargetHeight = 36.0

    static func isImage(_ node: StudioNode) -> Bool { node.kind.outputType == .image }
    static func isPromptStyled(_ node: StudioNode) -> Bool {
        node.kind == .prompt || node.kind == .imagePrompt || node.kind == .videoPrompt || node.kind == .promptEnhancer || node.kind == .imageDescriber || node.kind == .characterSheet
    }
    static func cardWidth(_ node: StudioNode) -> Double { node.kind == .prompt || node.kind == .imagePrompt || node.kind == .videoPrompt || node.kind == .promptEnhancer || node.kind == .imageDescriber || node.kind == .characterSheet ? 360 : isImage(node) || node.kind == .shotSequence ? 320 : 240 }
    /// Sockets sit on the card edge with their labels outside it, so they never
    /// push card content down. Every node in a family shares one port rhythm.
    static func portTop(_ node: StudioNode) -> Double { isPromptStyled(node) ? 88 : 70 }
    static func portSpacing(_ node: StudioNode) -> Double { 42 }
    static func socketX(_ node: StudioNode, direction: PortDirection) -> Double { direction == .input ? 0 : cardWidth(node) }
    static func socketY(_ node: StudioNode, index: Int) -> Double { portTop(node) + Double(index) * portSpacing(node) }
    // Prompt-style cards share the same header and content treatment. Their
    // preview must start at a stable distance below that header; deriving the
    // position from port count makes Image Prompt and Video Prompt cards grow
    // an unnecessary gap before their main content.
    static func previewTop(_ node: StudioNode) -> Double {
        // Every other node has the compact header, then content 8pt below it.
        isPromptStyled(node) ? 56 : 48
    }
    static func previewHeight(_ node: StudioNode) -> Double { previewHeight(node, output: nil) }
    static func previewHeight(_ node: StudioNode, output: RuntimeValue?) -> Double {
        if node.kind == .prompt { return 348 }
        if node.kind == .imagePrompt || node.kind == .videoPrompt || node.kind == .promptEnhancer || node.kind == .imageDescriber || node.kind == .characterSheet { return 300 }
        if node.kind == .shotSequence { return 118 }
        if isImage(node) || node.kind.outputType == .video {
            let width = max(cardWidth(node) - bodyInset * 2, 1)
            return width / mediaAspectRatio(node, output: output)
        }
        return 82
    }
    static func cardHeight(_ node: StudioNode) -> Double { cardHeight(node, output: nil) }
    static func cardHeight(_ node: StudioNode, output: RuntimeValue?) -> Double {
        let previewBottom = previewTop(node) + previewHeight(node, output: output) + footerReserve
        let lastSocket = socketY(node, index: max(0, max(node.inputPorts.count, node.outputPorts.count) - 1))
        return max(previewBottom, lastSocket + footerReserve)
    }
    static func leadingOverflow(_ node: StudioNode) -> Double { node.inputPorts.isEmpty ? 7 : socketRailWidth }
    static func trailingOverflow(_ node: StudioNode) -> Double { node.outputPorts.isEmpty ? 7 : socketRailWidth }

    private static func mediaAspectRatio(_ node: StudioNode, output: RuntimeValue?) -> Double {
        switch output {
        case .image(let url):
            if let ratio = imageAspectRatio(url) { return ratio }
        case .video(let url):
            // Video metadata is asynchronous in modern AVFoundation. Waiting for it
            // synchronously here used to block SwiftUI's main layout pass for every
            // rendered card. The canvas player measures the clip and records it;
            // until then the node's requested dimensions below stand in.
            if let ratio = videoAspectRatios.ratio(for: url) { return ratio }
        default: break
        }
        if node.kind == .videoInput, let path = node.videoPath,
           let ratio = videoAspectRatios.ratio(for: URL(fileURLWithPath: path)) { return ratio }
        if (node.kind == .imageInput || node.kind == .maskInput), let path = node.imagePath,
           let ratio = imageAspectRatio(URL(fileURLWithPath: path), cache: false) { return ratio }
        if isImage(node) { return Double(max(node.width, 1)) / Double(max(node.height, 1)) }
        if node.kind == .endCard, let card = node.endCardSettings { return Double(max(card.width, 1)) / Double(max(card.height, 1)) }
        if node.kind.outputType == .video { return Double(max(node.video.width, 1)) / Double(max(node.video.height, 1)) }
        return 1
    }

    private static func imageAspectRatio(_ url: URL, cache: Bool = true) -> Double? {
        if cache, let cached = imageAspectRatios.value(for: url) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        let ratio = width.doubleValue / height.doubleValue
        if cache { imageAspectRatios.insert(ratio, for: url) }
        return ratio
    }

}

/// Canvas layout is recalculated frequently while scrolling, zooming, and dragging.
/// Generated media paths are immutable, so a small thread-safe cache avoids reopening
/// the same image header on every layout pass without retaining image pixel data.
private final class MediaAspectRatioCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    private let limit = 256

    func value(for url: URL) -> Double? {
        lock.withLock { values[url.standardizedFileURL.path] }
    }

    func insert(_ value: Double, for url: URL) {
        lock.withLock {
            if values.count >= limit { values.removeAll(keepingCapacity: true) }
            values[url.standardizedFileURL.path] = value
        }
    }
}

/// Video shapes measured off the main layout pass. Reads register with Observation,
/// so the canvas re-measures a card when its clip's real proportions arrive.
final class VideoAspectRatioStore: Observable, @unchecked Sendable {
    private let registrar = ObservationRegistrar()
    private let cache = MediaAspectRatioCache()

    func ratio(for url: URL) -> Double? {
        registrar.access(self, keyPath: \.cache)
        return cache.value(for: url)
    }

    func record(_ ratio: Double, for url: URL) {
        guard ratio.isFinite, ratio > 0, cache.value(for: url) != ratio else { return }
        registrar.withMutation(of: self, keyPath: \.cache) { cache.insert(ratio, for: url) }
    }
}

enum PortDataType: String, Codable, CaseIterable, Sendable { case text, textArray, number, image, video, shotSequence }
enum PortDirection: String, Codable, Sendable { case input, output }
struct PortDescriptor: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var label: String
    var direction: PortDirection
    var type: PortDataType
    var required = true
    var repeatable = false
}
struct DynamicInputPort: Identifiable, Codable, Hashable, Sendable {
    var id: String = "input-\(UUID().uuidString.lowercased())"
    var label: String
    var type: PortDataType = .text

    /// True for names GenStudio generated ("Part 3", "Variable 2"). A name the author typed is never renumbered or trimmed away.
    func isAutomaticallyNamed(prefix: String) -> Bool {
        label == prefix || (label.hasPrefix(prefix + " ") && Int(label.dropFirst(prefix.count + 1)) != nil)
    }
}

/// Production-reference layouts supported by the Character Sheet node.
/// These are intentionally subject classes rather than visual styles: the
/// supplied images remain authoritative for whether the result is 2D, 3D,
/// photographic, painterly, or otherwise stylised.
enum CharacterSheetPose: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case original, standing, seated
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var instruction: String {
        switch self {
        case .original:
            "Keep the subject's existing body pose and age unchanged. All four body panels show that original pose and body shape from different camera positions. Preserve the same head-to-body ratio, limb lengths, and points of contact with the ground. Rotate only the viewpoint around the unchanged subject."
        case .standing:
            "All four whole-body views show the subject standing in one relaxed natural pose, feet on the ground. Preserve the original apparent age, head-to-body ratio, limb lengths, and body shape. Rotate only the viewpoint around that same standing subject."
        case .seated:
            "All four whole-body views show the subject seated on the same surface as the source subject. Keep one comfortable seated pose throughout the front, three-quarter, side, and rear views. Preserve the original apparent age, head-to-body ratio, limb lengths, and body shape. Rotate only the viewpoint around that same seated subject."
        }
    }
}

enum CharacterSheetSubject: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case person
    case animatedCharacter
    case animal
    case product

    var id: String { rawValue }

    var title: String {
        switch self {
        case .person: "People"
        case .animatedCharacter: "Character"
        case .animal: "Animal"
        case .product: "Product"
        }
    }

    var promptSubjectName: String {
        switch self {
        case .person: "person"
        case .animatedCharacter: "character"
        case .animal: "animal"
        case .product: "product"
        }
    }

    var generationLayoutInstructions: String {
        switch self {
        case .animatedCharacter:
            """
            Portrait board, ten panels in three rows. Top half: four complete body views, ordered front, front three-quarter turned toward the left of the page, true side profile facing right, and rear. Use one relaxed neutral pose suited to the character's anatomy; separate limbs enough to read the silhouette. Keep the same body scale and baseline in all four views, with all extremities inside their panels.
            Middle third: three large head studies, ordered neutral front, three-quarter with one mild characteristic expression, and true profile facing right. Bottom strip: three close-ups of existing defining details, prioritising costume construction, a signature accessory, and hands or feet. Preserve the established 2D or 3D medium, line weight, shape language, facial construction, proportions, palette, and asymmetric features. Expressions change facial muscles while keeping the same facial structure.
            """
        case .person:
            """
            Portrait board, ten panels in three rows. Top half: four complete body views, ordered straight front, front three-quarter at 45 degrees, true side profile at 90 degrees, and rear at 180 degrees. Keep the same body scale and baseline across rotations, showing the whole head, hands, feet, clothing, and footwear with breathing room.
            Middle third: three large portraits, ordered neutral front, three-quarter with a subtle natural smile, and true profile. Bottom strip: three tight detail crops from that same subject: garment texture and fastenings, one hand with its sleeve, and the foot area exactly as originally dressed. These are literal magnifications of visible features, retaining only the original garments and adornments. Match facial geometry, apparent age, skin texture, hairline, hair length, eye colour, body proportions, garment construction, and accessory placement across every view. Preserve the established photographic or illustrated treatment.
            """
        case .animal:
            """
            Landscape board, six spacious panels in two rows of three. Upper row: complete side profile facing left, front three-quarter view, and complete side profile facing right. Lower row: complete rear view, a large three-quarter head study, and a close-up of the distinctive coat, feather, scale, or skin markings.
            Preserve the animal's existing species-appropriate posture and natural joint articulation in every rotation. Keep complete ears, legs or wings, paws or hooves, and tail where visible. Allow long bodies and tails to fit with clear margins. All body views share one scale and baseline; head and marking studies are enlarged independently. Preserve the same individual, life stage, muzzle or beak geometry, anatomy, coat pattern, and established visual medium. Keep left and right markings on their actual sides through each rotation.
            """
        case .product:
            """
            Landscape board, six evenly sized panels in two rows of three. Upper row: straight front elevation, front three-quarter view, and true side elevation. Lower row: rear elevation, top view, and a macro study of an existing distinctive material, seam, control, or brand detail. Keep the complete product inside each overall view, with one scale, consistent camera distance, and minimal perspective distortion; only the detail study changes magnification.
            Preserve the same product instance, silhouette, geometry, proportions, component count, seams, controls, openings, surface finish, colours, existing label placement, and legible branding. Keep its assembled state and the established photographic, illustrated, or rendered medium. Hidden surfaces use a restrained continuation of visible construction. This is a visual appearance reference, not a measured engineering drawing.
            """
        }
    }

    var recommendedCanvas: (width: Int, height: Int) {
        switch self {
        case .person, .animatedCharacter: (816, 1024)
        case .animal, .product: (1024, 768)
        }
    }

    var layoutSummary: String {
        switch self {
        case .person, .animatedCharacter: "Portrait · four body views, three face studies, three defining details."
        case .animal: "Landscape · four body views, one head study, one marking detail."
        case .product: "Landscape · five overall views and one material or construction detail."
        }
    }

    var heightLabel: String {
        switch self {
        case .person: "Height / infant length (cm)"
        case .animatedCharacter: "Character height (cm)"
        case .animal: "Shoulder height (cm)"
        case .product: "Product height (cm)"
        }
    }

    var heightHelp: String {
        switch self {
        case .person: "Enter a known height, or body length for an infant. Leave blank if unknown; a seated pose is not a standing-height measurement."
        case .animal: "For standing quadrupeds, measure to the shoulder (withers). Leave blank for other body plans or when unknown."
        default: "Enter the known or intentionally designed height. Leave blank if unknown."
        }
    }
}

enum PortPresentation {
    static func socketIsFilled(_ port: PortDescriptor, connectedInputPortIDs: Set<String>) -> Bool {
        port.direction == .output || connectedInputPortIDs.contains(port.id)
    }
}

enum NodeKind: String, Codable, CaseIterable, Sendable {
    case prompt, imagePrompt, videoPrompt, promptEnhancer, promptTemplate, combineText, textArray, listSelect, number, numberToText, textModel
    case imageInput, videoInput, imageGenerator, imageUpscale, imageDescriber, characterSheet, imageResize, imageCrop, imageBlend, imageCompare, imageRotateFlip, imageBlur, imageInvert, colourCorrect, extractFrame
    case maskInput, maskOperations
    case textRouter, imageRouter, videoRouter, textPreview, imagePreview, videoPreview, stickyNote
    case textToVideo, imageToVideo, startEndVideo, guidedShot, videoToVideo, frameInterpolate, videoUpscale, instagramExport, shotSequence, animatic, assembleVideo, endCard, textOverlay, voiceover

    var title: String {
        switch self {
        case .prompt: "Prompt"; case .imagePrompt: "Image Prompt"; case .videoPrompt: "Video Prompt"; case .promptEnhancer: "Prompt Enhancer"; case .promptTemplate: "Prompt Template"; case .combineText: "Combine Text"
        case .number: "Number"; case .numberToText: "Number to Text"; case .textModel: "Local Text"
        case .imageInput: "Image Input"; case .videoInput: "Video Input"; case .imageGenerator: "Image Generator"
        case .imageUpscale: "Image Upscale"
        case .imageResize: "Image Resize"; case .imageCrop: "Image Crop"; case .imageBlend: "Image Blend"
        case .imageCompare: "Image Compare"; case .extractFrame: "Extract Frame"
        case .textRouter: "Text Router"; case .imageRouter: "Image Router"; case .videoRouter: "Video Router"
        case .textPreview: "Text Preview"; case .imagePreview: "Image Preview"; case .videoPreview: "Video Preview"
        case .imageDescriber: "Image Describer"
        case .characterSheet: "Character Sheet"
        case .stickyNote: "Sticky Note"
        case .textArray: "Text Array"; case .listSelect: "List Select"
        case .imageRotateFlip: "Image Rotate / Flip"; case .imageBlur: "Image Blur"; case .imageInvert: "Image Invert"; case .colourCorrect: "Colour Correct"
        case .maskInput: "Mask Input"; case .maskOperations: "Mask Operations"
        case .textToVideo: "Text to Video"; case .imageToVideo: "Image to Video"; case .startEndVideo: "Start/End Video"
        case .guidedShot: "Guided Shot"; case .videoToVideo: "Video to Video"; case .frameInterpolate: "Frame Interpolation"; case .videoUpscale: "Video Upscale"; case .instagramExport: "Social Export"; case .shotSequence: "Shot Sequence"
        case .animatic: "Animatic"; case .assembleVideo: "Stitcher"; case .endCard: "End Card"; case .textOverlay: "Text Overlay"; case .voiceover: "Voiceover"
        }
    }
    var detail: String {
        switch self {
        case .prompt: "Write text to feed another node."
        case .imagePrompt: "Build an image prompt from simple creative decisions, then connect it to Image Generator."
        case .videoPrompt: "Build a short, source-aware video prompt with camera and motion direction."
        case .promptEnhancer: "Rewrite a rough prompt into one written for the node it feeds. A local model reads where the prompt is going (image, video, its length and size) and looks at the pictures that node receives, then writes the prompt an AI model responds to best."
        case .promptTemplate: "Write a prompt containing {{name}} placeholders. Each placeholder is replaced by the text connected to the input of the same name."
        case .combineText: "Join the connected text inputs, top to bottom, with the separator between them. A new socket appears each time you connect one; \\n in the separator means a line break."
        case .number: "Supply a numeric value to another node."
        case .numberToText: "Convert a connected number into text."
        case .textModel: "Generate text using the model selected for this node."
        case .imageDescriber: "Describe one or more ordered images using a local vision model, an optional expert persona and editable instructions."
        case .characterSheet: "Write a fixed production-ready turnaround brief for People, Character, Animal, or Product. Connect original images directly to Image Generator reference inputs."
        case .imageInput: "Import an existing image from your Mac. This node supplies image pixels to the workflow."
        case .videoInput: "Import an existing video from your Mac."
        case .imageGenerator: "Generate an image from a prompt. FLUX.2 Klein can use up to three ordered Reference images; other recipes accept only one. With Klein you can also name what each Reference supplies, which is sent ahead of your prompt."
        case .imageUpscale: "Enlarge a connected image 2× or 4× with a local learned upscaler. Learned detail may modify faces, text, logos and fine patterns; compare with the source at 100%. Use Image Resize instead when exact pixels matter."
        case .imageResize: "Resize a connected image to the specified pixel dimensions."
        case .imageCrop: "Crop a connected image using normalized bounds from 0 to 1. X + Width and Y + Height must not exceed 1."
        case .imageBlend: "Composite the foreground over the background using opacity. Both images must have identical pixel dimensions."
        case .imageCompare: "View two connected images and choose which flows through Selected."
        case .extractFrame: "Extract an image from a connected video at a time in seconds."
        case .textRouter, .imageRouter, .videoRouter: "Send the same input through two independently connectable outputs."
        case .textPreview, .imagePreview, .videoPreview: "Inspect the connected value after running this node."
        case .stickyNote: "Add a note to your workflow."
        case .textArray: "Split connected text into up to 256 ordered items. Literal \\n means a line break; empty input produces an empty list. No automatic generation."
        case .listSelect: "Select exactly one item by its 1-based position. This does not run a batch."
        case .imageRotateFlip: "Flip an image, then rotate clockwise in 90-degree increments."
        case .imageBlur: "Apply local Gaussian blur in pixels; edge pixels are extended to avoid dark borders."
        case .imageInvert: "Invert image RGB colors while preserving alpha."
        case .colourCorrect: "Match a generated image's overall colour and tonal distribution to a source image while preserving its detail and alpha."
        case .maskInput: "Import an existing mask image from your Mac. White marks the area to change; black is preserved. This node supplies mask pixels to the workflow."
        case .maskOperations: "Invert, grow or shrink, and feather a connected mask using deterministic Core Image morphology and blur — no model is involved. Connect a Source Image to validate the mask matches its exact pixel dimensions before it is used."
        case .textToVideo: "Generate a short clip locally from a prompt using an installed compatible video recipe."
        case .imageToVideo: "Animate a start image with a motion prompt. Its aspect ratio is preserved within the selected recipe's supported dimensions."
        case .startEndVideo: "Generate a transition from a start image to an end image with a dedicated first/last-frame recipe."
        case .guidedShot: "Generate one shot through several timed frames from a Shot Sequence in a single job. Requires native multi-anchor support."
        case .videoToVideo: "Re-generate an existing clip from its frames and an edit prompt with a dedicated video-to-video recipe."
        case .frameInterpolate: "Create smooth delivery frames locally with Metal-accelerated RIFE. This changes frame rate without paying to diffuse every delivery frame."
        case .videoUpscale: "Enlarge a connected video 2× or 4× by upscaling each frame independently with a local learned model, then re-encoding with the original timing and audio. Frame-based restoration only: it does not use adjacent frames as a temporal condition and can shimmer or change fine detail between frames. Enlarging a small clip here is much faster than generating at the larger size: measured on Apple M1 Max, generating at 320 × 192 and upscaling 4× to 1280 × 768 took about 3 minutes for a one-second clip, against an estimated 15 minutes generating at 1280 × 768 directly. Each frame costs about 11 seconds, so long clips take proportionally longer."
        case .instagramExport: "Prepare a connected video for social delivery with its sound: 9:16 (Reels, Status), 4:5 (feed), 1:1 (square) or 16:9 (YouTube), as H.264 at 1080 px. Aspect-fill crops the edges when necessary. A 24, 25 or 30 fps source keeps its frame rate; interpolate slower drafts to 30 fps first."
        case .shotSequence: "Order still frames with stable slots, hold times, transition notes and cut/continuous boundaries."
        case .animatic: "Render a Shot Sequence as a deterministic timed slideshow with hard cuts. No AI motion."
        case .assembleVideo: "Stitch every clip you connect into one finished video, in slot order. Trim the unsettled frames off each AI clip, choose a cut, cross-dissolve or dip to black at each join, fit or fill mixed shapes, set each clip's sound level, and lay music under the lot. Rendered locally, no model."
        case .voiceover: "Speak a script over a finished video with a local voice model. Describe the voice in plain words (for example a warm South African woman); clip sound and music dip under it. Every take sounds slightly different."
        case .textOverlay: "Put a caption over a clip (an offer, a price, \"Book now\") at the top, middle or lower third, for the whole clip or a time window. Rendered locally in seconds; the clip's sound is kept."
        case .endCard: "The closing card of an advert: your logo, headline, offer and contact details on a brand colour or a darkened picture. Rendered locally in seconds, no model; outputs a short clip for the Stitcher and a still for posters or WhatsApp Status."
        }
    }
    var category: String {
        switch self {
        case .prompt, .imagePrompt, .videoPrompt, .promptEnhancer, .characterSheet, .promptTemplate, .combineText, .textArray, .listSelect, .number, .numberToText: "Inputs & Prompts"
        case .imageInput, .videoInput, .maskInput: "Media Inputs"
        case .textModel, .imageGenerator, .imageDescriber, .voiceover: "AI Generation"
        case .textToVideo, .imageToVideo, .startEndVideo, .guidedShot, .videoToVideo: "Video Generation"
        case .imageResize, .imageCrop, .imageBlend, .imageUpscale, .imageRotateFlip, .imageBlur, .imageInvert, .colourCorrect, .maskOperations: "Image Editing"
        case .extractFrame, .frameInterpolate, .videoUpscale, .instagramExport, .shotSequence, .animatic, .assembleVideo, .endCard, .textOverlay: "Video Editing & Delivery"
        case .textRouter, .imageRouter, .videoRouter, .textPreview, .imagePreview, .videoPreview, .imageCompare: "Flow & Inspection"
        case .stickyNote: "Notes"
        }
    }
    static let categoryOrder = ["Inputs & Prompts", "Media Inputs", "AI Generation", "Video Generation", "Image Editing", "Video Editing & Delivery", "Flow & Inspection", "Notes"]
    /// High-frequency starting points for the canvas context menu. Keep this
    /// list short: every item is shown as a one-click action above the full catalog.
    static let quickAddOrder: [NodeKind] = [.prompt, .promptEnhancer, .imagePrompt, .imageGenerator, .imageInput, .imageUpscale, .textToVideo, .imageToVideo]
    var videoTask: VideoTask? { VideoTask.task(for: self) }
    /// True when executing this node invokes a learned/native model rather than
    /// simply moving or transforming an already-authored value.
    var usesModel: Bool {
        switch self {
        case .textModel, .promptEnhancer, .imageGenerator, .imageUpscale, .imageDescriber, .frameInterpolate, .videoUpscale, .voiceover:
            return true
        default:
            return videoTask != nil
        }
    }
    /// Prompt authors and prompt-composition nodes are upstream inputs. Their
    /// values are evaluated automatically when a consuming node runs, so a
    /// second per-card run control is misleading and unnecessary.
    var hidesCanvasRunControl: Bool {
        switch self {
        case .prompt, .imagePrompt, .videoPrompt, .characterSheet, .promptTemplate, .combineText, .textArray, .listSelect, .number, .numberToText, .stickyNote:
            return true
        default:
            return false
        }
    }
    var canvasRunLabel: String { usesModel ? "Run Model" : "Run" }
    var inputTypes: Set<PortDataType> { Set(defaultInputPorts.map(\.type)) }
    var outputType: PortDataType? { defaultOutputPorts.first?.type }
    // Image generators begin with three ordered, named reference sockets. A
    // compatible recipe may expose further dynamic reference sockets, but the
    // canvas must consult that recipe's declared capacity before adding one.
    var supportsDynamicImageInputs: Bool { self == .imageDescriber }
    var supportsDynamicTextInputs: Bool { self == .combineText || self == .promptTemplate }
    var supportsDynamicVideoInputs: Bool { self == .assembleVideo }
    /// These initial sockets preserve the familiar ordered reference layout.
    /// Further sockets, when an exact adapter contract permits them, are kept
    /// in `dynamicInputs` so saved workflows retain their explicit wiring.
    static let imageGeneratorReferencePortIDs = ["referenceImage", "referenceImage2", "referenceImage3"]

    var defaultInputPorts: [PortDescriptor] {
        func input(_ id: String, _ label: String, _ type: PortDataType, required: Bool = true) -> PortDescriptor { .init(id: id, label: label, direction: .input, type: type, required: required) }
        return switch self {
        case .textModel: [input("prompt", "Prompt", .text)]
        case .promptEnhancer: [input(PromptEnhancer.roughPromptPortID, "Rough Prompt", .text), input(PromptEnhancer.imagePortID, "Image", .image, required: false)]
        case .imageDescriber: [input("image", "Image 1", .image)]
        case .textArray: [input("text", "Text", .text)]
        case .listSelect: [input("items", "Items", .textArray)]
        case .numberToText, .textRouter, .textPreview: [input("text", "Text", self == .numberToText ? .number : .text)]
        case .imageGenerator: [
            input("prompt", "Prompt", .text),
            input("referenceImage", "Reference 1", .image, required: false),
            input("referenceImage2", "Reference 2", .image, required: false),
            input("referenceImage3", "Reference 3", .image, required: false)
        ]
        case .imageResize, .imageCrop, .imageRotateFlip, .imageBlur, .imageInvert, .imageRouter, .imagePreview, .imageUpscale: [input("image", "Image", .image)]
        case .maskOperations: [input("mask", "Mask", .image), input("source", "Source Image", .image, required: false)]
        case .videoRouter, .videoPreview: [input("video", "Video", .video)]
        case .imageBlend: [input("background", "Background", .image), input("foreground", "Foreground", .image), input("opacity", "Opacity", .number, required: false)]
        case .colourCorrect: [input("source", "Source", .image), input("generated", "Generated", .image)]
        case .imageCompare: [input("a", "Image A", .image), input("b", "Image B", .image)]
        case .extractFrame: [input("video", "Video", .video), input("time", "Time", .number, required: false)]
        case .textToVideo: [input("prompt", "Prompt", .text), input("negativePrompt", "Negative", .text, required: false)]
        case .imageToVideo: [input("startImage", "Start Image", .image), input("prompt", "Motion Prompt", .text)]
        case .startEndVideo: [input("startImage", "Start Image", .image), input("endImage", "End Image", .image), input("prompt", "Transition", .text)]
        case .guidedShot: [input("sequence", "Frames", .shotSequence), input("prompt", "Direction", .text)]
        case .videoToVideo: [input("sourceVideo", "Source Clip", .video), input("prompt", "Edit Prompt", .text)]
        case .frameInterpolate, .videoUpscale, .instagramExport, .textOverlay: [input("video", "Video", .video)]
        case .voiceover: [input("video", "Video", .video), input("script", "Script", .text, required: false)]
        case .animatic: [input("sequence", "Sequence", .shotSequence)]
        case .endCard: [input("logo", "Logo", .image, required: false), input("background", "Background", .image, required: false)]
        default: []
        }
    }
    var defaultOutputPorts: [PortDescriptor] {
        func output(_ id: String, _ label: String, _ type: PortDataType) -> PortDescriptor { .init(id: id, label: label, direction: .output, type: type) }
        return switch self {
        case .prompt, .imagePrompt, .promptTemplate, .combineText, .listSelect, .numberToText, .textModel, .imageDescriber, .characterSheet, .textPreview: [output("text", "Text", .text)]
        case .promptEnhancer: [output(PromptEnhancer.outputPortID, "Enhanced", .text)]
        case .videoPrompt: [output("prompt", "Prompt", .text), output("avoid", "Avoid", .text)]
        case .number: [output("number", "Number", .number)]
        case .textArray: [output("items", "Items", .textArray)]
        case .imageInput, .imageGenerator, .imageUpscale, .imageResize, .imageCrop, .imageBlend, .imageRotateFlip, .imageBlur, .imageInvert, .colourCorrect, .imagePreview, .extractFrame: [output("image", "Image", .image)]
        case .maskInput: [output("image", "Mask", .image)]
        case .maskOperations: [output("mask", "Mask", .image)]
        case .videoInput, .videoPreview, .textToVideo, .imageToVideo, .startEndVideo, .guidedShot, .videoToVideo, .frameInterpolate, .videoUpscale, .instagramExport, .animatic, .assembleVideo, .textOverlay, .voiceover: [output("video", "Video", .video)]
        case .shotSequence: [output("sequence", "Sequence", .shotSequence)]
        case .endCard: [output("video", "Video", .video), output("image", "Card Image", .image)]
        case .textRouter: [output("a", "A", .text), output("b", "B", .text)]
        case .imageRouter: [output("a", "A", .image), output("b", "B", .image)]
        case .videoRouter: [output("a", "A", .video), output("b", "B", .video)]
        case .imageCompare: [output("selected", "Selected", .image), output("a", "Image A", .image), output("b", "Image B", .image)]
        case .stickyNote: []
        }
    }
}

struct StudioNode: Identifiable, Codable, Hashable, Sendable {
    var id = UUID(); var kind: NodeKind; var label: String; var position: CanvasPoint
    var prompt = ""; var model = ""; var temperature = 0.7; var maxTokens = 64
    var imagePath: String?; var videoPath: String?; var numberValue = 0.0; var separator = "\n"
    var arrayDelimiter = "\\n"; var arrayTrim = true; var listIndex = 1
    var quarterTurns = 0; var flipHorizontal = false; var flipVertical = false; var blurRadius = 8.0
    var width = 512; var height = 512; var imageSeed = 424242
    /// Nil migrates the original stock seeds to variation mode; custom legacy seeds stay locked.
    var generationSeedLocked: Bool?
    /// When on, dragging or typing one canvas dimension moves the other to keep the chosen ratio.
    var ratioLocked = false
    var selectedTakeID: UUID?
    /// Set when the author has locked this node as final: the chosen result is saved in the project folder
    /// and stands in for the node everywhere downstream. Nil while the node is still being worked on.
    var finalized: FinalRecord?
    var seedLocked: Bool {
        get { generationSeedLocked ?? (kind == .imageGenerator ? imageSeed != 424242 : video.seed >= 0 && video.seed != 424243) }
        set { generationSeedLocked = newValue }
    }
    var supportsTakes: Bool { kind == .imageGenerator || kind == .imageUpscale || kind == .frameInterpolate || kind == .videoUpscale || kind == .instagramExport || kind == .voiceover || kind.videoTask != nil }
    var cropX = 0.0; var cropY = 0.0; var cropWidth = 1.0; var cropHeight = 1.0
    var opacity = 0.5; var comparisonSelection = 0
    var dynamicInputs: [DynamicInputPort] = []
    var imageDescriberPersona: PersonaExpert?
    var characterSheetSubject: CharacterSheetSubject = .person
    /// Author-supplied physical size only. Nil means unknown, never inferred from pixels.
    var characterSheetHeightCM: Double?
    var characterSheetPose: CharacterSheetPose = .original
    /// Structured, local-only creative brief for Image Prompt nodes.
    var imagePromptSettings: ImagePromptSettings?
    /// Structured, local-only direction for a single moving shot.
    var videoPromptSettings: VideoPromptSettings?
    /// What a Prompt Enhancer writes for. Nil means Auto: follow the node its output feeds.
    var promptEnhancerTarget: PromptEnhancerTarget?
    /// Absent for nodes that predate these kinds, so older documents gain no new keys.
    var videoSettings: VideoGenerationSettings?
    var sequenceSpec: ShotSequenceSpec?
    var assemblySettings: AssemblySettings?
    /// End Card text, colours, size and length. Absent for every other kind.
    var endCardSettings: EndCardSettings?
    /// Text Overlay caption, position, timing and colours. Absent for every other kind.
    var textOverlaySettings: TextOverlaySettings?
    /// Voiceover script, voice description and mix. Absent for every other kind.
    var voiceoverSettings: VoiceoverSettings?
    /// Image-to-image strength. Absent for older documents; nil means the recipe default (0.75).
    var imageStrength: Double?
    /// What each Reference socket supplies, keyed by port ID. Absent for older
    /// documents. Keyed by port rather than by image because the role belongs to
    /// this generator's use of the socket: the same Image Input can feed two
    /// generators in different roles.
    var referenceRoles: [String: String]?
    /// Legacy saved setting from builds that required a first-run video opt-in. Ignored now.
    var experimentalVideoRecipeID: String?
    /// Exact recipe deliberately authorized for one first, unverified local image run.
    /// Keeping this separate from video opt-in prevents a model selection in one
    /// node family from silently authorizing another family.
    var experimentalImageRecipeID: String?
    /// Image Upscale settings. Absent for older documents; 4x/128 matches the proven capability defaults.
    var upscaleScale = 4
    /// 0 means Auto; otherwise 64, 128 or 256. Defaults to 128 until benchmarks justify Auto.
    var upscaleTileSize = 128
    /// Delivery frame rate for deterministic finishing nodes. Diffusion generation has its own fps.
    var deliveryFPS = 30
    /// Social Export shape. Absent for older documents, which stay vertical.
    var deliveryFormat: DeliveryFormat?
    var format: DeliveryFormat { get { deliveryFormat ?? .vertical } set { deliveryFormat = newValue } }
    /// Exact recipe deliberately authorized for one first, unverified local upscale run.
    /// Separate from image-generation opt-in so a generator model choice never
    /// silently authorizes an unverified upscaler recipe, and vice versa.
    var experimentalUpscaleRecipeID: String?
    /// Mask Operations settings. Absent for older documents; defaults are a no-op pass-through.
    var maskInvert = false
    var maskGrowShrink = 0
    var maskFeather = 0.0
    var video: VideoGenerationSettings { get { videoSettings ?? .measuredProbe } set { videoSettings = newValue } }
    var sequence: ShotSequenceSpec { get { sequenceSpec ?? .init() } set { sequenceSpec = newValue } }
    var assembly: AssemblySettings { get { assemblySettings ?? .init() } set { assemblySettings = newValue } }

    var inputPorts: [PortDescriptor] {
        if kind == .shotSequence {
            return sequence.anchors.map { PortDescriptor(id: $0.id, label: $0.label, direction: .input, type: .image, required: false, repeatable: true) }
        }
        // Text-joining sockets are optional: a free spare socket is always on offer, and the node
        // itself checks that at least one is connected (Combine Text) or that every {{name}} it uses is.
        let socketsAreRequired = kind != .imageGenerator && !kind.supportsDynamicTextInputs
        let dynamic = dynamicInputs.map { PortDescriptor(id: $0.id, label: $0.label, direction: .input, type: $0.type, required: socketsAreRequired, repeatable: true) }
        if kind == .imageGenerator { return kind.defaultInputPorts + dynamic }
        if kind.supportsDynamicImageInputs { return dynamic }
        return kind.supportsDynamicTextInputs || kind.supportsDynamicVideoInputs ? dynamic : kind.defaultInputPorts
    }
    var outputPorts: [PortDescriptor] { kind.defaultOutputPorts }
    var imageGeneratorReferencePortIDs: [String] {
        guard kind == .imageGenerator else { return [] }
        return inputPorts.filter { $0.type == .image }.map(\.id)
    }
    mutating func ensureInitialDynamicInputs() {
        guard dynamicInputs.isEmpty else { return }
        guard kind != .imageGenerator else { return }
        if kind.supportsDynamicImageInputs { dynamicInputs = [.init(id: "image", label: "Image 1", type: .image)]; return }
        if kind.supportsDynamicVideoInputs { dynamicInputs = [.init(label: "Clip 1", type: .video), .init(label: "Clip 2", type: .video)]; return }
        guard kind.supportsDynamicTextInputs else { return }
        // Joining needs two parts to be legible; a template can start with one variable.
        dynamicInputs = kind == .combineText ? [.init(label: "Part 1"), .init(label: "Part 2")] : [.init(label: "Variable 1")]
    }
    /// Prefix of the automatically named sockets on a text-joining node.
    var textSocketPrefix: String { kind == .promptTemplate ? "Variable" : "Part" }

    static let imageDescriberInstructions = "You are an expert image analyst tasked with providing detailed accurate and helpful descriptions of images. Your goal is to make visual content accessible through clear comprehensive text descriptions. Be objective and factual using clear descriptive language. Organize information from general to specific and include relevant context. Start with a brief overview of what the image shows then describe the main subjects and setting. Include visual details like colors lighting, textures, style, genre, contrast and composition. Transcribe any visible text accurately. Use specific concrete language and mention spatial relationships. For people focus on actions clothing and general appearance respectfully. For data visualizations explain the information presented. Write as if describing to someone who cannot see the image including important context for understanding. Balance thoroughness with clarity and provide descriptions in natural flowing narrative form. Your description shouldn't be longer than 500 characters"

    static func imageDescriberInstructions(for persona: PersonaExpert?) -> String {
        guard let persona else { return imageDescriberInstructions }
        return "\(imageDescriberInstructions)\n\nApply this additional expert perspective while keeping the same objective, natural narrative and 500-character limit:\n\(persona.systemPromptBlock)"
    }

    /// A deterministic production brief. Identity comes from the original pixels
    /// wired to Image Generator, not from a vision model's lossy re-description.
    var characterSheetBrief: String { Self.characterSheetPrompt(for: characterSheetSubject, heightCM: characterSheetHeightCM, pose: characterSheetPose) }

    static func characterSheetPrompt(for subject: CharacterSheetSubject, heightCM: Double? = nil, pose: CharacterSheetPose = .original) -> String {
        let poseInstruction = subject == .person || subject == .animatedCharacter ? pose.instruction : ""
        let measure: String
        if let heightCM, heightCM.isFinite, heightCM > 0, heightCM <= 100_000 {
            let caption = subject.heightLabel.replacingOccurrences(of: " (cm)", with: "") + ": " + NumberText.string(heightCM) + " cm"
            measure = "Author-supplied size: \(caption). Keep this physical size consistent with the subject's proportions and pose. Put only the caption \"\(caption)\" in a small clear footer. Keep the background plain; this caption states the authored size, not a calibrated ruler."
        } else {
            measure = "Keep the margins and background plain, without measurement labels, rulers, grid lines, or biographical text."
        }
        return """
        Create a professional \(subject.promptSubjectName) reference sheet of the same single subject across every panel. Identity, design, and visual style remain constant; only the viewing angle and the specified study change.

        \(poseInstruction)
        \(subject.generationLayoutInstructions)

        Use a plain light neutral background, thin clean panel gutters, generous outer margins, and soft even studio lighting with neutral colour balance. Keep all defining surfaces in focus. Keep a consistent scale across comparable overall views; close-ups use their own scale. Each panel contains one view of the subject.
        \(measure)
        """
    }

    private enum CodingKeys: String, CodingKey { case generationSeedLocked, ratioLocked, selectedTakeID, finalized, arrayDelimiter, arrayTrim, listIndex, quarterTurns, flipHorizontal, flipVertical, blurRadius, id, kind, label, position, prompt, model, temperature, maxTokens, imagePath, videoPath, numberValue, separator, width, height, imageSeed, cropX, cropY, cropWidth, cropHeight, opacity, comparisonSelection, dynamicInputs, imageDescriberPersona, characterSheetSubject, characterSheetHeightCM, characterSheetPose, imagePromptSettings, videoPromptSettings, promptEnhancerTarget, videoSettings, sequenceSpec, assemblySettings, imageStrength, referenceRoles, experimentalVideoRecipeID, experimentalImageRecipeID, maskInvert, maskGrowShrink, maskFeather, upscaleScale, upscaleTileSize, experimentalUpscaleRecipeID, deliveryFPS, endCardSettings, textOverlaySettings, deliveryFormat, voiceoverSettings }
    init(id: UUID = UUID(), kind: NodeKind, label: String, position: CanvasPoint, prompt: String = "", model: String = "", temperature: Double? = nil, maxTokens: Int? = nil, imagePath: String? = nil, videoPath: String? = nil, numberValue: Double = 0, separator: String = "\n", width: Int = 512, height: Int = 512, imageSeed: Int = 424242, cropX: Double = 0, cropY: Double = 0, cropWidth: Double = 1, cropHeight: Double = 1, opacity: Double = 0.5, comparisonSelection: Int = 0, dynamicInputs: [DynamicInputPort]? = nil, imageDescriberPersona: PersonaExpert? = nil, characterSheetSubject: CharacterSheetSubject = .person) {
        self.id = id; self.kind = kind; self.label = label; self.position = position; self.prompt = prompt; self.model = model; self.temperature = temperature ?? (kind == .promptEnhancer ? PromptEnhancer.defaultTemperature : 0.7); self.maxTokens = maxTokens ?? (kind == .imageDescriber ? 1024 : kind == .promptEnhancer ? PromptEnhancer.defaultMaxTokens : 64); self.imagePath = imagePath; self.videoPath = videoPath; self.numberValue = numberValue; self.separator = separator; self.width = width; self.height = height; self.imageSeed = imageSeed; self.cropX = cropX; self.cropY = cropY; self.cropWidth = cropWidth; self.cropHeight = cropHeight; self.opacity = opacity; self.comparisonSelection = comparisonSelection; self.dynamicInputs = dynamicInputs ?? []; self.imageDescriberPersona = imageDescriberPersona; self.characterSheetSubject = characterSheetSubject
        if kind == .imageDescriber && prompt.isEmpty { self.prompt = Self.imageDescriberInstructions(for: imageDescriberPersona) }
        if kind == .characterSheet && prompt.isEmpty { self.prompt = Self.characterSheetPrompt(for: characterSheetSubject) }
        if kind == .imagePrompt { imagePromptSettings = .init() }
        if kind == .videoPrompt { videoPromptSettings = .init() }
        if dynamicInputs == nil { ensureInitialDynamicInputs() }
        if kind.videoTask != nil { videoSettings = .measuredProbe }
        if kind == .shotSequence { sequenceSpec = .init() }
        if kind == .assembleVideo { assemblySettings = .init() }
        if kind == .endCard { endCardSettings = .init() }
        if kind == .textOverlay { textOverlaySettings = .init() }
        if kind == .voiceover { voiceoverSettings = .init() }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); kind = try c.decode(NodeKind.self, forKey: .kind); label = try c.decode(String.self, forKey: .label); position = try c.decode(CanvasPoint.self, forKey: .position)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""; model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""; temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? (kind == .promptEnhancer ? PromptEnhancer.defaultTemperature : 0.7); maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? (kind == .imageDescriber ? 1024 : kind == .promptEnhancer ? PromptEnhancer.defaultMaxTokens : 64)
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath); videoPath = try c.decodeIfPresent(String.self, forKey: .videoPath); numberValue = try c.decodeIfPresent(Double.self, forKey: .numberValue) ?? 0; separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? "\n"
        imageSeed = try c.decodeIfPresent(Int.self, forKey: .imageSeed) ?? 424242; width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 512; height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 512; cropX = try c.decodeIfPresent(Double.self, forKey: .cropX) ?? 0; cropY = try c.decodeIfPresent(Double.self, forKey: .cropY) ?? 0; cropWidth = try c.decodeIfPresent(Double.self, forKey: .cropWidth) ?? 1; cropHeight = try c.decodeIfPresent(Double.self, forKey: .cropHeight) ?? 1; opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.5; comparisonSelection = try c.decodeIfPresent(Int.self, forKey: .comparisonSelection) ?? 0
        arrayDelimiter = try c.decodeIfPresent(String.self, forKey: .arrayDelimiter) ?? "\\n"; arrayTrim = try c.decodeIfPresent(Bool.self, forKey: .arrayTrim) ?? true; listIndex = try c.decodeIfPresent(Int.self, forKey: .listIndex) ?? 1
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0; flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false; flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false; blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 8
        if c.contains(.dynamicInputs) { dynamicInputs = try c.decode([DynamicInputPort].self, forKey: .dynamicInputs) } else { dynamicInputs = []; ensureInitialDynamicInputs() }
        imageDescriberPersona = try c.decodeIfPresent(PersonaExpert.self, forKey: .imageDescriberPersona)
        characterSheetSubject = try c.decodeIfPresent(CharacterSheetSubject.self, forKey: .characterSheetSubject) ?? .person
        characterSheetHeightCM = try c.decodeIfPresent(Double.self, forKey: .characterSheetHeightCM)
        characterSheetPose = try c.decodeIfPresent(CharacterSheetPose.self, forKey: .characterSheetPose) ?? .original
        imagePromptSettings = try c.decodeIfPresent(ImagePromptSettings.self, forKey: .imagePromptSettings)
        videoPromptSettings = try c.decodeIfPresent(VideoPromptSettings.self, forKey: .videoPromptSettings)
        promptEnhancerTarget = try c.decodeIfPresent(PromptEnhancerTarget.self, forKey: .promptEnhancerTarget)
        videoSettings = try c.decodeIfPresent(VideoGenerationSettings.self, forKey: .videoSettings)
        sequenceSpec = try c.decodeIfPresent(ShotSequenceSpec.self, forKey: .sequenceSpec)
        assemblySettings = try c.decodeIfPresent(AssemblySettings.self, forKey: .assemblySettings)
        imageStrength = try c.decodeIfPresent(Double.self, forKey: .imageStrength)
        referenceRoles = try c.decodeIfPresent([String: String].self, forKey: .referenceRoles)
        experimentalVideoRecipeID = try c.decodeIfPresent(String.self, forKey: .experimentalVideoRecipeID)
        experimentalImageRecipeID = try c.decodeIfPresent(String.self, forKey: .experimentalImageRecipeID)
        upscaleScale = try c.decodeIfPresent(Int.self, forKey: .upscaleScale) ?? 4
        upscaleTileSize = try c.decodeIfPresent(Int.self, forKey: .upscaleTileSize) ?? 128
        experimentalUpscaleRecipeID = try c.decodeIfPresent(String.self, forKey: .experimentalUpscaleRecipeID)
        generationSeedLocked = try c.decodeIfPresent(Bool.self, forKey: .generationSeedLocked)
        ratioLocked = try c.decodeIfPresent(Bool.self, forKey: .ratioLocked) ?? false
        selectedTakeID = try c.decodeIfPresent(UUID.self, forKey: .selectedTakeID)
        finalized = try c.decodeIfPresent(FinalRecord.self, forKey: .finalized)
        maskInvert = try c.decodeIfPresent(Bool.self, forKey: .maskInvert) ?? false
        maskGrowShrink = try c.decodeIfPresent(Int.self, forKey: .maskGrowShrink) ?? 0
        maskFeather = try c.decodeIfPresent(Double.self, forKey: .maskFeather) ?? 0
        deliveryFPS = try c.decodeIfPresent(Int.self, forKey: .deliveryFPS) ?? 30
        if kind == .imageDescriber && prompt.isEmpty { prompt = Self.imageDescriberInstructions(for: imageDescriberPersona) }
        // Character Sheet is a fixed template, so reopened nodes receive current
        // category guidance. Locked final text is kept separately in finalized.
        if kind == .characterSheet { prompt = characterSheetBrief }
        if kind == .imagePrompt && imagePromptSettings == nil { imagePromptSettings = .init() }
        if kind == .videoPrompt && videoPromptSettings == nil { videoPromptSettings = .init() }
        endCardSettings = try c.decodeIfPresent(EndCardSettings.self, forKey: .endCardSettings)
        if kind == .endCard && endCardSettings == nil { endCardSettings = .init() }
        textOverlaySettings = try c.decodeIfPresent(TextOverlaySettings.self, forKey: .textOverlaySettings)
        deliveryFormat = try c.decodeIfPresent(DeliveryFormat.self, forKey: .deliveryFormat)
        voiceoverSettings = try c.decodeIfPresent(VoiceoverSettings.self, forKey: .voiceoverSettings)
        if kind == .voiceover && voiceoverSettings == nil { voiceoverSettings = .init() }
        if kind == .textOverlay && textOverlaySettings == nil { textOverlaySettings = .init() }
    }
}

struct StudioEdge: Identifiable, Codable, Hashable, Sendable {
    var id = UUID(); var sourceID: UUID; var sourcePortID: String; var targetID: UUID; var targetPortID: String; var type: PortDataType; var color: WireColor?
    init(id: UUID = UUID(), sourceID: UUID, targetID: UUID, type: PortDataType) {
        self.id = id; self.sourceID = sourceID; sourcePortID = "__legacy_output"; self.targetID = targetID; targetPortID = "__legacy_input"; self.type = type; color = nil
    }
    init(id: UUID = UUID(), sourceID: UUID, sourcePortID: String, targetID: UUID, targetPortID: String, type: PortDataType, color: WireColor? = nil) {
        self.id = id; self.sourceID = sourceID; self.sourcePortID = sourcePortID; self.targetID = targetID; self.targetPortID = targetPortID; self.type = type; self.color = color
    }
    private enum CodingKeys: String, CodingKey { case id, sourceID, sourcePortID, targetID, targetPortID, type, color }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); sourceID = try c.decode(UUID.self, forKey: .sourceID)
        sourcePortID = try c.decodeIfPresent(String.self, forKey: .sourcePortID) ?? ""; targetID = try c.decode(UUID.self, forKey: .targetID)
        targetPortID = try c.decodeIfPresent(String.self, forKey: .targetPortID) ?? ""; type = try c.decode(PortDataType.self, forKey: .type); color = try c.decodeIfPresent(WireColor.self, forKey: .color)
    }
}

enum WireColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, mint, cyan, blue, indigo, purple, pink, gray
    var title: String { rawValue.capitalized }
}

struct WorkflowProject: Identifiable, Codable, Hashable, Sendable {
    static let schemaVersion = 3
    var schemaVersion = Self.schemaVersion; var id = UUID(); var name: String; var nodes: [StudioNode]; var edges: [StudioEdge]
    var viewport = CanvasViewport(); var createdAt = Date(); var updatedAt = Date()
    /// The folder this project lives in, if it has one: its `.genstudio` file, and `Links/` holding the inputs and
    /// locked finals. Nil for a project that only exists in the app library.
    var homeFolder: String?

    /// Follow only text-preserving nodes. Explicit rewrites/compositions own
    /// their resulting prompt and must not inherit a sheet's layout by guesswork.
    func characterSheetSource(feeding nodeID: UUID) -> StudioNode? {
        var source = edges.first { $0.targetID == nodeID && $0.targetPortID == "prompt" }?.sourceID
        var visited = Set<UUID>()
        while let id = source, visited.insert(id).inserted,
              let node = nodes.first(where: { $0.id == id }) {
            if node.kind == .characterSheet { return node }
            guard node.kind == .textRouter || node.kind == .textPreview else { return nil }
            source = edges.first { $0.targetID == id && $0.targetPortID == "text" }?.sourceID
        }
        return nil
    }
    init(schemaVersion: Int = Self.schemaVersion, id: UUID = UUID(), name: String, nodes: [StudioNode], edges: [StudioEdge], viewport: CanvasViewport = .init(), createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name; self.nodes = nodes; self.edges = edges; self.viewport = viewport; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, nodes, edges, viewport, createdAt, updatedAt, homeFolder }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.schemaVersion).contains(version) else { throw StudioError.unsupportedSchema(version) }
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); name = try c.decode(String.self, forKey: .name); nodes = try c.decode([StudioNode].self, forKey: .nodes); edges = try c.decode([StudioEdge].self, forKey: .edges)
        viewport = try c.decodeIfPresent(CanvasViewport.self, forKey: .viewport) ?? .init(); createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(); updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        homeFolder = try c.decodeIfPresent(String.self, forKey: .homeFolder)
        if version == 1 { try migrateV1Edges() }
        else {
            guard edges.allSatisfy({ Self.validPersistedPortID($0.sourcePortID) && Self.validPersistedPortID($0.targetPortID) }) else {
                throw StudioError.validation("Saved v2 connections require nonblank, non-reserved endpoint identifiers.")
            }
        }
        migrateRemovedImageDescriberInstructionInputs()
        if version < 3 { migrateCharacterSheetsToDeterministicPrompts() }
        schemaVersion = Self.schemaVersion
        _ = try GraphValidator().validate(self, installedModels: nil, requireRunnableInputs: false)
    }
    private static func validPersistedPortID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !id.hasPrefix("__legacy")
    }
    private mutating func migrateRemovedImageDescriberInstructionInputs() {
        let describerIDs = Set(nodes.filter { $0.kind == .imageDescriber }.map(\.id))
        edges.removeAll { describerIDs.contains($0.targetID) && $0.targetPortID == "prompt" }
    }
    private mutating func migrateCharacterSheetsToDeterministicPrompts() {
        let sheetIDs = Set(nodes.filter { $0.kind == .characterSheet }.map(\.id))
        // These former inputs were consumed only by the removed vision pass.
        // Preserve the Character Sheet's text output and its downstream wires.
        edges.removeAll { sheetIDs.contains($0.targetID) }
        for index in nodes.indices where nodes[index].kind == .characterSheet {
            nodes[index].dynamicInputs = []
            nodes[index].model = ""
            nodes[index].prompt = nodes[index].characterSheetBrief
        }
    }
    private mutating func migrateV1Edges() throws {
        let legacyKinds: Set<NodeKind> = [.prompt, .textModel, .imageInput, .imageGenerator]
        guard nodes.allSatisfy({ legacyKinds.contains($0.kind) }) else { throw StudioError.validation("This v1 workflow contains a node kind that did not exist in schema v1.") }
        for index in edges.indices {
            guard let source = nodes.first(where: { $0.id == edges[index].sourceID }), let target = nodes.first(where: { $0.id == edges[index].targetID }) else { throw StudioError.validation("A legacy connection references a missing node.") }
            let sourcePort: String? = switch (source.kind, edges[index].type) {
            case (.prompt, .text), (.textModel, .text): "text"
            case (.imageInput, .image), (.imageGenerator, .image): "image"
            default: nil
            }
            let targetPort: String? = switch (target.kind, edges[index].type) {
            case (.textModel, .text), (.imageGenerator, .text): "prompt"
            case (.imageGenerator, .image): "referenceImage"
            default: nil
            }
            guard edges[index].sourcePortID.isEmpty, edges[index].targetPortID.isEmpty, let sourcePort, let targetPort else { throw StudioError.validation("This legacy connection shape cannot be migrated unambiguously.") }
            edges[index].sourcePortID = sourcePort
            edges[index].targetPortID = targetPort
        }
    }
}

struct PortAddress: Codable, Hashable, Sendable { let nodeID: UUID; let portID: String }
enum RuntimeValue: Codable, Hashable, Sendable { case text(String), textArray([String]), number(Double), image(URL), video(URL), shotSequence(ResolvedShotSequence) }
struct ExecutionArtifact: Identifiable, Codable, Hashable, Sendable { let id: UUID; let projectID: UUID; let targetID: UUID; let graphSnapshot: WorkflowProject; let values: [PortAddress: RuntimeValue]; let createdAt: Date; var mediaProvenance: [UUID: RenderedMediaProvenance]? = nil; var generatedNodeIDs: Set<UUID>? = nil; var mediaNames: [String: String]? = nil }
enum RunStatus: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, interrupted }
struct RunInputSnapshot: Codable, Hashable, Sendable {
    let projectID: UUID
    let nodeID: UUID
    let prompt: String
    let model: String
    let temperature: Double
    let maxTokens: Int
    var engineID: String? = nil
    var modelRecipe: ModelRecipe? = nil
    var imageWidth: Int? = nil
    var imageHeight: Int? = nil
    var imageSeed: Int? = nil
    var imageSteps: Int? = nil
    var videoRequest: VideoGenerationRequest? = nil
    var outputMedia: RenderedMediaProvenance? = nil
    var engineLogTail: String? = nil
    var imageRequest: ImageGenerationRequest? = nil
    var upscaleRequest: UpscaleRequest? = nil
    var upscaleVideoScale: Int? = nil
    var upscaleVideoTileSize: Int? = nil
    /// `prompt` remains the legacy authored-prompt field. These explicit fields
    /// make authored versus adapter-ready text auditable in new run records.
    var authoredPrompt: String? = nil
    var compiledPrompt: String? = nil
    var promptCompilerRecipeID: String? = nil
    var promptCompilerTask: String? = nil
    var promptCompilerDialect: PromptDialect? = nil
    var promptCompilerVersion: String? = nil
    var promptCompilerModelID: String? = nil
    var promptCompilerUsedFallback: Bool? = nil
    /// Prompt Enhancer runs only: identifies the rough prompt, settings, destination and pictures,
    /// so an unchanged enhancement is reused instead of asking the model again.
    var promptEnhancerFingerprint: String? = nil
    /// The engine process's own wall time, separate from model-file checks and graph work.
    var engineSeconds: Double? = nil
    var thermalStateAtStart: String? = nil
    var thermalStateAtEnd: String? = nil
}
struct RunRecord: Identifiable, Codable, Hashable, Sendable { let id: UUID; var snapshot: RunInputSnapshot; var status: RunStatus; let queuedAt: Date; var startedAt: Date?; var finishedAt: Date?; var error: String?; var outputID: UUID? }
struct TextOutput: Identifiable, Codable, Hashable, Sendable { let id: UUID; let runID: UUID; let projectID: UUID; let nodeID: UUID; let prompt: String; let model: String; let text: String; let createdAt: Date }
struct InstalledModel: Identifiable, Codable, Hashable, Sendable { var id: String { name }; let name: String; let size: Int64?; let digest: String? }

enum StudioError: LocalizedError, Equatable, Sendable {
    case validation(String), serviceUnavailable(String), malformedData(String), persistence(String), emptyResponse, timedOut, unsupportedSchema(Int)
    var errorDescription: String? {
        switch self { case .validation(let v): v; case .serviceUnavailable(let v): "Generation engine unavailable: \(v)"; case .malformedData(let v): "Saved data is unreadable: \(v)"; case .persistence(let v): "Could not save: \(v)"; case .emptyResponse: "The model returned an empty response."; case .timedOut: "Generation timed out."; case .unsupportedSchema(let v): "This workflow uses unsupported schema version \(v). GenStudio supports version \(WorkflowProject.schemaVersion)." }
    }
}


extension WorkflowProject {
    static let maximumTextSockets = 64

    /// Keeps a free socket at the end of every text-joining node (Combine Text, Prompt Template) so each new wire
    /// has somewhere to land and none replaces an earlier one. Surplus free trailing sockets that GenStudio
    /// named itself are dropped again, leaving exactly one; names the author typed are never touched.
    mutating func normalizeDynamicTextSockets() {
        for index in nodes.indices where nodes[index].kind.supportsDynamicTextInputs {
            let id = nodes[index].id
            let connected = Set(edges.filter { $0.targetID == id }.map(\.targetPortID))
            let prefix = nodes[index].textSocketPrefix
            let minimum = nodes[index].kind == .combineText ? 2 : 1
            while nodes[index].dynamicInputs.count > minimum {
                let ports = nodes[index].dynamicInputs
                guard !connected.contains(ports[ports.count - 1].id), !connected.contains(ports[ports.count - 2].id),
                      ports[ports.count - 1].isAutomaticallyNamed(prefix: prefix) else { break }
                nodes[index].dynamicInputs.removeLast()
            }
            guard nodes[index].dynamicInputs.count < Self.maximumTextSockets else { continue }
            if nodes[index].dynamicInputs.last.map({ connected.contains($0.id) }) ?? true {
                let used = Set(nodes[index].dynamicInputs.map(\.label))
                var ordinal = nodes[index].dynamicInputs.count + 1
                while used.contains("\(prefix) \(ordinal)") { ordinal += 1 }
                nodes[index].dynamicInputs.append(.init(label: "\(prefix) \(ordinal)"))
            }
        }
    }
}

/// One generation of a copied node, detached from any project so it can travel on the clipboard.
struct NodeGeneration: Codable, Hashable, Sendable {
    var createdAt: Date
    /// The copied nodes as they were configured when this generation ran (seed, model, size).
    var nodes: [StudioNode]
    /// Outputs of the copied nodes only, keyed by the source node ids.
    var values: [PortAddress: RuntimeValue]
    var generatedNodeIDs: Set<UUID>
    var mediaProvenance: [UUID: RenderedMediaProvenance]?
    var mediaNames: [String: String]?
    /// Source nodes whose selected take this was.
    var selectedForNodeIDs: Set<UUID>
}
