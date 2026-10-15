import AVFoundation
import Foundation

/// Where each clip starts once neighbours overlap at a dissolve or dip. Each overlap is limited to 45% of the
/// shorter of its two clips, so every clip keeps a moment of its own and a clip never overlaps the one two places away.
struct AssemblyTimeline: Sendable {
    let durations: [Double]
    /// The transition at each join, between clip `i` and `i + 1`.
    let joins: [AssemblyTransition]
    /// The overlap at each join; zero at a cut.
    let overlaps: [Double]
    let starts: [Double]
    var total: Double { (starts.last ?? 0) + (durations.last ?? 0) }
    /// The longest overlap at any join.
    var overlap: Double { overlaps.max() ?? 0 }

    init(durations: [Double], transition: AssemblyTransition, seconds: Double) {
        self.init(durations: durations, joins: Array(repeating: transition, count: max(0, durations.count - 1)), seconds: seconds)
    }

    init(durations: [Double], joins: [AssemblyTransition], seconds: Double) {
        self.durations = durations
        let joins = Array(joins.prefix(max(0, durations.count - 1)))
        self.joins = joins
        overlaps = joins.indices.map { i in joins[i].overlaps ? max(0, min(seconds, min(durations[i], durations[i + 1]) * 0.45)) : 0 }
        var starts: [Double] = [], cursor = 0.0
        for (index, duration) in durations.enumerated() { starts.append(cursor); cursor += duration - (index < overlaps.count ? overlaps[index] : 0) }
        self.starts = starts
    }

    func overlapIn(_ index: Int) -> Double { index > 0 ? overlaps[index - 1] : 0 }
    func overlapOut(_ index: Int) -> Double { index < overlaps.count ? overlaps[index] : 0 }
}

/// A piecewise-linear volume over time, applied to an audio-mix track as consecutive ramps.
struct VolumeEnvelope: Sendable {
    /// Music under a clip that has its own sound plays at this share of its level.
    static let duckFactor = 0.3
    static let duckRamp = 0.3
    private(set) var points: [(time: Double, volume: Double)]

    init(points: [(time: Double, volume: Double)]) {
        var merged: [(time: Double, volume: Double)] = []
        for point in points.sorted(by: { $0.time < $1.time }) {
            if let last = merged.last, abs(last.time - point.time) < 0.000_5 { merged[merged.count - 1] = point } else { merged.append(point) }
        }
        self.points = merged
    }

    func volume(at time: Double) -> Double {
        guard let first = points.first else { return 1 }
        if time <= first.time { return first.volume }
        for (a, b) in zip(points, points.dropFirst()) where time <= b.time {
            let span = b.time - a.time
            return span <= 0 ? b.volume : a.volume + (b.volume - a.volume) * (time - a.time) / span
        }
        return points.last!.volume
    }

    /// Music at `level`, dipping to `duckFactor` while clips have their own sound, fading out at the end.
    static func music(total: Double, level: Double, duck: Bool, clipSound: [ClosedRange<Double>], fadeOut: Double) -> VolumeEnvelope {
        func duckShare(_ t: Double) -> Double {
            guard duck else { return 1 }
            var share = 1.0
            for window in clipSound {
                let depth: Double
                if t >= window.lowerBound && t <= window.upperBound { depth = 1 }
                else if t < window.lowerBound { depth = max(0, 1 - (window.lowerBound - t) / duckRamp) }
                else { depth = max(0, 1 - (t - window.upperBound) / duckRamp) }
                share = min(share, 1 - (1 - duckFactor) * depth)
            }
            return share
        }
        let fadeStart = max(0, total - fadeOut)
        func fade(_ t: Double) -> Double { t <= fadeStart ? 1 : max(0, (total - t) / max(fadeOut, 0.001)) }
        var times: Set<Double> = [0, total, fadeStart]
        for window in clipSound {
            for t in [window.lowerBound - duckRamp, window.lowerBound, window.upperBound, window.upperBound + duckRamp] where t >= 0 && t <= total { times.insert(t) }
        }
        // Extra samples through the fade keep the product of dip and fade smooth.
        for step in 1..<6 { times.insert(fadeStart + (total - fadeStart) * Double(step) / 6) }
        return VolumeEnvelope(points: times.sorted().map { ($0, level * duckShare($0) * fade($0)) })
    }

    func apply(to parameters: AVMutableAudioMixInputParameters, timescale: CMTimeScale = 48_000) {
        guard let first = points.first else { return }
        parameters.setVolume(Float(first.volume), at: CMTime(seconds: first.time, preferredTimescale: timescale))
        for (a, b) in zip(points, points.dropFirst()) where b.time > a.time {
            let range = CMTimeRange(start: CMTime(seconds: a.time, preferredTimescale: timescale), end: CMTime(seconds: b.time, preferredTimescale: timescale))
            parameters.setVolumeRamp(fromStartVolume: Float(a.volume), toEndVolume: Float(b.volume), timeRange: range)
        }
    }
}

extension AVMutableCompositionTrack {
    /// Inserts at `time`, first filling any gap after the track's current end with an empty edit
    /// (a composition track cannot be inserted into beyond its end).
    func insert(_ range: CMTimeRange, of track: AVAssetTrack, placedAt time: CMTime) throws {
        let end = timeRange.end
        if end.isValid, time > end { insertEmptyTimeRange(CMTimeRange(start: end, end: time)) }
        else if !end.isValid || timeRange.duration == .zero, time > .zero { insertEmptyTimeRange(CMTimeRange(start: .zero, end: time)) }
        try insertTimeRange(range, of: track, at: time)
    }
}

extension ClipAssembler {
    /// Stitch with dissolves, dips, fades, music or clip levels. The picture is rendered with opacity ramps; every sound
    /// (each clip's own, crossfaded with its neighbours, and the music) is mixed into one track, then joined.
    static func assembleFinished(_ sources: [Source], joins: [AssemblyTransition], settings: AssemblySettings, music: URL?, to output: URL) async throws -> AssemblyResult {
        let timeline = AssemblyTimeline(durations: sources.map(\.range.duration.seconds), joins: joins, seconds: settings.transitionSeconds)
        let timescale: CMTimeScale = 600
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }
        let total = time(timeline.total)
        try checkFrameBudget(seconds: timeline.total, fps: settings.fps)
        let (width, height) = try renderSize(sources, settings: settings)

        // Picture: clips alternate between two tracks so a transition can show both.
        let picture = AVMutableComposition()
        guard let trackA = picture.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let trackB = picture.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.validation("Could not create the stitch video tracks.")
        }
        let videoTracks = [trackA, trackB]
        for (index, source) in sources.enumerated() {
            try videoTracks[index % 2].insert(source.range, of: source.video, placedAt: time(timeline.starts[index]))
        }
        let fade = min(AssemblySettings.fadeSeconds, timeline.total / 4)
        /// `ramp` is the opacity across `range` (start, end); nil holds the clip fully visible.
        func layer(_ index: Int, during range: CMTimeRange, ramp: (Float, Float)? = nil) -> AVVideoCompositionLayerInstruction {
            var configuration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTracks[index % 2])
            configuration.setTransform(placement(sources[index], width: width, height: height, framing: settings.framing), at: range.start)
            if let ramp { configuration.addOpacityRamp(.init(timeRange: range, start: ramp.0, end: ramp.1)) }
            if index == 0, settings.fadeIn, range.start.seconds < fade {
                let end = min(fade, range.end.seconds)
                configuration.addOpacityRamp(.init(timeRange: CMTimeRange(start: range.start, end: time(end)), start: Float(range.start.seconds / fade), end: Float(end / fade)))
            }
            if index == sources.count - 1, settings.fadeOut, range.end.seconds > timeline.total - fade {
                let start = max(timeline.total - fade, range.start.seconds)
                configuration.addOpacityRamp(.init(timeRange: CMTimeRange(start: time(start), end: range.end), start: Float((timeline.total - start) / fade), end: 0))
            }
            return AVVideoCompositionLayerInstruction(configuration: configuration)
        }
        func instruction(_ layers: [AVVideoCompositionLayerInstruction], _ range: CMTimeRange) -> AVVideoCompositionInstruction {
            AVVideoCompositionInstruction(configuration: .init(layerInstructions: layers, timeRange: range))
        }
        var instructions: [AVVideoCompositionInstruction] = []
        for index in sources.indices {
            let start = timeline.starts[index] + timeline.overlapIn(index)
            let end = timeline.starts[index] + timeline.durations[index] - timeline.overlapOut(index)
            let solo = CMTimeRange(start: time(start), end: index == sources.count - 1 ? total : time(end))
            instructions.append(instruction([layer(index, during: solo)], solo))
            let overlap = timeline.overlapOut(index)
            guard index < sources.count - 1, overlap > 0 else { continue }
            let blend = CMTimeRange(start: time(end), end: time(timeline.starts[index + 1] + overlap))
            switch timeline.joins[index] {
            case .dipToBlack:
                // The outgoing shot fades to black, then the incoming one fades up from it.
                let middle = time(end + overlap / 2)
                let out = CMTimeRange(start: blend.start, end: middle), into = CMTimeRange(start: middle, end: blend.end)
                instructions.append(instruction([layer(index, during: out, ramp: (1, 0))], out))
                instructions.append(instruction([layer(index + 1, during: into, ramp: (0, 1))], into))
            default:
                // The first layer is drawn on top: the outgoing shot fades away over the incoming one.
                instructions.append(instruction([layer(index, during: blend, ramp: (1, 0)), layer(index + 1, during: blend)], blend))
            }
        }
        let videoComposition = AVVideoComposition(configuration: .init(frameDuration: CMTime(value: 1, timescale: CMTimeScale(settings.fps)), instructions: instructions, renderSize: CGSize(width: width, height: height)))

        let scratch = output.deletingLastPathComponent().appending(path: "assembly-parts-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pictureFile = scratch.appending(path: "picture.mov")
        guard let session = AVAssetExportSession(asset: picture, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError.validation("Could not create the stitch exporter.") }
        session.videoComposition = videoComposition
        session.timeRange = CMTimeRange(start: .zero, duration: total)
        do { try await session.export(to: pictureFile, as: .mov) }
        catch is CancellationError { throw CancellationError() }
        catch { throw StudioError.validation("Stitch export failed: \(error.localizedDescription)") }
        try Task.checkCancellation()

        // Sound: each clip's own (crossfaded like the picture), plus music under everything, mixed to one track.
        let sound = AVMutableComposition()
        let mix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []
        var reports: [AssemblyClipReport] = []
        var clipSoundWindows: [ClosedRange<Double>] = []
        var clipTracks: [AVMutableCompositionTrack] = []
        var clipEnvelopePoints: [[(time: Double, volume: Double)]] = [[], []]
        for (index, source) in sources.enumerated() {
            let start = timeline.starts[index], duration = timeline.durations[index], end = start + duration
            var copied = false
            if settings.audio == .preserve, let audio = source.audio {
                let usable = CMTimeRangeGetIntersection(try await audio.load(.timeRange), otherRange: source.range)
                if usable.duration.seconds > 0 {
                    while clipTracks.count <= index % 2 {
                        guard let track = sound.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError.validation("Could not create the stitch audio track.") }
                        clipTracks.append(track)
                    }
                    let at = time(start) + (usable.start - source.range.start)
                    try clipTracks[index % 2].insert(usable, of: audio, placedAt: at)
                    copied = true
                    if source.volume > 0 { clipSoundWindows.append(at.seconds...(at + usable.duration).seconds) }
                    clipEnvelopePoints[index % 2] += Self.clipEnvelope(start: start, end: end, level: source.volume,
                                                                       into: index > 0 ? (timeline.joins[index - 1], timeline.overlapIn(index)) : nil,
                                                                       out: index < sources.count - 1 ? (timeline.joins[index], timeline.overlapOut(index)) : nil,
                                                                       fadeIn: index == 0 && settings.fadeIn ? fade : 0,
                                                                       fadeOut: index == sources.count - 1 && settings.fadeOut ? fade : 0)
                }
            }
            reports.append(.init(start: start, duration: duration, sourceHasAudio: source.hasAudio, audioCopied: copied))
        }
        for (slot, track) in clipTracks.enumerated() {
            let input = AVMutableAudioMixInputParameters(track: track)
            VolumeEnvelope(points: clipEnvelopePoints[slot]).apply(to: input)
            parameters.append(input)
        }
        if let music {
            let asset = AVURLAsset(url: music)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw StudioError.validation("The music file \(music.lastPathComponent) has no sound.") }
            let range = try await source.load(.timeRange)
            guard range.duration.seconds > 0.05, let track = sound.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw StudioError.validation("The music file \(music.lastPathComponent) is too short to use.")
            }
            var cursor = CMTime.zero
            while cursor < total {
                try Task.checkCancellation()
                let piece = CMTimeRange(start: range.start, duration: CMTimeMinimum(range.duration, total - cursor))
                try track.insertTimeRange(piece, of: source, at: cursor)
                cursor = cursor + piece.duration
            }
            let input = AVMutableAudioMixInputParameters(track: track)
            VolumeEnvelope.music(total: timeline.total, level: min(1, max(0, settings.musicVolume)), duck: settings.duckMusic, clipSound: clipSoundWindows,
                                 fadeOut: min(AssemblySettings.musicFadeOutSeconds, timeline.total / 3)).apply(to: input)
            parameters.append(input)
        }
        mix.inputParameters = parameters

        try? FileManager.default.removeItem(at: output)
        let hasAudio = !parameters.isEmpty
        if hasAudio {
            let soundFile = scratch.appending(path: "sound.m4a")
            try await mixDown(sound, mix: mix, duration: total, to: soundFile)
            try await VideoUpscaleRunner.mux(video: pictureFile, audioFrom: soundFile, to: output)
        } else {
            try FileManager.default.moveItem(at: pictureFile, to: output)
        }
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: output) } }
        try Task.checkCancellation()
        let probe = try await VideoProbe.inspect(output)
        guard probe.width == width, probe.height == height, abs(probe.duration - timeline.total) <= 1.5 / Double(settings.fps) + 0.05 else {
            throw StudioError.validation("Stitch validation failed: expected \(width)×\(height) over \(timeline.total) s; decoded \(probe.width)×\(probe.height) over \(probe.duration) s.")
        }
        guard probe.hasAudio == hasAudio else { throw StudioError.validation("Stitch audio does not match the selected policy.") }
        succeeded = true
        return .init(probe: probe, clips: reports, width: width, height: height, fps: settings.fps, hasAudioTrack: hasAudio)
    }

    /// A clip's sound level over the stitch: up to `level`, crossfaded at a dissolve, silent through the
    /// middle of a dip to black, and faded at the very start or end when the stitch fades from or to black.
    static func clipEnvelope(start: Double, end: Double, level: Double, into: (AssemblyTransition, Double)?, out: (AssemblyTransition, Double)?,
                             fadeIn: Double, fadeOut: Double) -> [(time: Double, volume: Double)] {
        var points: [(time: Double, volume: Double)] = []
        if let (kind, overlap) = into, overlap > 0 {
            points += kind == .dipToBlack ? [(start, 0), (start + overlap / 2, 0), (start + overlap, level)] : [(start, 0), (start + overlap, level)]
        } else if fadeIn > 0 {
            points += [(start, 0), (start + fadeIn, level)]
        } else {
            points.append((start, level))
        }
        if let (kind, overlap) = out, overlap > 0 {
            points += kind == .dipToBlack ? [(end - overlap, level), (end - overlap / 2, 0), (end, 0)] : [(end - overlap, level), (end, 0)]
        } else if fadeOut > 0 {
            points += [(end - fadeOut, level), (end, 0)]
        } else {
            points.append((end, level))
        }
        return points
    }

    /// Renders every audio track of `composition` through `mix` into one 48 kHz stereo AAC file.
    static func mixDown(_ composition: AVComposition, mix: AVAudioMix, duration: CMTime, to url: URL) async throws {
        let tracks = try await composition.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = CMTimeRange(start: .zero, duration: duration)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        guard reader.canAdd(output) else { throw StudioError.validation("Could not read the assembly sound.") }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw StudioError.validation("Could not write the assembly sound.") }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw StudioError.validation("Could not mix the assembly sound: \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { reader.cancelReading(); writer.cancelWriting() } }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw StudioError.validation("Mixing the assembly sound failed: \(writer.error?.localizedDescription ?? "writer stopped")") }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.append(buffer) else { throw StudioError.validation("Mixing the assembly sound failed: \(writer.error?.localizedDescription ?? "append rejected")") }
        }
        guard reader.status == .completed else { throw StudioError.validation("Reading the assembly sound failed: \(reader.error?.localizedDescription ?? "incomplete")") }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw StudioError.validation("Mixing the assembly sound did not complete: \(writer.error?.localizedDescription ?? "unknown error")") }
        finished = true
    }
}
