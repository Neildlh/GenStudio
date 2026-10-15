import CryptoKit
import Foundation

/// Distinct generation contracts. A recipe that supports one task never implies another.
enum VideoTask: String, Codable, CaseIterable, Sendable {
    case textToVideo, imageToVideo, firstLastFrame, timedKeyframes, videoToVideo

    var title: String {
        switch self {
        case .textToVideo: "Text to video"
        case .imageToVideo: "Image to video"
        case .firstLastFrame: "Start/end frame video"
        case .timedKeyframes: "Timed keyframe (guided) video"
        case .videoToVideo: "Video to video"
        }
    }

    /// The node kind that authors this task; there is no shared generic video generator.
    var nodeKind: NodeKind {
        switch self {
        case .textToVideo: .textToVideo
        case .imageToVideo: .imageToVideo
        case .firstLastFrame: .startEndVideo
        case .timedKeyframes: .guidedShot
        case .videoToVideo: .videoToVideo
        }
    }

    static func task(for kind: NodeKind) -> VideoTask? { allCases.first { $0.nodeKind == kind } }
}

/// Input purpose, not just data type. Unsupported roles must fail preflight rather than be ignored.
enum VideoInputRole: String, Codable, CaseIterable, Sendable {
    case prompt, negativePrompt, startImage, endImage, timedAnchors, sourceVideo, referenceImage, mask
}

/// Content identity for immutable media; a URL or path is only a location.
struct MediaIdentity: Codable, Hashable, Sendable {
    let sha256: String
    let byteSize: Int64

    static func of(_ url: URL) throws -> MediaIdentity {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isDirectory == true { return try ofDirectory(url) }
        guard values?.isRegularFile != false else {
            throw StudioError.validation("Media \(url.lastPathComponent) is not a readable file or frame directory.")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw StudioError.validation("Media file \(url.lastPathComponent) is not readable.") }
        defer { try? handle.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data); count += Int64(data.count)
        }
        return .init(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), byteSize: count)
    }

    /// Hash an extracted reference-frame directory deterministically. A directory
    /// has no portable byte stream of its own, so include each relative filename
    /// and its bytes in sorted order. This catches changed, missing, or reordered
    /// frames before the video engine loads a large model.
    private static func ofDirectory(_ url: URL) throws -> MediaIdentity {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: url.path) else {
            throw StudioError.validation("Frame directory \(url.lastPathComponent) is not readable.")
        }
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw StudioError.validation("Frame directory \(url.lastPathComponent) could not be enumerated.")
        }
        let files = enumerator.compactMap { item -> URL? in
            guard let file = item as? URL,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return file
        }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw StudioError.validation("Frame directory \(url.lastPathComponent) contains no image frames.") }
        var hash = SHA256(); var count: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let relative = file.path.replacingOccurrences(of: url.path + "/", with: "")
            hash.update(data: Data(relative.utf8)); hash.update(data: Data([0]))
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: file) } catch { throw StudioError.validation("Frame \(relative) is not readable.") }
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data); count += Int64(data.count)
            }
            hash.update(data: Data([0]))
        }
        return .init(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), byteSize: count)
    }
}

struct IntegerBounds: Codable, Hashable, Sendable {
    let minimum: Int
    let maximum: Int
    var multiple: Int = 1
    func contains(_ value: Int) -> Bool { (minimum...maximum).contains(value) && value.isMultiple(of: multiple) }
    var summary: String { multiple > 1 ? "\(minimum)–\(maximum) in multiples of \(multiple)" : "\(minimum)–\(maximum)" }
}

/// Snaps the canvas within `width`/`height`'s bounds and quantisation that best matches
/// `ratio`: closest aspect ratio first, largest area second among equally close matches.
/// Shared by aspect-ratio presets and automatic source-image adoption so both use one
/// fitting rule.
///
/// This sweeps every multiple-of-`width.multiple` value in `width`'s range (and, symmetrically,
/// every multiple in `height`'s range), picking the best-matching companion dimension for each —
/// rather than projecting from only the four corners of the bounding box. Four fixed corners can
/// miss the true best fit for a quantized ratio: the ideal companion value for a corner can round
/// across a whole multiple step and land outside tolerance, even when a non-corner combination
/// fits well. Relative error (not a fixed absolute gap on the ratio value) also makes the match
/// consistent across very different ratios — an absolute 0.08 is a huge fraction of a portrait
/// ratio like 9:16 but a small one of a landscape ratio like 21:9.
///
/// Nil only when every combination in bounds is more than 8% off the target ratio.
func fittedDimensions(ratio: Double, width: IntegerBounds, height: IntegerBounds, preferredLongestEdge: Int? = nil, preferLargestCanvas: Bool = false, targetPixels: Int? = nil) -> (Int, Int)? {
    guard ratio.isFinite, ratio > 0, width.minimum <= width.maximum, height.minimum <= height.maximum else { return nil }
    let tolerance = 0.08
    var best: (w: Int, h: Int, error: Double, area: Int)?
    var candidates: [(w: Int, h: Int, error: Double, area: Int)] = []
    func consider(_ w: Int, _ h: Int) {
        guard width.contains(w), height.contains(h) else { return }
        let error = abs(Double(w) / Double(h) - ratio) / ratio
        let area = w * h
        guard error < tolerance else { return }
        if targetPixels != nil { candidates.append((w, h, error, area)); return }
        guard let current = best else { best = (w, h, error, area); return }
        if preferLargestCanvas {
            let longestEdge = max(w, h)
            let currentLongestEdge = max(current.w, current.h)
            if longestEdge > currentLongestEdge || (longestEdge == currentLongestEdge && (error < current.error - 1e-9 || (abs(error - current.error) <= 1e-9 && area > current.area))) {
                best = (w, h, error, area)
            }
        } else if let preferredLongestEdge {
            let distance = abs(max(w, h) - preferredLongestEdge)
            let currentDistance = abs(max(current.w, current.h) - preferredLongestEdge)
            if distance < currentDistance || (distance == currentDistance && (error < current.error - 1e-9 || (abs(error - current.error) <= 1e-9 && area > current.area))) {
                best = (w, h, error, area)
            }
        } else if error < current.error - 1e-9 || (abs(error - current.error) <= 1e-9 && area > current.area) {
            best = (w, h, error, area)
        }
    }
    /// The two multiple-aligned values in `bounds` bracketing `value`, clamped to bounds.
    func bracketing(_ value: Double, in bounds: IntegerBounds) -> [Int] {
        let steps = (value - Double(bounds.minimum)) / Double(bounds.multiple)
        let lower = bounds.minimum + Int(steps.rounded(.down)) * bounds.multiple
        return Array(Set([lower, lower + bounds.multiple]).map { min(bounds.maximum, max(bounds.minimum, $0)) })
    }
    var w = width.minimum
    while w <= width.maximum {
        for h in bracketing(Double(w) / ratio, in: height) { consider(w, h) }
        w += width.multiple
    }
    var h = height.minimum
    while h <= height.maximum {
        for w in bracketing(Double(h) * ratio, in: width) { consider(w, h) }
        h += height.multiple
    }
    if let targetPixels {
        // Nearly-exact ratios only (within 1% of the most exact available), then the canvas whose
        // pixel count is closest to the model's sweet spot.
        guard let minError = candidates.map(\.error).min() else { return nil }
        let pick = candidates.filter { $0.error <= minError + 0.01 }.min {
            abs($0.area - targetPixels) < abs($1.area - targetPixels) || (abs($0.area - targetPixels) == abs($1.area - targetPixels) && $0.error < $1.error)
        }
        return pick.map { ($0.w, $0.h) }
    }
    guard let best else { return nil }
    return (best.w, best.h)
}

/// Keeps width and height in the chosen ratio while one of them is changed. The ratio is the matched
/// preset's exact value (so repeated drags never accumulate rounding drift), or the canvas's own
/// ratio when it matches no preset. Both axes stay inside their bounds and multiples.
enum RatioLock {
    static func ratio(width: Int, height: Int) -> Double {
        if case .preset(let preset) = AspectRatioSelection.matching(width: width, height: height) { return preset.ratio }
        return Double(max(width, 1)) / Double(max(height, 1))
    }
    private static func snap(_ value: Double, _ bounds: IntegerBounds) -> Int {
        let step = max(bounds.multiple, 1)
        let snapped = Int((value / Double(step)).rounded()) * step
        return min(bounds.maximum, max(bounds.minimum, snapped))
    }
    static func resolve(changedWidth: Bool, raw: Int, currentWidth: Int, currentHeight: Int, widthBounds: IntegerBounds, heightBounds: IntegerBounds) -> (width: Int, height: Int) {
        let ratio = ratio(width: currentWidth, height: currentHeight)
        if changedWidth {
            var w = snap(Double(raw), widthBounds)
            let h = snap(Double(w) / ratio, heightBounds)
            if abs(Double(w) / Double(h) - ratio) / ratio > 0.03 { w = snap(Double(h) * ratio, widthBounds) }
            return (w, h)
        }
        var h = snap(Double(raw), heightBounds)
        let w = snap(Double(h) * ratio, widthBounds)
        if abs(Double(w) / Double(h) - ratio) / ratio > 0.03 { h = snap(Double(w) / ratio, heightBounds) }
        return (w, h)
    }
}

/// Common production canvases. Values are fitted to the selected recipe's
/// bounds and quantisation rules before being written to a node.
enum AspectRatioPreset: String, CaseIterable, Identifiable, Sendable {
    case square = "1:1", portrait = "4:5", portrait23 = "2:3", vertical = "9:16"
    case landscape32 = "3:2", landscape43 = "4:3", widescreen = "16:9", cinema = "21:9"
    var id: String { rawValue }
    var title: String { rawValue }
    var ratio: Double {
        switch self { case .square: 1; case .portrait: 4.0/5.0; case .portrait23: 2.0/3.0; case .vertical: 9.0/16.0; case .landscape32: 3.0/2.0; case .landscape43: 4.0/3.0; case .widescreen: 16.0/9.0; case .cinema: 21.0/9.0 }
    }
    func dimensions(width: IntegerBounds, height: IntegerBounds, preferredLongestEdge: Int? = nil, preferLargestCanvas: Bool = false, targetPixels: Int? = nil) -> (Int, Int)? {
        fittedDimensions(ratio: ratio, width: width, height: height, preferredLongestEdge: preferredLongestEdge, preferLargestCanvas: preferLargestCanvas, targetPixels: targetPixels)
    }
}

/// Keeps a video node's start/end image canvas matched to its connected source image, so a
/// portrait photo is never silently center-cropped to a node left at a landscape default.
/// Only ever narrows to a size the task's capability already allows; never overrides a size
/// the user set by hand except in direct response to a connection or recipe change.
enum VideoDimensionSync {
    /// Pixel size already known without running the graph: a chosen file on an Image Input
    /// node (probed from disk), or another node's own configured width/height. Nil for a
    /// source whose output size is only known after it executes.
    static func knownDimensions(_ node: StudioNode) -> (width: Int, height: Int)? {
        if node.kind == .imageInput {
            guard let path = node.imagePath else { return nil }
            return ImageDimensionProbe.dimensions(URL(fileURLWithPath: path))
        }
        guard node.width > 0, node.height > 0 else { return nil }
        return (node.width, node.height)
    }

    /// Re-fits `nodeID` to its connected start/end image(s) using its current recipe's bounds.
    /// Call after connecting an image, changing which file an Image Input node points to, or
    /// switching the node's recipe (whose bounds may no longer fit the previous size).
    static func resyncNode(_ nodeID: UUID, in project: inout WorkflowProject) {
        guard let index = project.nodes.firstIndex(where: { $0.id == nodeID }),
              let task = project.nodes[index].kind.videoTask,
              let capability = VideoCapabilityRegistry.capability(recipeID: project.nodes[index].model, task: task) else { return }
        // endImage first, startImage second: when both are connected with different aspect
        // ratios, the start frame — the animation's primary anchor — wins.
        for role in ["endImage", "startImage"] {
            guard let edge = project.edges.first(where: { $0.targetID == nodeID && $0.targetPortID == role }),
                  let source = project.nodes.first(where: { $0.id == edge.sourceID }),
                  let dims = knownDimensions(source),
                  let fitted = fittedDimensions(
                    ratio: Double(dims.width) / Double(dims.height),
                    width: capability.width,
                    height: capability.height,
                    preferredLongestEdge: max(project.nodes[index].video.width, project.nodes[index].video.height)
                  ) else { continue }
            project.nodes[index].video.width = fitted.0
            project.nodes[index].video.height = fitted.1
        }
    }

    /// Re-fits every video node whose start/end image is fed by `sourceNodeID`. Call after a
    /// source node's own image changes (a new file chosen, or its own size setting edited).
    static func resyncTargets(of sourceNodeID: UUID, in project: inout WorkflowProject) {
        guard let source = project.nodes.first(where: { $0.id == sourceNodeID }) else { return }
        let targets = Set(project.edges.filter { $0.sourceID == sourceNodeID && ($0.targetPortID == "startImage" || $0.targetPortID == "endImage") }.map(\.targetID))
        guard knownDimensions(source) != nil, !targets.isEmpty else { return }
        for targetID in targets { resyncNode(targetID, in: &project) }
    }
}

/// Wan2.1's causal VAE compresses time by four, so valid total lengths are 4n+1.
struct FrameCountRule: Codable, Hashable, Sendable {
    let minimum: Int
    let maximum: Int
    let stride: Int
    let offset: Int
    func contains(_ frames: Int) -> Bool { (minimum...maximum).contains(frames) && (frames - offset).isMultiple(of: stride) }
    var summary: String { "\(minimum)–\(maximum) frames of the form \(stride)n+\(offset)" }
    var allowed: [Int] { Array(Swift.stride(from: minimum, through: maximum, by: 1)).filter(contains) }
}

struct VideoDurationControlSpec: Equatable, Sendable {
    let minimumSeconds: Double
    let maximumSeconds: Double
    let stepSeconds: Double
    let requestedFractionDigits: Int

    /// The slider moves in whole and half seconds (1, 1.5, 2, 2.5 …) rather than single frames, since
    /// nobody plans a 1.125 s clip. The resolver still snaps the result to the nearest frame count the
    /// model supports. Nil when the model's range is too narrow to hold two half-second stops.
    var friendlyStops: (minimum: Double, maximum: Double, step: Double)? {
        let low = (minimumSeconds * 2).rounded(.up) / 2, high = (maximumSeconds * 2).rounded(.down) / 2
        return high > low ? (low, high, 0.5) : nil
    }
}

struct ResolvedVideoDuration: Equatable, Sendable {
    let requestedSeconds: Double
    let frameCount: Int
    let fps: Int
    let control: VideoDurationControlSpec

    /// GenStudio's established sample-duration convention. The final sample is presented one
    /// frame interval before this endpoint.
    var generatedSeconds: Double { Double(frameCount) / Double(fps) }
    var lastFrameTimestamp: Double { Double(frameCount - 1) / Double(fps) }
    var wasSnapped: Bool { abs(generatedSeconds - requestedSeconds) > 0.000_001 }
}

/// The single conversion path used by authoring, preflight and runtime request construction.
/// Requested seconds remain stable across FPS/recipe changes when they fit the new duration range;
/// the cached frame count is always replaced by the nearest supported value.
enum VideoDurationResolver {
    static func controlSpec(rule: FrameCountRule, fps: Int) throws -> VideoDurationControlSpec {
        guard fps > 0 else { throw StudioError.validation("Frame rate must be greater than zero before resolving duration.") }
        let allowed = rule.allowed
        guard let first = allowed.first, let last = allowed.last else {
            throw StudioError.validation("The selected recipe does not define any valid frame counts.")
        }
        // One displayed-frame interval is the finest duration that can affect duration × FPS.
        // The model's temporal stride is applied separately when that request snaps to `allowed`.
        let step = 1.0 / Double(fps)
        return .init(
            minimumSeconds: Double(first) / Double(fps),
            maximumSeconds: Double(last) / Double(fps),
            stepSeconds: step,
            requestedFractionDigits: step >= 1 ? 0 : 1
        )
    }

    static func resolve(requestedSeconds: Double, fps: Int, rule: FrameCountRule) throws -> ResolvedVideoDuration {
        guard requestedSeconds.isFinite, requestedSeconds > 0 else {
            throw StudioError.validation("Duration must be a finite number of seconds greater than zero.")
        }
        let control = try controlSpec(rule: rule, fps: fps)
        let clamped = min(control.maximumSeconds, max(control.minimumSeconds, requestedSeconds))
        let targetFrames = clamped * Double(fps)
        let allowed = rule.allowed
        let frameCount = allowed.min { left, right in
            let leftDistance = abs(Double(left) - targetFrames)
            let rightDistance = abs(Double(right) - targetFrames)
            if abs(leftDistance - rightDistance) < 0.000_001 { return left < right }
            return leftDistance < rightDistance
        }!
        return .init(requestedSeconds: clamped, frameCount: frameCount, fps: fps, control: control)
    }

    @discardableResult
    static func apply(to settings: inout VideoGenerationSettings, rule: FrameCountRule) throws -> ResolvedVideoDuration {
        let resolved = try resolve(requestedSeconds: settings.requestedDurationSeconds, fps: settings.fps, rule: rule)
        settings.requestedDurationSeconds = resolved.requestedSeconds
        settings.frameCount = resolved.frameCount
        return resolved
    }
}

/// "How long should the finished clip be?" answered in seconds. The generated frame rate is chosen
/// automatically: as close as the model allows to its own recommended rate, so the requested length
/// fits inside the model's frame limits. Nobody should have to do that arithmetic by hand.
enum VideoLengthPlanner {
    /// Shortest and longest clip the model can make at any frame rate it supports, on half-second stops.
    static func secondsRange(_ capability: VideoCapability) -> ClosedRange<Double>? {
        guard let first = capability.frames.allowed.first, let last = capability.frames.allowed.last else { return nil }
        let low = (Double(first) / Double(capability.fps.maximum) * 2).rounded(.up) / 2
        let high = (Double(last) / Double(capability.fps.minimum) * 2).rounded(.down) / 2
        return high > low ? low...high : nil
    }

    /// The generated frame rate closest to the recipe's recommendation that can deliver `seconds`.
    static func fps(forSeconds seconds: Double, capability: VideoCapability) -> Int {
        guard let first = capability.frames.allowed.first, let last = capability.frames.allowed.last else { return capability.recommended.fps }
        let preferred = capability.recommended.fps
        let fits = (capability.fps.minimum...capability.fps.maximum).filter { fps in
            let frames = Int((seconds * Double(fps)).rounded())
            return frames >= first && frames <= last
        }
        return fits.min { abs($0 - preferred) < abs($1 - preferred) || (abs($0 - preferred) == abs($1 - preferred) && $0 < $1) } ?? preferred
    }
}

/// Detail levels replace the raw step count. Steps are refinement passes: more of them cost little
/// (20 → 4 steps saved only 30% of wall time on Wan; docs/evidence/video-benchmark-m1max-2026-09-18.md),
/// so the levels spread around the recipe's own recommended count.
enum VideoQualityLevel: Int, CaseIterable, Sendable {
    case low, medium, high, extra
    var title: String { ["Low", "Medium", "High", "Extra"][rawValue] }
    private var multiplier: Double { [0.4, 1.0, 1.5, 2.0][rawValue] }

    func steps(_ capability: VideoCapability) -> Int {
        let raw = Int((Double(capability.recommended.steps) * multiplier).rounded())
        return min(capability.steps.maximum, max(capability.steps.minimum, raw))
    }
    /// Levels that give a distinct step count for this model, in order. One entry or fewer means the
    /// model fixes its own quality (distilled models with a single step count).
    static func available(_ capability: VideoCapability) -> [VideoQualityLevel] {
        var seen = Set<Int>()
        return allCases.filter { seen.insert($0.steps(capability)).inserted }
    }
    static func nearest(steps: Int, capability: VideoCapability) -> VideoQualityLevel {
        available(capability).min { abs($0.steps(capability) - steps) < abs($1.steps(capability) - steps) } ?? .medium
    }
}

enum VideoDurationPresentation {
    static func requestedLabel(_ resolved: ResolvedVideoDuration) -> String {
        "Duration: \(format(resolved.requestedSeconds, digits: resolved.control.requestedFractionDigits)) seconds"
    }

    static func resultLabel(_ resolved: ResolvedVideoDuration) -> String {
        "\(format(resolved.requestedSeconds, digits: resolved.control.requestedFractionDigits)) s requested · \(resolved.frameCount) expensive generated frames at \(resolved.fps) fps · \(format(resolved.generatedSeconds, digits: 2)) s"
    }

    static func snappingExplanation(_ resolved: ResolvedVideoDuration, rule: FrameCountRule) -> String? {
        guard resolved.wasSnapped else { return nil }
        let constraint = rule.allowed.count == 1
            ? "a fixed \(resolved.frameCount)-frame clip"
            : "clips in \(rule.stride)-frame intervals"
        return "This model generates \(constraint). The closest supported duration is \(format(resolved.generatedSeconds, digits: 2)) seconds."
    }

    private static func format(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }
}

enum CapabilityReadiness: Codable, Hashable, Sendable {
    /// Adapter exists but no real output has been validated for this exact tuple.
    case awaitingProof
    /// A real local render through this adapter was decoded and validated. Quality may still be experimental.
    case verified(evidence: String)
    /// No adapter for this task exists in GenStudio.
    case unavailable(reason: String)

    /// A decoded local render has validated this exact recipe/engine/task tuple.
    /// This drives labelling, recommendation ranking and feed eligibility. It is
    /// deliberately **not** the execution gate: see `executable`.
    var proven: Bool { if case .verified = self { return true }; return false }

    /// GenStudio has an adapter contract for this task and the route has not been
    /// withdrawn, so the user may run it.
    ///
    /// Proof is a label, not a permission. A model that matches a supported adapter
    /// runs on first use and records its own proof from the decoded result; requiring
    /// proof before the first run made proof unobtainable without a developer change,
    /// which is the defect this replaces. `.unavailable` remains a hard block, because
    /// those routes are known broken (AnimateDiff's identical frames, the withdrawn
    /// LTX-2.5 stable-diffusion.cpp path) rather than merely unmeasured.
    var executable: Bool { if case .unavailable = self { return false }; return true }

    /// Historical spelling of `executable`, kept because installability and
    /// reviewability have always used this meaning.
    var adapterAvailable: Bool { executable }
}

/// Typed command dispatch key. Each profile has exactly one argument builder and one component-role set.
enum VideoCommandProfile: String, Codable, Sendable {
    case wan21TextToVideo, wan21FirstLastFrame, animateDiffSD15, lingBotVideo, wan22TI2V, ltx25, minimaxH3, minimaxH3Ref2VA, mlxFastMetal5, mlxLTX23

    var componentRoles: [String] {
        switch self {
        case .wan21TextToVideo, .lingBotVideo, .wan22TI2V: ["diffusion", "textEncoder", "vae"]
        case .ltx25: ["diffusion", "textEncoder", "vae", "audioVae"]
        case .wan21FirstLastFrame: ["diffusion", "textEncoder", "vae", "clipVision"]
        case .animateDiffSD15: ["checkpoint", "motionModule"]
        case .minimaxH3: ["diffusion", "textEncoder", "vae"]
        case .minimaxH3Ref2VA: ["diffusion", "textEncoder", "vae"]
        case .mlxFastMetal5: ["mlxConfig", "mlxDiT", "textEncoder", "tokenizer", "vae"]
        case .mlxLTX23: ["ltxConfig", "ltxTransformer", "textConnector", "textEncoder", "tokenizer", "vaeEncoder", "vaeDecoder", "upscaler"]
        }
    }
}

/// Keyed to the exact recipe, engine build and task. Controls are advertised only from this descriptor.
struct VideoCapability: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(recipeID)@\(engineBuild):\(task.rawValue)" }
    let recipeID: String
    let engineID: String
    let engineBuild: String
    let task: VideoTask
    let requiredRoles: Set<VideoInputRole>
    let optionalRoles: Set<VideoInputRole>
    let width: IntegerBounds
    let height: IntegerBounds
    let frames: FrameCountRule
    let fps: IntegerBounds
    let steps: IntegerBounds
    let readiness: CapabilityReadiness
    let qualityNote: String
    /// Known measurement only for the exact settings named; never extrapolated.
    let measuredBaseline: String?
    var command: VideoCommandProfile = .wan21TextToVideo
    /// Nil means the pinned guide passes no sampler; the runtime default is used and recorded as "default".
    var sampler: String? = "euler"
    var scheduler: String? = nil
    var usesFlowShift = true
    /// Present only for adapters that re-noise a start image.
    var strength: DoubleBounds? = nil
    /// Documented starting settings for this recipe and task; not a quality or speed claim.
    var recommended: VideoGenerationSettings = .measuredProbe
    /// The route can render an interpolated fast draft (`VideoGenerationSettings.fastDraft`).
    var supportsFastDraft = false
    /// Takes timed on the reference M1 Max; drives the per-take time estimate. Empty means unmeasured.
    var speedAnchors: [VideoSpeedAnchor] = []
    /// The model generates a sound track with the picture (`VideoGenerationSettings.sound`).
    var producesAudio = false
    /// The pixel count a ratio button starts from: the recipe's own recommended canvas.
    var optimalPixels: Int { recommended.width * recommended.height }
    var supportedRoles: Set<VideoInputRole> { requiredRoles.union(optionalRoles) }
    func with(readiness: CapabilityReadiness) -> VideoCapability {
        var copy = VideoCapability(recipeID: recipeID, engineID: engineID, engineBuild: engineBuild, task: task, requiredRoles: requiredRoles, optionalRoles: optionalRoles, width: width, height: height, frames: frames, fps: fps, steps: steps, readiness: readiness, qualityNote: qualityNote, measuredBaseline: measuredBaseline)
        copy.command = command; copy.sampler = sampler; copy.scheduler = scheduler; copy.usesFlowShift = usesFlowShift; copy.strength = strength; copy.recommended = recommended
        copy.supportsFastDraft = supportsFastDraft
        copy.speedAnchors = speedAnchors
        copy.producesAudio = producesAudio
        return copy
    }

    /// Recipe switches adopt the new recipe's tuned defaults (frame rate, steps, guidance, size) while
    /// keeping what the person chose on purpose: the clip length, its shape (a portrait or square clip
    /// stays so, sized to this recipe's preferred pixel count), the seed, the fast-draft and the sound choice.
    /// If the old duration falls outside the new temporal range, only that duration is clamped.
    func recommendedSettings(preservingDurationFrom existing: VideoGenerationSettings) -> VideoGenerationSettings {
        var next = recommended
        if existing.width > 0, existing.height > 0 {
            let shape = Double(existing.width) / Double(existing.height)
            let own = Double(recommended.width) / Double(recommended.height)
            // A shape within ~10% of the recipe's own canvas is the same intent: use the tuned canvas exactly.
            if abs(log(shape / own)) > 0.1,
               let fitted = fittedDimensions(ratio: shape, width: width, height: height, targetPixels: optimalPixels) {
                next.width = fitted.0; next.height = fitted.1
            }
        }
        next.seed = existing.seed
        next.fastDraft = supportsFastDraft ? existing.fastDraft : nil
        next.sound = producesAudio ? existing.sound : nil
        next.requestedDurationSeconds = existing.requestedDurationSeconds
        if (try? VideoDurationResolver.apply(to: &next, rule: frames)) == nil {
            next = recommended
            _ = try? VideoDurationResolver.apply(to: &next, rule: frames)
        }
        // What to avoid is the user's intent, not a model setting: a draft-to-final switch must not lose it.
        next.negativePrompt = existing.negativePrompt
        return next
    }
}

enum VideoCapabilityRegistry {
    static let sdCppBuild = "stable-diffusion.cpp@7f410a3793c5bba8eb198e962ce7a3d6095f9d89"
    static let wanT2VRecipeID = "wan21-13b-q4"
    static let ltx25RecipeID = "ltx25-dev-22b-q4km"

    /// FastMetal's packaged MLX script is T2V-only. The app-owned runtime and
    /// exact command adapter now ship, so the package may be admitted for a
    /// controlled first proof. It remains absent from normal search and the
    /// recommended starter queue, while Start Here exposes it explicitly as
    /// Download & Test until a decoded M1 Max render promotes this readiness.
    static let fastMetal5TextToVideo: VideoCapability = {
        var value = VideoCapability(
            recipeID: MLXVideoModelCatalog.fastMetal5BRecipeID,
            engineID: "mlx-fastvideo", engineBuild: MLXVideoModelCatalog.fastVideoBuild,
            task: .textToVideo, requiredRoles: [.prompt], optionalRoles: [.negativePrompt],
            width: .init(minimum: 480, maximum: 1280, multiple: 16),
            height: .init(minimum: 256, maximum: 1280, multiple: 16),
            frames: .init(minimum: 21, maximum: 121, stride: 4, offset: 1),
            fps: .init(minimum: 24, maximum: 24), steps: .init(minimum: 3, maximum: 3),
            readiness: .awaitingProof,
            qualityNote: "FastMetal 5B QAD (Wan 2.2 TI2V 5B, quantization-aware distilled) on the upstream three-step Apple MLX path. Text-to-video only. The fastest local draft engine: coherent motion and lighting at 832×480 and 1280×704. Fast draft renders every second frame and interpolates the rest (about 2× faster, slightly softer).",
            measuredBaseline: "Measured on this M1 Max (64 GB) through the app's launcher, 5.04 s clips (121 frames, 24 fps), 12 Oct 2026: 832×480 in 88 s (fast draft 46 s); 1280×704 in 319 s (fast draft 134 s), 11.4 GiB MLX peak. A new prompt adds about 37 s of CPU text encoding once; later takes of the same prompt reuse it."
        )
        value.command = .mlxFastMetal5
        value.sampler = nil; value.scheduler = nil; value.usesFlowShift = false
        // Upstream's default canvas is landscape (832 wide); 480 rather than 448 keeps a 16:9-like draft.
        value.recommended = settings(width: 832, height: 480, frames: 121, fps: 24, steps: 3, cfg: 1.0, flowShift: 5.0)
        value.supportsFastDraft = true
        // 12 Oct 2026, docs/evidence/fast-local-video-m1max-2026-10-12.md (process totals, prompt cached).
        value.speedAnchors = [
            .init(width: 832, height: 480, frames: 121, fastDraft: false, seconds: 88),
            .init(width: 1280, height: 704, frames: 121, fastDraft: false, seconds: 281),
            .init(width: 832, height: 480, frames: 121, fastDraft: true, seconds: 46),
            .init(width: 1280, height: 704, frames: 121, fastDraft: true, seconds: 134)
        ]
        return value
    }()

    private static func mlxLTX23(_ task: VideoTask) -> VideoCapability {
        let required: Set<VideoInputRole> = switch task {
        case .imageToVideo: [.startImage, .prompt]
        case .firstLastFrame: [.startImage, .endImage, .prompt]
        default: [.prompt]
        }
        var value = VideoCapability(
            recipeID: MLXVideoModelCatalog.ltx23Q4RecipeID,
            engineID: "mlx-ltx", engineBuild: MLXVideoModelCatalog.ltxBuild,
            task: task, requiredRoles: required, optionalRoles: [],
            width: .init(minimum: 256, maximum: 1_024, multiple: 64),
            height: .init(minimum: 256, maximum: 1_024, multiple: 64),
            frames: .init(minimum: 9, maximum: 257, stride: 8, offset: 1),
            fps: .init(minimum: 24, maximum: 24), steps: .init(minimum: 1, maximum: 8),
            readiness: .awaitingProof,
            qualityNote: task == .firstLastFrame
                ? "Native Apple-Silicon MLX distilled two-stage LTX-2.3 with the start image on the first frame and the end image on the last (ltx-2-mlx 0.16 keyframe conditioning), with generated sound. About eight times faster than MiniMax-H3 here; H3 remains the higher-quality start/end route."
                : "Native Apple-Silicon MLX distilled two-stage LTX-2.3 with float16 compute. Generates sound with the picture: describe it in the prompt (ambience, music, a short spoken line).",
            measuredBaseline: task == .firstLastFrame
                ? "Measured on this M1 Max, 12 Oct 2026: a 5.04 s 768×448 start-to-end clip in 186 s, peak 22 GB; first frame 29.8 dB and last frame 27.7 dB PSNR against the supplied images."
                : "Measured on this M1 Max, 12 Oct 2026: a 5.04 s 768×448 clip in 173 s with float16 compute (235 s before), peak 22 GB."
        )
        value.command = .mlxLTX23
        value.producesAudio = true
        value.sampler = nil; value.scheduler = nil; value.usesFlowShift = false
        value.recommended = settings(width: 768, height: 448, frames: 121, fps: 24, steps: 8, cfg: 1.0, flowShift: 1.0, negative: "")
        // 12 Oct 2026, ltx-2-mlx 0.16.3 with float16 compute: 768×448 T2V 173 s, start/end 186 s; a 576×1024 vertical
        // image-to-video ad shot 394 s (T2V and I2V share the pipeline).
        value.speedAnchors = task == .firstLastFrame
            ? [.init(width: 768, height: 448, frames: 121, fastDraft: false, seconds: 186)]
            : [.init(width: 768, height: 448, frames: 121, fastDraft: false, seconds: 173), .init(width: 576, height: 1024, frames: 121, fastDraft: false, seconds: 394)]
        return value
    }

    static let ltx23TextToVideo = mlxLTX23(.textToVideo)
    static let ltx23ImageToVideo = mlxLTX23(.imageToVideo)
    static let ltx23FirstLastFrame = mlxLTX23(.firstLastFrame)

    /// The Wan2.1 T2V 1.3B checkpoint is text-to-video only. It is never offered for I2V, FLF2V or keyframes.
    static let wanTextToVideo = VideoCapability(
        recipeID: wanT2VRecipeID, engineID: "stable-diffusion.cpp", engineBuild: sdCppBuild, task: .textToVideo,
        requiredRoles: [.prompt], optionalRoles: [.negativePrompt],
        width: .init(minimum: 160, maximum: 832, multiple: 16), height: .init(minimum: 96, maximum: 480, multiple: 16),
        frames: .init(minimum: 5, maximum: 33, stride: 4, offset: 1), fps: .init(minimum: 4, maximum: 24), steps: .init(minimum: 4, maximum: 40),
        readiness: shippedWanReadiness,
        qualityNote: "Experimental: Wan2.1 T2V 1.3B Q4 at low resolution produces short, soft clips with morphing and flicker. Not production quality.",
        measuredBaseline: "Re-measured directly against the pinned engine on Apple M1 Max / 64 GB (18 Sep 2026): 320×192, 9 frames, 8 fps, 20 steps takes about 89 s — sampling 31.6 s and VAE decode 52.8 s. VAE decode, not diffusion, dominates: cutting 20 steps to 4 saves only 30% of wall time, while resolution is near-linear in pixels (480×288 took about 192 s). An earlier figure of 194–207 s included first-run component checksum validation (15.3 s, cached per session) on an older build. Generate at low resolution and enlarge with Video Upscale rather than raising generation resolution; see docs/evidence/video-benchmark-m1max-2026-09-18.md."
    )

    /// Promoted only after a real local render through NativeWanVideoEngine was decoded and validated.
    static let shippedWanReadiness: CapabilityReadiness = .verified(evidence: "docs/research/production-node-workflows/evidence/wan-t2v-integration.json")

    private static func settings(width: Int, height: Int, frames: Int, fps: Int, steps: Int, cfg: Double, flowShift: Double = 3.0, strength: Double? = nil, negative: String = "static, frozen, blurry, low quality, distorted") -> VideoGenerationSettings {
        var value = VideoGenerationSettings()
        value.width = width; value.height = height; value.frameCount = frames; value.fps = fps; value.requestedDurationSeconds = Double(frames) / Double(fps); value.steps = steps; value.cfgScale = cfg; value.flowShift = flowShift; value.strength = strength; value.negativePrompt = negative
        return value
    }
    private static func adapter(_ recipeID: String, _ task: VideoTask, _ command: VideoCommandProfile, width: IntegerBounds, height: IntegerBounds, frames: FrameCountRule, fps: IntegerBounds, steps: IntegerBounds,
                                sampler: String?, scheduler: String? = nil, usesFlowShift: Bool, strength: DoubleBounds? = nil, recommended: VideoGenerationSettings, note: String) -> VideoCapability {
        let required: Set<VideoInputRole> = switch task {
        case .imageToVideo: [.startImage, .prompt]
        case .firstLastFrame: [.startImage, .endImage, .prompt]
        case .videoToVideo: [.sourceVideo, .prompt]
        default: [.prompt]
        }
        var capability = VideoCapability(recipeID: recipeID, engineID: "stable-diffusion.cpp", engineBuild: sdCppBuild, task: task, requiredRoles: required, optionalRoles: [.negativePrompt],
                                         width: width, height: height, frames: frames, fps: fps, steps: steps, readiness: .awaitingProof, qualityNote: note, measuredBaseline: nil)
        capability.command = command; capability.sampler = sampler; capability.scheduler = scheduler; capability.usesFlowShift = usesFlowShift; capability.strength = strength; capability.recommended = recommended
        return capability
    }

    // Pinned guide: docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/animatediff.md
    static let animateDiffTextToVideo = adapter(MediaModelCatalog.animateDiffRecipeID, .textToVideo, .animateDiffSD15,
        width: .init(minimum: 256, maximum: 512, multiple: 64), height: .init(minimum: 256, maximum: 512, multiple: 64), frames: .init(minimum: 8, maximum: 32, stride: 8, offset: 0),
        fps: .init(minimum: 4, maximum: 24), steps: .init(minimum: 10, maximum: 40), sampler: "euler", scheduler: "discrete", usesFlowShift: false,
        recommended: settings(width: 384, height: 384, frames: 16, fps: 8, steps: 20, cfg: 8.0),
        note: "Diagnostic descriptor only. A real Apple-Silicon run completed, but all eight decoded output frames were byte-identical. This path is withheld from the node recipe picker because a static repeated frame is not a valid video result.")
    static let animateDiffImageToVideo = adapter(MediaModelCatalog.animateDiffRecipeID, .imageToVideo, .animateDiffSD15,
        width: .init(minimum: 256, maximum: 512, multiple: 64), height: .init(minimum: 256, maximum: 512, multiple: 64), frames: .init(minimum: 8, maximum: 32, stride: 8, offset: 0),
        fps: .init(minimum: 4, maximum: 24), steps: .init(minimum: 10, maximum: 40), sampler: "euler", scheduler: "karras", usesFlowShift: false, strength: .init(minimum: 0.1, maximum: 0.9),
        recommended: settings(width: 512, height: 512, frames: 8, fps: 8, steps: 25, cfg: 7.0, strength: 0.75),
        note: "Diagnostic descriptor only. A real Apple-Silicon run completed, but all eight decoded output frames were byte-identical. This path is withheld from the node recipe picker because a static repeated frame is not a valid video result.")

    // Pinned guide: docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/lingbot_video.md
    static let lingBotTextToVideo = adapter(MediaModelCatalog.lingBotRecipeID, .textToVideo, .lingBotVideo,
        width: .init(minimum: 256, maximum: 832, multiple: 16), height: .init(minimum: 256, maximum: 832, multiple: 16), frames: .init(minimum: 33, maximum: 81, stride: 16, offset: 1),
        fps: .init(minimum: 8, maximum: 24), steps: .init(minimum: 10, maximum: 40), sampler: nil, usesFlowShift: false,
        recommended: settings(width: 256, height: 448, frames: 33, fps: 8, steps: 10, cfg: 3.0),
        note: "LingBot-Video Dense 1.3B. New nodes start with an economical portrait motion test: 256×448, 33 generated frames, 8 generation fps and 10 steps. Use 448×800 only after motion is approved, then upscale and interpolate for delivery. Frame counts are 33, 49, 65 or 81.")
    static let lingBotImageToVideo = adapter(MediaModelCatalog.lingBotRecipeID, .imageToVideo, .lingBotVideo,
        width: .init(minimum: 256, maximum: 832, multiple: 16), height: .init(minimum: 256, maximum: 832, multiple: 16), frames: .init(minimum: 33, maximum: 81, stride: 16, offset: 1),
        fps: .init(minimum: 8, maximum: 24), steps: .init(minimum: 10, maximum: 40), sampler: nil, usesFlowShift: false,
        recommended: settings(width: 256, height: 448, frames: 33, fps: 8, steps: 10, cfg: 3.0),
        note: "The start image becomes the first frame. New nodes start at 256×448, 33 generated frames, 8 generation fps and 10 steps. Connecting a source follows its aspect ratio; use a portrait source for Reels. Approve motion before raising resolution, and use Frame Interpolation for 30 fps delivery.")

    // Pinned guide: .vendor/sd/source-evidence/docs/wan.md (Wan2.2 TI2V 5B T2V and I2V examples use -W 480 -H 832)
    static let wan22TextToVideo = adapter(MediaModelCatalog.wan22TI2VRecipeID, .textToVideo, .wan22TI2V,
        width: .init(minimum: 320, maximum: 1280, multiple: 32), height: .init(minimum: 320, maximum: 1280, multiple: 32), frames: .init(minimum: 17, maximum: 81, stride: 4, offset: 1),
        fps: .init(minimum: 8, maximum: 24), steps: .init(minimum: 10, maximum: 50), sampler: "euler", usesFlowShift: true,
        recommended: settings(width: 480, height: 832, frames: 33, fps: 24, steps: 20, cfg: 6.0),
        note: "Wan 2.2 TI2V 5B Q4_K_M with the Wan 2.2 VAE. Not yet rendered through GenStudio.")
    static let wan22ImageToVideo = adapter(MediaModelCatalog.wan22TI2VRecipeID, .imageToVideo, .wan22TI2V,
        width: .init(minimum: 320, maximum: 1280, multiple: 32), height: .init(minimum: 320, maximum: 1280, multiple: 32), frames: .init(minimum: 17, maximum: 81, stride: 4, offset: 1),
        fps: .init(minimum: 8, maximum: 24), steps: .init(minimum: 10, maximum: 50), sampler: "euler", usesFlowShift: true,
        recommended: settings(width: 480, height: 832, frames: 17, fps: 8, steps: 10, cfg: 6.0),
        note: "The same TI2V checkpoint conditioned on a start image. The conservative preset uses the documented 480×832 canvas with minimum frame count and steps. Time, peak memory and quality are unmeasured on this Mac.")

    // Pinned guide: docs/research/model-expansion/evidence/sdcpp-7f410a3-docs/ltx2.md.
    // The pinned sd.cpp route moves the Gemma encoder and LTX model through CPU
    // offload on this hardware. It has no usable Draft output on the reference
    // M1 Max, so preserve the descriptor only to diagnose old projects; do not
    // let a costly fallback appear as a production-capable video choice.
    static let ltx25TextToVideo: VideoCapability = adapter(ltx25RecipeID, .textToVideo, .ltx25,
        width: .init(minimum: 256, maximum: 1280, multiple: 8), height: .init(minimum: 256, maximum: 1280, multiple: 8), frames: .init(minimum: 9, maximum: 121, stride: 4, offset: 1),
        fps: .init(minimum: 8, maximum: 24), steps: .init(minimum: 1, maximum: 50), sampler: "euler", usesFlowShift: false,
        recommended: settings(width: 640, height: 360, frames: 17, fps: 8, steps: 20, cfg: 3.0),
        note: "Unavailable on this Mac with the bundled runtime: the LTX-2.5 adapter offloads its encoder and model to CPU and did not produce a first frame in a 6 minute 28 second minimal diagnostic run.")
        .with(readiness: .unavailable(reason: "LTX-2.5 is disabled for this bundled runtime: its CPU-offloaded path did not produce a first frame in a 6 minute 28 second minimal M1 Max diagnostic. It is not a usable local video backend. Choose the separate LTX-2.3 MLX Q4 recipe for native Apple-Silicon generation."))
    static let ltx25ImageToVideo: VideoCapability = adapter(ltx25RecipeID, .imageToVideo, .ltx25,
        width: .init(minimum: 256, maximum: 1280, multiple: 8), height: .init(minimum: 256, maximum: 1280, multiple: 8), frames: .init(minimum: 9, maximum: 121, stride: 4, offset: 1),
        fps: .init(minimum: 8, maximum: 24), steps: .init(minimum: 1, maximum: 50), sampler: "euler", usesFlowShift: false,
        recommended: settings(width: 640, height: 360, frames: 17, fps: 8, steps: 20, cfg: 3.0),
        note: "Unavailable on this Mac with the bundled runtime: the LTX-2.5 adapter offloads its encoder and model to CPU and did not produce a first frame in a 6 minute 28 second minimal diagnostic run.")
        .with(readiness: .unavailable(reason: "LTX-2.5 is disabled for this bundled runtime: its CPU-offloaded path did not produce a first frame in a 6 minute 28 second minimal M1 Max diagnostic. It is not a usable local video backend. Choose the separate LTX-2.3 MLX Q4 recipe for native Apple-Silicon generation."))

    static let wan21FirstLastFrame = adapter(MediaModelCatalog.wan21FLFRecipeID, .firstLastFrame, .wan21FirstLastFrame,
        width: .init(minimum: 480, maximum: 480, multiple: 16), height: .init(minimum: 832, maximum: 832, multiple: 16), frames: .init(minimum: 5, maximum: 33, stride: 4, offset: 1),
        fps: .init(minimum: 8, maximum: 24), steps: .init(minimum: 4, maximum: 40), sampler: "euler", usesFlowShift: true,
        recommended: settings(width: 480, height: 832, frames: 17, fps: 24, steps: 20, cfg: 6.0),
        note: "Dedicated Wan 2.1 FLF2V 14B checkpoint. The conservative preset uses the documented 480×832 canvas and a short 17-frame clip. Time, peak memory and quality are unmeasured on this Mac.")

    // MiniMax-H3's documented FL2VA route also accepts text-only and first-frame
    // requests. The initial GenStudio integration deliberately omits audio output;
    // the video frames still pass through the normal decode/encode validation path.
    static let minimaxH3TextToVideo: VideoCapability = {
        var value = adapter(MediaModelCatalog.minimaxH3RecipeID, .textToVideo, .minimaxH3,
        width: .init(minimum: 320, maximum: 864, multiple: 32), height: .init(minimum: 320, maximum: 864, multiple: 32), frames: .init(minimum: 5, maximum: 56, stride: 17, offset: 5),
        fps: .init(minimum: 24, maximum: 24), steps: .init(minimum: 8, maximum: 40), sampler: "euler", usesFlowShift: true,
        recommended: settings(width: 480, height: 320, frames: 22, fps: 24, steps: 20, cfg: 1.0, flowShift: 12.0),
        note: "MiniMax-H3 FL2VA video-only route. It can generate text-to-video; this adapter omits the optional audio VAE and has not completed a decoded local proof.")
        // Wall-clock runs on this Mac from the owner's run history (12 Oct 2026 audit).
        value.speedAnchors = [.init(width: 320, height: 544, frames: 56, fastDraft: false, seconds: 1081), .init(width: 544, height: 544, frames: 56, fastDraft: false, seconds: 1932)]
        return value
    }()
    static let minimaxH3ImageToVideo: VideoCapability = {
        var value = adapter(MediaModelCatalog.minimaxH3RecipeID, .imageToVideo, .minimaxH3,
        width: .init(minimum: 320, maximum: 864, multiple: 32), height: .init(minimum: 320, maximum: 864, multiple: 32), frames: .init(minimum: 5, maximum: 56, stride: 17, offset: 5),
        fps: .init(minimum: 24, maximum: 24), steps: .init(minimum: 8, maximum: 40), sampler: "euler", usesFlowShift: true,
        recommended: settings(width: 480, height: 320, frames: 22, fps: 24, steps: 20, cfg: 1.0, flowShift: 12.0),
        note: "MiniMax-H3 I2VA. The connected start image is conditioned with --init-img; generated audio is not retained by this version of GenStudio.")
        // Wall-clock runs on this Mac from the owner's run history (12 Oct 2026 audit).
        value.speedAnchors = [.init(width: 320, height: 544, frames: 56, fastDraft: false, seconds: 1081), .init(width: 544, height: 544, frames: 56, fastDraft: false, seconds: 1932)]
        return value
    }()
    static let minimaxH3FirstLastFrame: VideoCapability = {
        var value = adapter(MediaModelCatalog.minimaxH3RecipeID, .firstLastFrame, .minimaxH3,
        width: .init(minimum: 320, maximum: 864, multiple: 32), height: .init(minimum: 320, maximum: 864, multiple: 32), frames: .init(minimum: 5, maximum: 56, stride: 17, offset: 5),
        fps: .init(minimum: 24, maximum: 24), steps: .init(minimum: 8, maximum: 40), sampler: "euler", usesFlowShift: true,
        recommended: settings(width: 480, height: 320, frames: 22, fps: 24, steps: 20, cfg: 1.0, flowShift: 12.0),
        note: "MiniMax-H3 FL2VA. Start and end images are passed to the documented first/last-frame route; generated audio is not retained by this version of GenStudio.")
        // Wall-clock runs on this Mac from the owner's run history (12 Oct 2026 audit).
        value.speedAnchors = [.init(width: 320, height: 576, frames: 39, fastDraft: false, seconds: 1506)]
        return value
    }()
    static let minimaxH3VideoToVideo = adapter(MediaModelCatalog.minimaxH3Ref2VARecipeID, .videoToVideo, .minimaxH3Ref2VA,
        width: .init(minimum: 320, maximum: 864, multiple: 32), height: .init(minimum: 320, maximum: 864, multiple: 32), frames: .init(minimum: 5, maximum: 56, stride: 17, offset: 5),
        fps: .init(minimum: 24, maximum: 24), steps: .init(minimum: 8, maximum: 40), sampler: "euler", usesFlowShift: true,
        recommended: settings(width: 480, height: 320, frames: 22, fps: 24, steps: 20, cfg: 1.0, flowShift: 12.0),
        note: "MiniMax-H3 Ref2VA reference-video route. GenStudio extracts ordered 24 fps reference frames and supplies them to the runtime; generated audio is not retained.")

    // Rejected descriptors stay in the complete adapter registry so old saved workflows can be
    // diagnosed precisely and command contracts remain testable. They are never selectable or
    // executable until a later engine/model combination earns a real temporal proof.
    static let rejectedRecipeIDs: Set<String> = [MediaModelCatalog.animateDiffRecipeID]
    static let shipped: [VideoCapability] = [wanTextToVideo, fastMetal5TextToVideo, ltx23TextToVideo, ltx23ImageToVideo, ltx23FirstLastFrame, animateDiffTextToVideo, animateDiffImageToVideo, lingBotTextToVideo, lingBotImageToVideo, wan22TextToVideo, wan22ImageToVideo, ltx25TextToVideo, ltx25ImageToVideo, wan21FirstLastFrame, minimaxH3TextToVideo, minimaxH3ImageToVideo, minimaxH3FirstLastFrame, minimaxH3VideoToVideo]

    /// Explains a task with no descriptor in the supplied registry.
    static func unavailableReason(for task: VideoTask) -> String {
        switch task {
        case .textToVideo: "No installed recipe with a verified text-to-video adapter."
        case .imageToVideo: "No installed image-to-video adapter is available. Download LTX-2.3 MLX Q4 from Models → Start Here; FastMetal and Wan2.1 T2V cannot condition on a start image."
        case .firstLastFrame: "No installed start/end frame adapter is available. Install LTX-2.3 MLX Q4 from Models → Start Here (about 3 minutes per 5 s clip here), or MiniMax-H3 FL2VA for the highest quality."
        case .timedKeyframes: "Guided Shot needs a native multi-keyframe adapter. The bundled stable-diffusion.cpp runtime accepts at most the start/end image contracts in this build; it cannot submit several timed anchors in one job. LTX-2's KeyframeInterpolationPipeline is the planned integration path, but it is not wired or locally validated yet. Use Shot Sequence → Animatic for a timing preview, or create explicit pairwise Start/End Video transitions and assemble them. Guided Shot will not silently substitute either workflow."
        case .videoToVideo: "No installed video-to-video adapter is available. Install the MiniMax-H3 Ref2VA recipe; source clips are converted to ordered 24 fps reference frames and re-generated as a new clip."
        }
    }

    static func capabilities(for task: VideoTask, in registry: [VideoCapability] = shipped) -> [VideoCapability] {
        registry.filter { $0.task == task }
    }
    static func selectableCapabilities(for task: VideoTask, in registry: [VideoCapability] = shipped) -> [VideoCapability] {
        capabilities(for: task, in: registry).filter { $0.readiness.adapterAvailable && !rejectedRecipeIDs.contains($0.recipeID) }
    }
    static func rejectionReason(for recipeID: String) -> String? {
        guard rejectedRecipeIDs.contains(recipeID) else { return nil }
        return "This exact AnimateDiff Q4 recipe completed local T2V and I2V runs, but every decoded frame was byte-identical. It is disabled because a static repeated image is not valid video."
    }
    static func capability(recipeID: String, task: VideoTask, in registry: [VideoCapability] = shipped) -> VideoCapability? {
        registry.first { $0.recipeID == recipeID && $0.task == task }
    }
    /// True when some adapter for this task could run given a proven capability. Authoring never depends on this.
    static func hasRunnableAdapter(for task: VideoTask, in registry: [VideoCapability] = shipped) -> Bool {
        capabilities(for: task, in: registry).contains { $0.readiness.proven }
    }
    static func supportsRecipe(_ recipeID: String, in registry: [VideoCapability] = shipped) -> Bool {
        registry.contains { $0.recipeID == recipeID && $0.readiness.proven }
    }
    static func hasAdapter(_ recipeID: String, in registry: [VideoCapability] = shipped) -> Bool { registry.contains { $0.recipeID == recipeID } }
    static func hasUsableAdapter(_ recipeID: String, in registry: [VideoCapability] = shipped) -> Bool {
        registry.contains { $0.recipeID == recipeID && $0.readiness.adapterAvailable && !rejectedRecipeIDs.contains($0.recipeID) }
    }

    /// Product ordering for an M1-class local workflow. Proof/install state is considered by the
    /// caller first; this ranks exact task fits within the same state without pretending that one
    /// checkpoint can perform another recipe's contract.
    static func recommendationPriority(_ capability: VideoCapability) -> Int {
        switch (capability.task, capability.recipeID) {
        case (.textToVideo, MLXVideoModelCatalog.fastMetal5BRecipeID): 0
        case (.textToVideo, MLXVideoModelCatalog.ltx23Q4RecipeID): 1
        case (.imageToVideo, MLXVideoModelCatalog.ltx23Q4RecipeID): 0
        case (.textToVideo, wanT2VRecipeID): 0
        case (.imageToVideo, MediaModelCatalog.lingBotRecipeID): 0
        case (.imageToVideo, MediaModelCatalog.wan22TI2VRecipeID): 1
        case (.firstLastFrame, MLXVideoModelCatalog.ltx23Q4RecipeID): 0
        case (.firstLastFrame, MediaModelCatalog.wan21FLFRecipeID): 1
        case (.videoToVideo, MediaModelCatalog.minimaxH3Ref2VARecipeID): 0
        case (_, MediaModelCatalog.animateDiffRecipeID): 20
        case (_, MediaModelCatalog.minimaxH3RecipeID): 30
        default: 10
        }
    }
}

struct VideoMediaInput: Codable, Hashable, Sendable {
    let role: VideoInputRole
    let identity: MediaIdentity
    /// Retained location at request time; identity is the content hash above.
    let location: URL
    var anchorID: String? = nil
    var frameIndex: Int? = nil
}

/// A fully resolved request: every value an adapter needs, and everything provenance records.
struct VideoGenerationRequest: Codable, Hashable, Sendable {
    let task: VideoTask
    let recipeID: String
    let engineBuild: String
    let prompt: String
    let negativePrompt: String
    let width: Int
    let height: Int
    let frameCount: Int
    let fps: Int
    let steps: Int
    let cfgScale: Double
    let flowShift: Double
    let sampler: String
    /// Resolved before launch; a "random" seed is never recorded as random.
    let seed: UInt32
    let mediaInputs: [VideoMediaInput]
    var scheduler: String? = nil
    var strength: Double? = nil
    /// Identity of connected media before crop/resize; the prepared file identity is in mediaInputs.
    var sourceIdentities: [MediaIdentity]? = nil
    /// Legacy provenance from builds that required a separate video first-run opt-in.
    /// Current video execution ignores this value.
    var allowsUnverifiedLocalRun: Bool? = nil
    /// Model-specific prompt produced locally from the human-authored `prompt`. The authored
    /// text remains above for auditability; adapters use this only when it validates.
    var compiledPrompt: String? = nil
    var promptCompilerModelID: String? = nil
    /// Human-authored duration before the model's temporal rule resolved it to frameCount.
    var requestedDurationSeconds: Double? = nil
    /// True when an interpolated fast draft was requested on a route that offers one.
    var fastDraft: Bool? = nil
    /// True when sound was requested on a route that makes it. The decoded output records whether it was made.
    var sound: Bool? = nil
    /// Total sample duration (frameCount / fps). The last frame is displayed at (frameCount − 1) / fps.
    var duration: Double { Double(frameCount) / Double(fps) }
    var lastFrameTimestamp: Double { Double(frameCount - 1) / Double(fps) }
}

struct VideoInputPresence: Sendable {
    var prompt: String?
    var negativePrompt: String?
    /// Roles whose sockets are connected (or otherwise supplied) on the node, including unsupported ones.
    var suppliedRoles: Set<VideoInputRole>
}

enum VideoRequestPlanner {
    static let promptByteLimit = 16_384

    /// Pure validation shared by preflight and execution. Throws before any model loads.
    static func validate(settings: VideoGenerationSettings, task: VideoTask, capability: VideoCapability?, supplied: Set<VideoInputRole>) throws -> VideoCapability {
        guard let capability else { throw StudioError.validation(VideoCapabilityRegistry.unavailableReason(for: task)) }
        guard capability.task == task else { throw StudioError.validation("Recipe \(capability.recipeID) supports \(capability.task.title), not \(task.title).") }
        if case .unavailable(let reason) = capability.readiness { throw StudioError.validation(reason) }
        let unsupported = supplied.subtracting(capability.supportedRoles)
        if !unsupported.isEmpty {
            throw StudioError.validation("\(capability.recipeID) \(task.title) cannot use connected \(unsupported.map(\.rawValue).sorted().joined(separator: ", ")) input. Disconnect it explicitly; GenStudio never ignores a connected input.")
        }
        let missing = capability.requiredRoles.subtracting(supplied)
        if !missing.isEmpty { throw StudioError.validation("\(task.title) needs its \(missing.map(\.rawValue).sorted().joined(separator: ", ")) input.") }
        guard capability.width.contains(settings.width), capability.height.contains(settings.height) else {
            throw StudioError.validation("Video size must be width \(capability.width.summary) and height \(capability.height.summary) pixels for this recipe.")
        }
        guard capability.fps.contains(settings.fps) else { throw StudioError.validation("Frame rate must be \(capability.fps.summary) fps for this recipe.") }
        var resolvedSettings = settings
        let resolvedDuration = try VideoDurationResolver.apply(to: &resolvedSettings, rule: capability.frames)
        guard capability.frames.contains(resolvedDuration.frameCount) else {
            throw StudioError.validation("Frame count must be \(capability.frames.summary) for this recipe.")
        }
        guard capability.steps.contains(settings.steps) else { throw StudioError.validation("Sampling steps must be \(capability.steps.summary) for this recipe.") }
        guard settings.cfgScale.isFinite, (1...12).contains(settings.cfgScale) else { throw StudioError.validation("Guidance scale must be a finite number from 1 to 12.") }
        if capability.usesFlowShift {
            guard settings.flowShift.isFinite, (1...12).contains(settings.flowShift) else { throw StudioError.validation("Flow shift must be a finite number from 1 to 12.") }
        }
        if let bounds = capability.strength {
            guard bounds.contains(settings.strength ?? ImageCapabilityRegistry.defaultStrength) else { throw StudioError.validation("Strength must be \(bounds.summary) for this recipe.") }
        }
        guard settings.seed >= -1, settings.seed <= Int(UInt32.max) else { throw StudioError.validation("Seed must be −1 (random, resolved and recorded before launch) or 0–4294967295.") }
        return capability
    }

    static func makeRequest(settings: VideoGenerationSettings, task: VideoTask, capability: VideoCapability?, prompt: String, negativePrompt: String?, mediaInputs: [VideoMediaInput] = [], allowsUnverifiedLocalRun: Bool = false, randomSeed: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) throws -> VideoGenerationRequest {
        var supplied: Set<VideoInputRole> = Set(mediaInputs.map(\.role))
        supplied.insert(.prompt)
        if negativePrompt != nil { supplied.insert(.negativePrompt) }
        let capability = try validate(settings: settings, task: task, capability: capability, supplied: supplied)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StudioError.validation("\(task.title) needs a nonempty prompt.") }
        let negative = negativePrompt ?? settings.negativePrompt
        guard prompt.utf8.count <= promptByteLimit, negative.utf8.count <= promptByteLimit else { throw StudioError.validation("Prompts are limited to 16 KB.") }
        try EnginePromptSyntax.validate(prompt, negative)
        let seed = settings.seed < 0 ? randomSeed() : UInt32(settings.seed)
        var resolvedSettings = settings
        let duration = try VideoDurationResolver.apply(to: &resolvedSettings, rule: capability.frames)
        return .init(task: task, recipeID: capability.recipeID, engineBuild: capability.engineBuild, prompt: prompt, negativePrompt: negative, width: resolvedSettings.width, height: resolvedSettings.height, frameCount: duration.frameCount, fps: resolvedSettings.fps, steps: resolvedSettings.steps, cfgScale: resolvedSettings.cfgScale, flowShift: resolvedSettings.flowShift, sampler: capability.sampler ?? "default", seed: seed, mediaInputs: mediaInputs,
                     scheduler: capability.scheduler, strength: capability.strength == nil ? nil : (resolvedSettings.strength ?? ImageCapabilityRegistry.defaultStrength), allowsUnverifiedLocalRun: allowsUnverifiedLocalRun ? true : nil, requestedDurationSeconds: duration.requestedSeconds,
                     fastDraft: capability.supportsFastDraft && settings.fastDraft == true ? true : nil,
                     sound: capability.producesAudio && settings.sound != false ? true : nil)
    }
}
