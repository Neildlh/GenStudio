import Foundation

/// Inspector-owned settings for generation nodes. Only the capability descriptor decides what is valid.
struct VideoGenerationSettings: Codable, Hashable, Sendable {
    var negativePrompt = "static, frozen, blurry, low quality, distorted"
    var width = 320
    var height = 192
    var frameCount = 9
    var fps = 8
    var steps = 20
    var cfgScale = 6.0
    var flowShift = 3.0
    /// −1 requests a random seed that is resolved and recorded before launch.
    var seed = 424243
    /// Start-image strength for adapters that re-noise the start image. Nil uses 0.75 and keeps older documents unchanged.
    var strength: Double? = nil
    /// Human-authored clip length. Frame count remains cached for display and legacy persistence,
    /// but every runtime request resolves it again against the exact selected capability.
    var requestedDurationSeconds = 9.0 / 8.0
    /// Opt-in interpolated draft on routes that offer one (FastMetal): denoise every second frame,
    /// then interpolate. Nil keeps older documents byte-for-byte unchanged; routes without the mode ignore it.
    var fastDraft: Bool? = nil
    /// Sound generated with the picture on routes that make it (LTX-2.3). Nil means on; false keeps the clip
    /// silent. Older documents omit it, and silent routes ignore it.
    var sound: Bool? = nil
    var duration: Double { fps > 0 ? Double(frameCount) / Double(fps) : 0 }
    var lastFrameTimestamp: Double { fps > 0 ? Double(max(frameCount - 1, 0)) / Double(fps) : 0 }

    init(
        negativePrompt: String = "static, frozen, blurry, low quality, distorted",
        width: Int = 320,
        height: Int = 192,
        frameCount: Int = 9,
        fps: Int = 8,
        steps: Int = 20,
        cfgScale: Double = 6.0,
        flowShift: Double = 3.0,
        seed: Int = 424243,
        strength: Double? = nil,
        requestedDurationSeconds: Double? = nil
    ) {
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.fps = fps
        self.steps = steps
        self.cfgScale = cfgScale
        self.flowShift = flowShift
        self.seed = seed
        self.strength = strength
        self.requestedDurationSeconds = requestedDurationSeconds ?? (fps > 0 ? Double(frameCount) / Double(fps) : 0)
    }

    private enum CodingKeys: String, CodingKey {
        case negativePrompt, width, height, frameCount, fps, steps, cfgScale, flowShift, seed, strength, requestedDurationSeconds, fastDraft, sound
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        negativePrompt = try values.decodeIfPresent(String.self, forKey: .negativePrompt) ?? "static, frozen, blurry, low quality, distorted"
        width = try values.decodeIfPresent(Int.self, forKey: .width) ?? 320
        height = try values.decodeIfPresent(Int.self, forKey: .height) ?? 192
        frameCount = try values.decodeIfPresent(Int.self, forKey: .frameCount) ?? 9
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? 8
        steps = try values.decodeIfPresent(Int.self, forKey: .steps) ?? 20
        cfgScale = try values.decodeIfPresent(Double.self, forKey: .cfgScale) ?? 6.0
        flowShift = try values.decodeIfPresent(Double.self, forKey: .flowShift) ?? 3.0
        seed = try values.decodeIfPresent(Int.self, forKey: .seed) ?? 424243
        strength = try values.decodeIfPresent(Double.self, forKey: .strength)
        requestedDurationSeconds = try values.decodeIfPresent(Double.self, forKey: .requestedDurationSeconds)
            ?? (fps > 0 ? Double(frameCount) / Double(fps) : 0)
        fastDraft = try values.decodeIfPresent(Bool.self, forKey: .fastDraft)
        sound = try values.decodeIfPresent(Bool.self, forKey: .sound)
    }

    /// The previously measured direct-CLI probe shape; a starting point, not a quality claim.
    static let measuredProbe = VideoGenerationSettings()
}

enum ShotBoundary: String, Codable, CaseIterable, Sendable {
    /// The next anchor should continue the same shot when a generator supports it.
    case continuous
    /// A deliberate edit point between distinct shots.
    case cut
}

/// A still anchor with a stable identity. Its id is also the node's input socket id,
/// so reordering or inserting anchors never moves a connection to another image.
struct ShotAnchor: Codable, Hashable, Identifiable, Sendable {
    var id: String = "anchor-\(UUID().uuidString.lowercased())"
    var label: String
    /// Seconds from this anchor to the next. Ignored for the last anchor, which uses the sequence final hold.
    var holdSeconds = 2.0
    /// Direction toward the next anchor. Animatic records it; it is not a generation prompt schedule.
    var transitionNote = ""
    var boundaryToNext = ShotBoundary.cut
    /// Optional imported still. A connected socket and a chosen file together are rejected, never merged.
    var imagePath: String? = nil
}

struct ShotSequenceSpec: Codable, Hashable, Sendable {
    static let maximumAnchors = 64
    var anchors: [ShotAnchor] = []
    var finalHoldSeconds = 2.0
    var fps = 24
    var width = 1280
    var height = 720
}

struct ResolvedAnchorTiming: Codable, Hashable, Sendable {
    let anchorID: String
    /// Authored time in seconds; the adapter or encoder resolves it onto a frame grid separately.
    let authoredTime: Double
    let startFrame: Int
    /// Exclusive.
    let endFrame: Int
    var frameCount: Int { endFrame - startFrame }
}

struct SequenceTiming: Codable, Hashable, Sendable {
    let fps: Int
    let anchors: [ResolvedAnchorTiming]
    let frameCount: Int
    /// Total sample duration: frameCount / fps.
    var duration: Double { Double(frameCount) / Double(fps) }
    /// Presentation time of the final sample, one frame before the duration.
    var lastFrameTimestamp: Double { Double(frameCount - 1) / Double(fps) }

    static func resolve(_ spec: ShotSequenceSpec) throws -> SequenceTiming {
        guard !spec.anchors.isEmpty else { throw StudioError.validation("Add at least one frame to the Shot Sequence.") }
        guard spec.anchors.count <= ShotSequenceSpec.maximumAnchors else { throw StudioError.validation("A Shot Sequence supports at most \(ShotSequenceSpec.maximumAnchors) frames.") }
        guard Set(spec.anchors.map(\.id)).count == spec.anchors.count else { throw StudioError.validation("Shot Sequence frame identifiers must be unique.") }
        guard (1...60).contains(spec.fps) else { throw StudioError.validation("Output frame rate must be 1–60 fps.") }
        guard spec.finalHoldSeconds.isFinite, spec.finalHoldSeconds > 0 else { throw StudioError.validation("Final hold must be a finite number of seconds greater than zero.") }
        var times: [Double] = [0]
        for anchor in spec.anchors.dropLast() {
            guard anchor.holdSeconds.isFinite, anchor.holdSeconds > 0 else { throw StudioError.validation("\(anchor.label) hold must be a finite number of seconds greater than zero.") }
            times.append(times[times.count - 1] + anchor.holdSeconds)
        }
        let total = times[times.count - 1] + spec.finalHoldSeconds
        guard total <= 600 else { throw StudioError.validation("Shot Sequence duration is limited to 10 minutes.") }
        let starts = times.map { Int(($0 * Double(spec.fps)).rounded()) }
        let frameCount = Int((total * Double(spec.fps)).rounded())
        var resolved: [ResolvedAnchorTiming] = []
        for index in spec.anchors.indices {
            let end = index + 1 < starts.count ? starts[index + 1] : frameCount
            guard end > starts[index] else {
                throw StudioError.validation("\(spec.anchors[index].label) resolves to no frames at \(spec.fps) fps. Lengthen its hold or raise the frame rate.")
            }
            resolved.append(.init(anchorID: spec.anchors[index].id, authoredTime: times[index], startFrame: starts[index], endFrame: end))
        }
        return .init(fps: spec.fps, anchors: resolved, frameCount: frameCount)
    }
}

/// Typed runtime payload for sequence-consuming nodes: ordered retained stills with content identity.
struct ResolvedShotSequence: Codable, Hashable, Sendable {
    struct Anchor: Codable, Hashable, Sendable {
        let anchorID: String
        let label: String
        let image: URL
        let identity: MediaIdentity
        let transitionNote: String
        let boundaryToNext: ShotBoundary
    }
    let anchors: [Anchor]
    let timing: SequenceTiming
    let width: Int
    let height: Int
}

enum AssemblyAudioPolicy: String, Codable, CaseIterable, Sendable {
    /// Keep clip audio in place; clips without audio contribute silence for their duration.
    case preserve
    /// Output has no audio track.
    case silent

    var title: String { self == .preserve ? "Keep (silence where a clip has none)" : "Mute clip sound" }
}

enum AssemblyTransition: String, Codable, CaseIterable, Sendable {
    case cut, dissolve, dipToBlack
    var title: String {
        switch self { case .cut: "Hard cut"; case .dissolve: "Cross-dissolve"; case .dipToBlack: "Dip to black" }
    }
    /// Transitions that overlap the neighbouring clips and so shorten the stitch.
    var overlaps: Bool { self != .cut }
}

/// How a clip whose shape differs from the output is placed in the frame.
enum AssemblyFraming: String, Codable, CaseIterable, Sendable {
    /// The whole picture is visible; bars fill the difference.
    case fit
    /// The frame is filled; the overflowing edges are cropped.
    case fill
    var title: String { self == .fit ? "Fit (show the whole clip)" : "Fill (crop the edges)" }
}

/// Per-clip edits in a Stitcher, kept by clip slot so they follow the clip when slots are reordered.
struct StitchClipEdit: Codable, Hashable, Sendable {
    /// Seconds cut from the clip's start (AI clips often settle over their first frames).
    var trimStart = 0.0
    /// Seconds cut from the clip's end.
    var trimEnd = 0.0
    /// Level of the clip's own sound, 0–1.
    var volume = 1.0
    /// The transition into this clip. Nil uses the node's default; ignored on the first clip.
    var transitionIn: AssemblyTransition?

    static let minimumSeconds = 0.1
    var isDefault: Bool { self == StitchClipEdit() }

    init(trimStart: Double = 0, trimEnd: Double = 0, volume: Double = 1, transitionIn: AssemblyTransition? = nil) {
        self.trimStart = trimStart; self.trimEnd = trimEnd; self.volume = volume; self.transitionIn = transitionIn
    }

    private enum CodingKeys: String, CodingKey { case trimStart, trimEnd, volume, transitionIn }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? 0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        transitionIn = try c.decodeIfPresent(AssemblyTransition.self, forKey: .transitionIn)
    }

    /// The part of a clip of `duration` seconds that plays, after trims and an optional skipped first frame.
    func window(duration: Double, skipLeadingSeconds: Double = 0, clipName: String) throws -> ClosedRange<Double> {
        guard trimStart >= 0, trimEnd >= 0 else { throw StudioError.validation("\(clipName): trims cannot be negative.") }
        let start = trimStart + skipLeadingSeconds, end = duration - trimEnd
        guard end - start >= Self.minimumSeconds else {
            throw StudioError.validation("\(clipName) is \(duration.formatted(.number.precision(.fractionLength(2)))) s long, but its trims remove \((duration - max(0, end - start)).formatted(.number.precision(.fractionLength(2)))) s. Shorten the trims so at least \(Self.minimumSeconds.formatted()) s plays.")
        }
        return start...end
    }
}

struct AssemblySettings: Codable, Hashable, Sendable {
    static let maximumClips = 32
    /// Zero means match the first clip's display size, rounded to even pixels.
    var width = 0
    var height = 0
    var fps = 24
    var audio = AssemblyAudioPolicy.preserve
    var transition = AssemblyTransition.cut
    /// Overlap of each cross-dissolve; Assemble shortens it so every clip keeps a moment of its own.
    var transitionSeconds = 0.5
    var fadeIn = false
    var fadeOut = false
    /// A music file under the whole assembly, looped to fill it. Independent of the clip-sound policy.
    var musicPath: String?
    var musicVolume = 0.6
    /// Lower the music while a clip has its own sound.
    var duckMusic = true
    var framing = AssemblyFraming.fit
    /// Frame-chained shots (each starting on the previous clip's last frame) repeat that frame at the join,
    /// which reads as a stutter. When on, every clip after the first skips its first frame.
    var skipRepeatedJoinFrame = false
    /// Trims, level and transition per clip slot, keyed by slot id. Slots without an entry play whole.
    var clipEdits: [String: StitchClipEdit] = [:]

    static let fadeSeconds = 0.6
    static let musicFadeOutSeconds = 1.5

    func edit(for slotID: String) -> StitchClipEdit { clipEdits[slotID] ?? .init() }

    /// These settings with edits kept only for `slotIDs` that differ from the defaults.
    func pruned(to slotIDs: [String]) -> AssemblySettings {
        var copy = self
        copy.clipEdits = clipEdits.filter { slotIDs.contains($0.key) && !$0.value.isDefault }
        return copy
    }

    /// The transition at each join, between clip `i` and `i + 1`, for clips in `slotIDs` order.
    func joins(_ slotIDs: [String]) -> [AssemblyTransition] {
        slotIDs.dropFirst().map { edit(for: $0).transitionIn ?? transition }
    }

    /// Plain cuts with no fades, music or level changes keep the original single-pass assembly.
    var needsMixdown: Bool { needsMixdown(edits: []) }
    func needsMixdown(edits: [StitchClipEdit], joins: [AssemblyTransition]? = nil) -> Bool {
        let anyOverlap = joins.map { $0.contains { $0.overlaps } } ?? transition.overlaps
        return anyOverlap || fadeIn || fadeOut || musicPath != nil || (audio == .preserve && edits.contains { $0.volume < 1 })
    }

    init(width: Int = 0, height: Int = 0, fps: Int = 24, audio: AssemblyAudioPolicy = .preserve) {
        self.width = width; self.height = height; self.fps = fps; self.audio = audio
    }

    private enum CodingKeys: String, CodingKey { case width, height, fps, audio, transition, transitionSeconds, fadeIn, fadeOut, musicPath, musicVolume, duckMusic, framing, skipRepeatedJoinFrame, clipEdits }

    /// Assemblies saved before transitions and music open as plain cuts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 24
        audio = try c.decodeIfPresent(AssemblyAudioPolicy.self, forKey: .audio) ?? .preserve
        transition = try c.decodeIfPresent(AssemblyTransition.self, forKey: .transition) ?? .cut
        transitionSeconds = try c.decodeIfPresent(Double.self, forKey: .transitionSeconds) ?? 0.5
        fadeIn = try c.decodeIfPresent(Bool.self, forKey: .fadeIn) ?? false
        fadeOut = try c.decodeIfPresent(Bool.self, forKey: .fadeOut) ?? false
        musicPath = try c.decodeIfPresent(String.self, forKey: .musicPath)
        musicVolume = try c.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.6
        duckMusic = try c.decodeIfPresent(Bool.self, forKey: .duckMusic) ?? true
        framing = try c.decodeIfPresent(AssemblyFraming.self, forKey: .framing) ?? .fit
        skipRepeatedJoinFrame = try c.decodeIfPresent(Bool.self, forKey: .skipRepeatedJoinFrame) ?? false
        clipEdits = try c.decodeIfPresent([String: StitchClipEdit].self, forKey: .clipEdits) ?? [:]
    }
}

struct RenderedMediaProvenance: Codable, Hashable, Sendable {
    enum Operation: String, Codable, Sendable { case animatic, assembly, textToVideo, imageToVideo, firstLastFrame, videoToVideo, endCard, textOverlay, voiceover }
    let operation: Operation
    let output: MediaIdentity
    let inputs: [MediaIdentity]
    let width: Int
    let height: Int
    let fps: Int
    let frameCount: Int
    let duration: Double
    var lastFrameTimestamp: Double? = nil
    var timing: SequenceTiming? = nil
    var audio: AssemblyAudioPolicy? = nil
    var hasAudioTrack = false
    var request: VideoGenerationRequest? = nil
    var elapsedSeconds: Double? = nil
    /// Present for model-backed generation. Nil keeps older provenance and non-generation operations compatible.
    var requestedDurationSeconds: Double? = nil
    /// Stitcher settings in force for the run, including per-clip trims, so the cut can be reproduced.
    var assembly: AssemblySettings? = nil
}
