import AVFoundation
import XCTest
@testable import GenStudio

/// The Stitcher: many generated clips into one video, with per-clip trims, a transition per join, fit or fill
/// framing, per-clip sound level, and a fix for the repeated frame at frame-chained joins.
final class StitcherPlanTests: XCTestCase {
    func testEachJoinKeepsItsOwnTransition() {
        let timeline = AssemblyTimeline(durations: [4, 4, 4], joins: [.cut, .dissolve], seconds: 1)
        XCTAssertEqual(timeline.overlaps, [0, 1])
        XCTAssertEqual(timeline.starts, [0, 4, 7])
        XCTAssertEqual(timeline.total, 11, accuracy: 0.0001)
        XCTAssertEqual(AssemblyTimeline(durations: [4, 4], joins: [.dipToBlack], seconds: 0.5).total, 7.5, accuracy: 0.0001, "A dip overlaps like a dissolve")
    }

    func testAJoinNeverEatsMoreThanEitherNeighbourCanGive() {
        let timeline = AssemblyTimeline(durations: [4, 1, 4], joins: [.dissolve, .dipToBlack], seconds: 2)
        XCTAssertEqual(timeline.overlaps, [0.45, 0.45])
        XCTAssertLessThanOrEqual(timeline.overlapIn(1) + timeline.overlapOut(1), 1, "The middle clip keeps a moment of its own")
    }

    func testTrimsLeaveThePlayedWindowAndRejectTrimmingToNothing() throws {
        let edit = StitchClipEdit(trimStart: 0.5, trimEnd: 1)
        let window = try edit.window(duration: 5, skipLeadingSeconds: 0.04, clipName: "Clip 2")
        XCTAssertEqual(window.lowerBound, 0.54, accuracy: 0.0001)
        XCTAssertEqual(window.upperBound, 4, accuracy: 0.0001)
        XCTAssertThrowsError(try StitchClipEdit(trimStart: 3, trimEnd: 2).window(duration: 5, clipName: "Clip 2")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Clip 2"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Shorten the trims"), error.localizedDescription)
        }
    }

    func testPerClipTransitionsLevelsAndOlderSettings() throws {
        let saved = try JSONDecoder().decode(AssemblySettings.self, from: Data(#"{"width":0,"height":0,"fps":24,"audio":"preserve","transition":"dissolve"}"#.utf8))
        XCTAssertEqual(saved.framing, .fit); XCTAssertFalse(saved.skipRepeatedJoinFrame); XCTAssertTrue(saved.clipEdits.isEmpty)

        var settings = AssemblySettings()
        settings.clipEdits["b"] = .init(volume: 0.5, transitionIn: .dipToBlack)
        XCTAssertEqual(settings.joins(["a", "b", "c"]), [.dipToBlack, .cut], "An override applies to its own join; others use the default")
        XCTAssertFalse(settings.needsMixdown(edits: [.init(), .init()], joins: [.cut]))
        XCTAssertTrue(settings.needsMixdown(edits: [.init()], joins: [.dipToBlack]))
        XCTAssertTrue(settings.needsMixdown(edits: [.init(volume: 0.5)], joins: []), "A clip level needs the mixed sound path")
        settings.audio = .silent
        XCTAssertFalse(settings.needsMixdown(edits: [.init(volume: 0.5)], joins: []), "Levels do nothing when clip sound is muted")

        let roundTrip = try JSONDecoder().decode(AssemblySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip, settings)
        XCTAssertEqual(settings.pruned(to: ["a"]).clipEdits, [:], "Edits of removed slots are not recorded")
    }

    func testRunningTimeMatchesTheRenderTimeline() {
        let facts: [StitchClipFacts?] = [.init(duration: 5, frameRate: 25), .init(duration: 5, frameRate: 25)]
        let played = StitchPlan.played(facts, edits: [.init(trimEnd: 1), .init(trimStart: 0.5)], skipRepeatedJoinFrame: true)
        XCTAssertEqual(played[0]!, 4, accuracy: 0.0001)
        XCTAssertEqual(played[1]!, 4.46, accuracy: 0.0001, "Trim plus one skipped 25 fps frame")
        XCTAssertEqual(StitchPlan.runningTime(played, joins: [.dissolve], seconds: 0.5)!, 7.96, accuracy: 0.0001)
        XCTAssertNil(StitchPlan.runningTime([played[0], nil], joins: [.cut], seconds: 0.5), "Unknown until every clip exists")
    }

    func testDipSoundIsSilentAtTheMiddleOfTheJoin() {
        let outgoing = VolumeEnvelope(points: ClipAssembler.clipEnvelope(start: 0, end: 4, level: 0.8, into: nil, out: (.dipToBlack, 1), fadeIn: 0, fadeOut: 0))
        XCTAssertEqual(outgoing.volume(at: 2), 0.8, accuracy: 0.001)
        XCTAssertEqual(outgoing.volume(at: 3.5), 0, accuracy: 0.001)
        let incoming = VolumeEnvelope(points: ClipAssembler.clipEnvelope(start: 3, end: 7, level: 1, into: (.dipToBlack, 1), out: nil, fadeIn: 0, fadeOut: 0))
        XCTAssertEqual(incoming.volume(at: 3.4), 0, accuracy: 0.001)
        XCTAssertEqual(incoming.volume(at: 5), 1, accuracy: 0.001)
    }
}

final class StitcherEditingTests: XCTestCase {
    private func project() -> (WorkflowProject, UUID, [DynamicInputPort]) {
        var stitcher = StudioNode(kind: .assembleVideo, label: "Stitcher", position: .init(x: 900, y: 0))
        stitcher.dynamicInputs = (1...4).map { DynamicInputPort(label: "Clip \($0)", type: .video) }
        let slots = stitcher.dynamicInputs
        // Two columns: A above B at x 0, C at x 400. Slot 4 stays empty.
        let a = StudioNode(kind: .videoInput, label: "A", position: .init(x: 0, y: 0))
        let b = StudioNode(kind: .videoInput, label: "B", position: .init(x: 40, y: 300))
        let c = StudioNode(kind: .videoInput, label: "C", position: .init(x: 400, y: -200))
        let edges = [VideoFixtures.edge(c, "video", stitcher, slots[0].id, .video), VideoFixtures.edge(b, "video", stitcher, slots[1].id, .video),
                     VideoFixtures.edge(a, "video", stitcher, slots[2].id, .video)]
        return (WorkflowProject(name: "Stitch", nodes: [a, b, c, stitcher], edges: edges), stitcher.id, slots)
    }

    func testOrderByCanvasReadsColumnsLeftToRightThenTopToBottom() {
        var (project, id, slots) = project()
        SequenceEditing.orderClipsByCanvasPosition(&project, nodeID: id)
        XCTAssertEqual(project.nodes.first { $0.id == id }!.dynamicInputs.map(\.id), [slots[2].id, slots[1].id, slots[0].id, slots[3].id],
                       "A then B (same column), then C; the empty slot last")
        XCTAssertEqual(project.edges.count, 3, "Reordering never rewires")
    }

    func testRemovingEmptySlotsDropsTheirEdits() {
        var (project, id, slots) = project()
        SequenceEditing.updateClipEdit(&project, nodeID: id, portID: slots[3].id) { $0.trimStart = 1 }
        SequenceEditing.updateClipEdit(&project, nodeID: id, portID: slots[0].id) { $0.trimEnd = 0.5 }
        SequenceEditing.removeEmptyClipSlots(&project, nodeID: id)
        let node = project.nodes.first { $0.id == id }!
        XCTAssertEqual(node.dynamicInputs.map(\.id), slots.prefix(3).map(\.id))
        XCTAssertEqual(Set(node.assembly.clipEdits.keys), [slots[0].id])
    }

    func testAnEditBackToDefaultsLeavesNoEntryAndValuesAreClamped() {
        var (project, id, slots) = project()
        SequenceEditing.updateClipEdit(&project, nodeID: id, portID: slots[0].id) { $0.volume = 3; $0.trimStart = -2 }
        XCTAssertEqual(project.nodes.first { $0.id == id }!.assembly.clipEdits[slots[0].id], nil, "Clamped back to 100% and 0 s, which is the default")
        SequenceEditing.updateClipEdit(&project, nodeID: id, portID: slots[0].id) { $0.volume = 0 }
        XCTAssertEqual(project.nodes.first { $0.id == id }!.assembly.clipEdits[slots[0].id]?.volume, 0)
    }
}

final class StitcherRenderTests: XCTestCase {
    /// A clip that is one colour for its first half and another for its second.
    private func twoTone(_ first: (Int, Int, Int), _ second: (Int, Int, Int), framesEach: Int, fps: Int, in root: URL, name: String) async throws -> URL {
        let a = try VideoFixtures.solidPNG(first, width: 160, height: 90, in: root, name: "\(name)-a")
        let b = try VideoFixtures.solidPNG(second, width: 160, height: 90, in: root, name: "\(name)-b")
        let url = root.appending(path: "\(name).mov")
        try await FrameSequenceEncoder.encode(frames: [.file(a), .file(b)], width: 160, height: 90, fps: fps, framesPerImage: [framesEach, framesEach], to: url)
        return url
    }

    private func colour(_ probe: VideoProbe, at time: Double) -> [Int] { probe.frames.min { abs($0.time - time) < abs($1.time - time) }!.centerRGB }

    func testTrimsCutTheHeadAndTailOfEachClip() async throws {
        let root = try VideoFixtures.root("stitch-trim"); defer { try? FileManager.default.removeItem(at: root) }
        // Each clip: 0.5 s of a "bad" colour, then 0.5 s of the shot we want.
        let first = try await twoTone((230, 20, 20), (20, 200, 20), framesEach: 5, fps: 10, in: root, name: "first")
        let second = try await twoTone((20, 20, 230), (230, 230, 20), framesEach: 5, fps: 10, in: root, name: "second")
        let settings = AssemblySettings(width: 160, height: 90, fps: 10, audio: .preserve)

        let result = try await ClipAssembler.assemble(clips: [.init(url: first, edit: .init(trimStart: 0.5)), .init(url: second, edit: .init(trimEnd: 0.5))],
                                                      settings: settings, to: root.appending(path: "stitch.mov"))

        XCTAssertEqual(result.probe.duration, 1, accuracy: 0.11, "0.5 s from each clip")
        XCTAssertTrue(VideoFixtures.close(colour(result.probe, at: 0), (20, 200, 20)), "Opens on the first clip's kept half: \(colour(result.probe, at: 0))")
        XCTAssertTrue(VideoFixtures.close(colour(result.probe, at: 0.75), (20, 20, 230)), "Ends on the second clip's kept half: \(colour(result.probe, at: 0.75))")
    }

    func testDipToBlackPassesThroughBlackBetweenShots() async throws {
        let root = try VideoFixtures.root("stitch-dip"); defer { try? FileManager.default.removeItem(at: root) }
        let red = try await VideoFixtures.colorClip((230, 20, 20), frames: 10, fps: 10, in: root, name: "red")
        let blue = try await VideoFixtures.colorClip((20, 20, 230), frames: 10, fps: 10, in: root, name: "blue")
        let settings = AssemblySettings(width: 160, height: 90, fps: 10, audio: .preserve)

        let result = try await ClipAssembler.assemble(clips: [.init(url: red), .init(url: blue, edit: .init(transitionIn: .dipToBlack))],
                                                      settings: settings, to: root.appending(path: "stitch.mov"))

        XCTAssertEqual(result.probe.duration, 1.55, accuracy: 0.11, "1 s + 1 s − 0.45 s of overlap (the 45% limit on a 1 s clip)")
        XCTAssertTrue(VideoFixtures.close(colour(result.probe, at: 0.2), (230, 20, 20)))
        XCTAssertTrue(colour(result.probe, at: 0.78).allSatisfy { $0 < 60 }, "Black at the middle of the dip: \(colour(result.probe, at: 0.78))")
        XCTAssertTrue(VideoFixtures.close(colour(result.probe, at: 1.4), (20, 20, 230)))
    }

    func testFillCropsWhereFitLetterboxes() async throws {
        let root = try VideoFixtures.root("stitch-fill"); defer { try? FileManager.default.removeItem(at: root) }
        let wide = try await VideoFixtures.colorClip((230, 20, 20), frames: 5, fps: 10, in: root, name: "wide")
        func topPixel(_ framing: AssemblyFraming) async throws -> [Int] {
            var settings = AssemblySettings(width: 90, height: 160, fps: 10, audio: .preserve)
            settings.framing = framing
            let output = root.appending(path: "\(framing.rawValue).mov")
            _ = try await ClipAssembler.assemble(clips: [.init(url: wide)], settings: settings, to: output)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            let image = try await generator.image(at: CMTime(value: 2, timescale: 10)).image
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // Draw so the pixel at (45, 8) from the top lands on the 1×1 context.
            context.draw(image, in: CGRect(x: -45, y: -(Double(image.height) - 8), width: Double(image.width), height: Double(image.height)))
            let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return [Int(data[0]), Int(data[1]), Int(data[2])]
        }
        let fit = try await topPixel(.fit), fill = try await topPixel(.fill)
        XCTAssertTrue(fit.allSatisfy { $0 < 40 }, "Fit leaves a bar above a wide clip in a tall frame: \(fit)")
        XCTAssertTrue(VideoFixtures.close(fill, (230, 20, 20)), "Fill covers the frame: \(fill)")
    }

    func testSkippingTheRepeatedJoinFrameDropsOneFramePerJoin() async throws {
        let root = try VideoFixtures.root("stitch-chain"); defer { try? FileManager.default.removeItem(at: root) }
        var clips: [URL] = []
        for (index, rgb) in [(230, 20, 20), (20, 200, 20), (20, 20, 230)].enumerated() {
            clips.append(try await VideoFixtures.colorClip(rgb, frames: 10, fps: 10, in: root, name: "c\(index)"))
        }
        var settings = AssemblySettings(width: 160, height: 90, fps: 10, audio: .preserve)
        let plain = try await ClipAssembler.assemble(clips, settings: settings, to: root.appending(path: "plain.mov"))
        settings.skipRepeatedJoinFrame = true
        let chained = try await ClipAssembler.assemble(clips, settings: settings, to: root.appending(path: "chained.mov"))
        XCTAssertEqual(plain.probe.duration - chained.probe.duration, 0.2, accuracy: 0.05, "Two joins, one 10 fps frame each")
        XCTAssertEqual(chained.clips.map(\.duration), [1, 0.9, 0.9].map { $0 }, accuracy: 0.01)
    }

    func testAMutedClipIsSilentWhileItsNeighbourKeepsItsSound() async throws {
        let root = try VideoFixtures.root("stitch-level"); defer { try? FileManager.default.removeItem(at: root) }
        let a = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((200, 30, 30), frames: 10, fps: 10, in: root, name: "a"), seconds: 1, in: root, name: "a-tone")
        let b = try await VideoFixtures.withTone(try await VideoFixtures.colorClip((30, 30, 200), frames: 10, fps: 10, in: root, name: "b"), seconds: 1, in: root, name: "b-tone")
        let output = root.appending(path: "stitch.mov")
        let result = try await ClipAssembler.assemble(clips: [.init(url: a), .init(url: b, edit: .init(volume: 0))],
                                                      settings: AssemblySettings(width: 160, height: 90, fps: 10, audio: .preserve), to: output)
        XCTAssertTrue(result.hasAudioTrack)
        let rms = try await StitcherAudio.rms(output)
        XCTAssertGreaterThan(rms(0.2, 0.8), 0.05, "The first clip keeps its sound")
        XCTAssertLessThan(rms(1.2, 1.8), 0.005, "The muted clip is silent")
    }
}

private enum StitcherAudio {
    /// Loudness of the output's sound between two times.
    static func rms(_ url: URL) async throws -> (Double, Double) -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                                                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0; var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            pointer?.withMemoryRebound(to: Float.self, capacity: length / 4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) }
        }
        let all = samples
        return { start, end in
            let a = max(0, Int(start * 48_000)), b = min(all.count, Int(end * 48_000))
            guard b > a else { return 0 }
            return sqrt(all[a..<b].reduce(0) { $0 + Double($1 * $1) } / Double(b - a))
        }
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, message, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, message, file: file, line: line) }
}
