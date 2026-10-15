import AVFoundation
import Foundation

struct AssemblyClipReport: Codable, Hashable, Sendable {
    let start: Double
    let duration: Double
    /// The clip's own asset has an audio track, regardless of assembly policy or range overlap.
    let sourceHasAudio: Bool
    /// Audio was actually inserted into the assembled composition for this clip.
    let audioCopied: Bool
}

struct AssemblyResult: Sendable {
    let probe: VideoProbe
    let clips: [AssemblyClipReport]
    let width: Int
    let height: Int
    let fps: Int
    let hasAudioTrack: Bool
}

/// One clip in a stitch, with its trims, level and incoming transition.
struct AssemblyClip: Sendable {
    let url: URL
    var edit = StitchClipEdit()
}

/// Ordered concatenation normalized to one render size and frame rate.
enum ClipAssembler {
    static func assemble(_ clips: [URL], settings: AssemblySettings, music: URL? = nil, to output: URL) async throws -> AssemblyResult {
        try await assemble(clips: clips.map { AssemblyClip(url: $0) }, settings: settings, music: music, to: output)
    }

    /// A clip's tracks, loaded once, with the part that plays after trims.
    struct Source {
        /// Held so its tracks stay valid until they are inserted; a track outlived by its asset cannot be read.
        let asset: AVURLAsset
        let video: AVAssetTrack
        /// The trimmed part of the video track that plays.
        let range: CMTimeRange
        let size: CGSize
        let transform: CGAffineTransform
        let audio: AVAssetTrack?
        let hasAudio: Bool
        let volume: Double
    }

    static func load(_ clips: [AssemblyClip], settings: AssemblySettings) async throws -> [Source] {
        guard (1...AssemblySettings.maximumClips).contains(clips.count) else { throw StudioError.validation("Stitcher accepts 1–\(AssemblySettings.maximumClips) clips.") }
        guard (1...60).contains(settings.fps) else { throw StudioError.validation("Stitcher frame rate must be 1–60 fps.") }
        var sources: [Source] = []
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: clip.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError.validation("\(clip.url.lastPathComponent) has no video track.") }
            let (range, size, transform, rate) = try await video.load(.timeRange, .naturalSize, .preferredTransform, .nominalFrameRate)
            guard range.duration.seconds.isFinite, range.duration.seconds > 0 else { throw StudioError.validation("\(clip.url.lastPathComponent) has no finite duration.") }
            _ = try DisplayGeometry.resolve(size: size, transform: transform, source: clip.url.lastPathComponent)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if settings.audio == .preserve, audioTracks.count > 1 {
                throw StudioError.validation("\(clip.url.lastPathComponent) has \(audioTracks.count) audio tracks. The Stitcher supports one audio track per clip; mix the audio first or mute clip sound.")
            }
            let skip = settings.skipRepeatedJoinFrame && index > 0 && rate > 0 ? 1 / Double(rate) : 0
            let window = try clip.edit.window(duration: range.duration.seconds, skipLeadingSeconds: skip, clipName: "Clip \(index + 1) (\(clip.url.lastPathComponent))")
            let timescale = max(600, range.start.timescale)
            let played = CMTimeRange(start: range.start + CMTime(seconds: window.lowerBound, preferredTimescale: timescale),
                                     end: range.start + CMTime(seconds: window.upperBound, preferredTimescale: timescale))
            sources.append(.init(asset: asset, video: video, range: played, size: size, transform: transform,
                                 audio: audioTracks.first, hasAudio: !audioTracks.isEmpty, volume: min(1, max(0, clip.edit.volume))))
        }
        return sources
    }

    /// Output size: the settings' size, or the first clip's display size rounded to even pixels.
    static func renderSize(_ sources: [Source], settings: AssemblySettings) throws -> (width: Int, height: Int) {
        let first = CGRect(origin: .zero, size: sources[0].size).applying(sources[0].transform)
        func even(_ value: Double) -> Int { max(16, Int(value.rounded()) & ~1) }
        let width = settings.width > 0 ? settings.width : even(abs(first.width))
        let height = settings.height > 0 ? settings.height : even(abs(first.height))
        guard (16...4096).contains(width), (16...4096).contains(height), width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw StudioError.validation("Stitcher size must be even and 16–4096 pixels per side.")
        }
        return (width, height)
    }

    /// Places a clip centred in the output, scaled to fit inside it or to fill it (the render size crops the overflow).
    static func placement(_ source: Source, width: Int, height: Int, framing: AssemblyFraming) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: source.size).applying(source.transform)
        let sx = Double(width) / abs(bounds.width), sy = Double(height) / abs(bounds.height)
        let scale = framing == .fill ? max(sx, sy) : min(sx, sy)
        var transform = source.transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return transform.concatenating(CGAffineTransform(translationX: (Double(width) - abs(bounds.width) * scale) / 2, y: (Double(height) - abs(bounds.height) * scale) / 2))
    }

    static func checkFrameBudget(seconds: Double, fps: Int) throws {
        // Reject before the expensive export/decode pass, not after: a composition longer than the
        // decoder's frame-validation limit (VideoProbe.frameLimit) would otherwise export in full,
        // then fail validation only once VideoProbe.inspect re-decodes it.
        let expectedFrames = Int((seconds * Double(fps)).rounded(.up))
        guard expectedFrames <= VideoProbe.frameLimit else {
            throw StudioError.validation("The stitch would produce about \(expectedFrames) frames at \(fps) fps, over the \(VideoProbe.frameLimit)-frame decode-validation limit. Use fewer or shorter clips, or a lower frame rate.")
        }
    }

    static func assemble(clips: [AssemblyClip], settings: AssemblySettings, music: URL? = nil, to output: URL) async throws -> AssemblyResult {
        let sources = try await load(clips, settings: settings)
        let joins = Array(clips.dropFirst().map { $0.edit.transitionIn ?? settings.transition })
        if settings.needsMixdown(edits: clips.map(\.edit), joins: joins) || music != nil {
            return try await assembleFinished(sources, joins: joins, settings: settings, music: music, to: output)
        }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError.validation("Could not create the stitch video track.") }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var reports: [AssemblyClipReport] = []
        var placed: [CMTimeRange] = []
        for source in sources {
            try Task.checkCancellation()
            try videoTrack.insertTimeRange(source.range, of: source.video, at: cursor)
            var audioCopied = false
            if settings.audio == .preserve, let sourceAudio = source.audio {
                let audioRange = try await sourceAudio.load(.timeRange)
                let usable = CMTimeRangeGetIntersection(audioRange, otherRange: source.range)
                if usable.duration.seconds > 0 {
                    // One continuous track for the whole stitch; a clip without sound leaves silence in place.
                    guard let track = audioTrack ?? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw StudioError.validation("Could not create the stitch audio track.")
                    }
                    audioTrack = track
                    try track.insert(usable, of: sourceAudio, placedAt: cursor + (usable.start - source.range.start))
                    audioCopied = true
                }
            }
            placed.append(CMTimeRange(start: cursor, duration: source.range.duration))
            reports.append(.init(start: cursor.seconds, duration: source.range.duration.seconds, sourceHasAudio: source.hasAudio, audioCopied: audioCopied))
            cursor = cursor + source.range.duration
        }
        try checkFrameBudget(seconds: cursor.seconds, fps: settings.fps)
        let (width, height) = try renderSize(sources, settings: settings)
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
        for (source, range) in zip(sources, placed) {
            layer.setTransform(placement(source, width: width, height: height, framing: settings.framing), at: range.start)
        }
        let instruction = AVVideoCompositionInstruction(configuration: .init(layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)], timeRange: CMTimeRange(start: .zero, duration: cursor)))
        let videoComposition = AVVideoComposition(configuration: .init(frameDuration: CMTime(value: 1, timescale: CMTimeScale(settings.fps)), instructions: [instruction], renderSize: CGSize(width: width, height: height)))

        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError.validation("Could not create the stitch exporter.") }
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: .zero, duration: cursor)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: output) } }
        do { try await session.export(to: output, as: .mov) }
        catch is CancellationError { throw CancellationError() }
        catch { throw StudioError.validation("Stitch export failed: \(error.localizedDescription)") }
        try Task.checkCancellation()
        let probe = try await VideoProbe.inspect(output)
        let expected = cursor.seconds
        guard probe.width == width, probe.height == height, abs(probe.duration - expected) <= 1.5 / Double(settings.fps) else {
            throw StudioError.validation("Stitch validation failed: expected \(width)×\(height) over \(expected) s; decoded \(probe.width)×\(probe.height) over \(probe.duration) s.")
        }
        guard probe.hasAudio == (audioTrack != nil) else { throw StudioError.validation("Stitch audio does not match the selected policy.") }
        succeeded = true
        return .init(probe: probe, clips: reports, width: width, height: height, fps: settings.fps, hasAudioTrack: audioTrack != nil)
    }
}
