import AVFoundation
import AppKit
import SwiftUI

/// The facts about a connected clip the Stitcher inspector needs before a run: its length, frame rate and a frame to show.
struct StitchClipFacts: Equatable, Sendable {
    let duration: Double
    let frameRate: Double

    static func load(_ url: URL) async -> StitchClipFacts? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let loaded = try? await track.load(.timeRange, .nominalFrameRate),
              loaded.0.duration.seconds.isFinite, loaded.0.duration.seconds > 0 else { return nil }
        return .init(duration: loaded.0.duration.seconds, frameRate: Double(loaded.1))
    }

    /// One frame of `url` at `seconds`, small enough for an inspector row.
    static func frame(_ url: URL, at seconds: Double) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let image = try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// Running time of a stitch from the clips it will receive, mirroring the render's own timeline.
enum StitchPlan {
    /// Seconds each slot plays after its trims, or nil while a clip has not been made yet or is trimmed to nothing.
    static func played(_ facts: [StitchClipFacts?], edits: [StitchClipEdit], skipRepeatedJoinFrame: Bool) -> [Double?] {
        zip(facts, edits).enumerated().map { index, pair in
            guard let facts = pair.0 else { return nil }
            let skip = skipRepeatedJoinFrame && index > 0 && facts.frameRate > 0 ? 1 / facts.frameRate : 0
            return try? pair.1.window(duration: facts.duration, skipLeadingSeconds: skip, clipName: "").length
        }
    }

    static func runningTime(_ played: [Double?], joins: [AssemblyTransition], seconds: Double) -> Double? {
        let known = played.compactMap { $0 }
        guard !known.isEmpty, known.count == played.count else { return nil }
        return AssemblyTimeline(durations: known, joins: joins, seconds: seconds).total
    }
}

private extension ClosedRange<Double> { var length: Double { upperBound - lowerBound } }

struct StitcherInspector: View {
    @ObservedObject var model: StudioModel
    let node: StudioNode
    @State private var facts: [URL: StitchClipFacts] = [:]
    @State private var expanded: Set<String> = []

    private var current: StudioNode { model.currentProject?.nodes.first { $0.id == node.id } ?? node }
    private var edges: [StudioEdge] { model.currentProject?.edges.filter { $0.targetID == node.id } ?? [] }
    private var connectedPorts: Set<String> { Set(edges.map(\.targetPortID)) }

    private func setting<T>(_ keyPath: WritableKeyPath<StudioNode, T>) -> Binding<T> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in model.updateNodeFromBinding(node.id) { $0[keyPath: keyPath] = value } })
    }

    private func edit<T>(_ slot: DynamicInputPort, _ keyPath: WritableKeyPath<StitchClipEdit, T>) -> Binding<T> {
        Binding(get: { current.assembly.edit(for: slot.id)[keyPath: keyPath] },
                set: { value in model.updateClipEdit(nodeID: node.id, portID: slot.id) { $0[keyPath: keyPath] = value } })
    }

    /// The node feeding a slot and the clip it last made, if any.
    private func source(_ slot: DynamicInputPort) -> (node: StudioNode, clip: URL?)? {
        guard let edge = edges.first(where: { $0.targetPortID == slot.id }),
              let source = model.currentProject?.nodes.first(where: { $0.id == edge.sourceID }) else { return nil }
        let value = source.outputPorts.first?.id == edge.sourcePortID
            ? model.displayedValue(for: source)
            : model.latestValue(at: .init(nodeID: source.id, portID: edge.sourcePortID), inProject: model.currentProjectID)
        if case .video(let url) = value { return (source, url) }
        return (source, nil)
    }

    var body: some View {
        let settings = current.assembly
        let slots = current.dynamicInputs
        let sources = slots.map(source)
        let clipFacts = sources.map { $0?.clip.flatMap { facts[$0] } }
        let played = StitchPlan.played(clipFacts, edits: slots.map { settings.edit(for: $0.id) }, skipRepeatedJoinFrame: settings.skipRepeatedJoinFrame)
        let joins = settings.joins(slots.map(\.id))

        if let issue = VideoPreflight.assemblyIssue(current, connectedPorts: connectedPorts) {
            Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        summary(slots: slots.count, connected: sources.compactMap { $0 }.count, running: StitchPlan.runningTime(played, joins: joins, seconds: settings.transitionSeconds))
            .task(id: sources.compactMap { $0?.clip }) { await loadFacts(sources.compactMap { $0?.clip }) }

        HStack {
            Button("Add Slot") { model.addDynamicInput(to: node.id) }.disabled(slots.count >= AssemblySettings.maximumClips)
            Button("Order by Canvas") { model.orderClipsByCanvasPosition(nodeID: node.id) }
                .help("Put clips in the order their nodes sit on the canvas: left to right, and top to bottom within a column.")
                .disabled(connectedPorts.count < 2)
            Button("Remove Empty") { model.removeEmptyClipSlots(nodeID: node.id) }
                .disabled(!slots.contains { !connectedPorts.contains($0.id) } || connectedPorts.isEmpty)
        }.controlSize(.small)

        ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
            clipRow(slot, index: index, count: slots.count, source: sources[index], played: played[index], settings: settings)
        }

        Text("Joins").font(.headline).padding(.top, 6)
        Picker("Between clips", selection: setting(\.assembly.transition)) { ForEach(AssemblyTransition.allCases, id: \.self) { Text($0.title).tag($0) } }
        if settings.transition.overlaps || joins.contains(where: \.overlaps) {
            Stepper("Dissolve or dip: \(settings.transitionSeconds.formatted(.number.precision(.fractionLength(1)))) s", value: setting(\.assembly.transitionSeconds), in: 0.2...1.5, step: 0.1)
        }
        Toggle("Skip the repeated frame at each join", isOn: setting(\.assembly.skipRepeatedJoinFrame))
        Text("Turn on when each shot was made from the previous clip's last frame (Start/End Video chains). That frame then appears twice at the join and reads as a stutter.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Fade in from black", isOn: setting(\.assembly.fadeIn))
        Toggle("Fade out to black", isOn: setting(\.assembly.fadeOut))

        Text("Picture").font(.headline).padding(.top, 6)
        Picker("Mixed shapes", selection: setting(\.assembly.framing)) { ForEach(AssemblyFraming.allCases, id: \.self) { Text($0.title).tag($0) } }
        Stepper("Frame rate: \(settings.fps) fps", value: setting(\.assembly.fps), in: 1...60)
        Stepper("Width: \(settings.width == 0 ? "match first clip" : "\(settings.width) px")", value: setting(\.assembly.width), in: 0...4096, step: 2)
        Stepper("Height: \(settings.height == 0 ? "match first clip" : "\(settings.height) px")", value: setting(\.assembly.height), in: 0...4096, step: 2)

        Text("Sound").font(.headline).padding(.top, 6)
        Picker("Clip sound", selection: setting(\.assembly.audio)) { ForEach(AssemblyAudioPolicy.allCases, id: \.self) { Text($0.title).tag($0) } }
        LabeledContent("Music") {
            HStack {
                Text(settings.musicPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None").lineLimit(1).truncationMode(.middle)
                Button(settings.musicPath == nil ? "Choose…" : "Change…") { model.chooseAssemblyMusic(nodeID: node.id) }
                if settings.musicPath != nil { Button("Remove") { model.updateNode(node.id) { $0.assembly.musicPath = nil } } }
            }
        }
        if settings.musicPath != nil {
            LabeledContent("Music level") { Slider(value: setting(\.assembly.musicVolume), in: 0.05...1) }
            Toggle("Lower music under clip sound", isOn: setting(\.assembly.duckMusic))
            Text("The music loops to fill the video and fades out over the last \(AssemblySettings.musicFadeOutSeconds.formatted()) s. Use music you have the rights to.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("Clips play in slot order. Connect a clip to the Stitcher and a new slot appears for it. Dissolves and dips overlap neighbouring clips, so the video gets slightly shorter.")
            .font(.caption).foregroundStyle(.secondary)
        lastOutput
    }

    @ViewBuilder private func summary(slots: Int, connected: Int, running: Double?) -> some View {
        let clips = "\(connected) of \(slots) slot\(slots == 1 ? "" : "s") connected"
        if let running {
            Label("\(clips) · runs \(Self.seconds(running))", systemImage: "film.stack").font(.callout)
        } else {
            Label(clips, systemImage: "film.stack").font(.callout)
            if connected > 0 { Text("The running time shows once every connected clip has been made.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func clipRow(_ slot: DynamicInputPort, index: Int, count: Int, source: (node: StudioNode, clip: URL?)?, played: Double?, settings: AssemblySettings) -> some View {
        let clipEdit = settings.edit(for: slot.id)
        let isOpen = expanded.contains(slot.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StitchClipThumbnail(url: source?.clip, seconds: clipEdit.trimStart).frame(width: 64, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(index + 1). \(source?.node.label ?? slot.label)").lineLimit(1).truncationMode(.middle)
                    Text(detail(source: source, played: played, edit: clipEdit, index: index, settings: settings))
                        .font(.caption).foregroundStyle(source == nil ? .orange : .secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { toggle(slot.id) } label: { Image(systemName: isOpen ? "slider.horizontal.below.square.filled.and.square" : "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("Trim, level and transition").accessibilityLabel("Edit \(slot.label)")
                Button { model.moveClip(nodeID: node.id, portID: slot.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0).accessibilityLabel("Move \(slot.label) earlier")
                Button { model.moveClip(nodeID: node.id, portID: slot.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == count - 1).accessibilityLabel("Move \(slot.label) later")
                Button { model.removeDynamicInput(nodeID: node.id, portID: slot.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).disabled(count == 1).accessibilityLabel("Remove \(slot.label)")
            }
            if isOpen {
                Stepper("Trim start: \(Self.seconds(clipEdit.trimStart))", value: edit(slot, \.trimStart), in: 0...60, step: 0.1)
                Stepper("Trim end: \(Self.seconds(clipEdit.trimEnd))", value: edit(slot, \.trimEnd), in: 0...60, step: 0.1)
                LabeledContent("Sound level") {
                    HStack {
                        Slider(value: edit(slot, \.volume), in: 0...1)
                        Text(clipEdit.volume == 0 ? "Muted" : "\(Int((clipEdit.volume * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                    }
                }.disabled(settings.audio == .silent)
                if index > 0 {
                    Picker("Into this clip", selection: edit(slot, \.transitionIn)) {
                        Text("Default (\(settings.transition.title))").tag(AssemblyTransition?.none)
                        ForEach(AssemblyTransition.allCases, id: \.self) { Text($0.title).tag(AssemblyTransition?.some($0)) }
                    }
                }
                if !clipEdit.isDefault {
                    Button("Reset This Clip") { model.updateClipEdit(nodeID: node.id, portID: slot.id) { $0 = .init() } }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(source: (node: StudioNode, clip: URL?)?, played: Double?, edit: StitchClipEdit, index: Int, settings: AssemblySettings) -> String {
        guard let source else { return "Empty — connect a clip" }
        var parts: [String] = []
        if let clip = source.clip, let facts = facts[clip] {
            if let played {
                parts.append(edit.trimStart > 0 || edit.trimEnd > 0 ? "\(Self.seconds(facts.duration)) → plays \(Self.seconds(played))" : Self.seconds(facts.duration))
            } else {
                parts.append("trimmed to nothing")
            }
        } else if source.clip == nil {
            parts.append("not made yet")
        }
        if settings.audio == .preserve, edit.volume < 1 { parts.append(edit.volume == 0 ? "muted" : "sound \(Int((edit.volume * 100).rounded()))%") }
        if index > 0, let transition = edit.transitionIn { parts.append("\(transition.title.lowercased()) in") }
        return parts.joined(separator: " · ")
    }

    private func toggle(_ id: String) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }

    private func loadFacts(_ clips: [URL]) async {
        for clip in Set(clips) where facts[clip] == nil {
            guard let loaded = await StitchClipFacts.load(clip) else { continue }
            try? Task.checkCancellation()
            facts[clip] = loaded
        }
    }

    @ViewBuilder private var lastOutput: some View {
        if let record = model.executionArtifacts.first(where: { $0.graphSnapshot.id == model.currentProjectID && $0.mediaProvenance?[node.id] != nil })?.mediaProvenance?[node.id] {
            Text("Last stitch: \(record.width)×\(record.height), \(record.frameCount) frames at \(record.fps) fps, \(Self.seconds(record.duration))\(record.hasAudioTrack ? ", with sound" : ", no sound").")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func seconds(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1)))) s" }
}

/// The first frame a clip plays in the stitch, or a placeholder until the clip exists.
private struct StitchClipThumbnail: View {
    let url: URL?
    let seconds: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: url == nil ? "film.badge.plus" : "film").foregroundStyle(.secondary) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: "\(url?.path ?? "")@\(seconds)") {
            guard let url else { image = nil; return }
            // Let a run of stepper clicks settle before decoding.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            image = await StitchClipFacts.frame(url, at: seconds)
        }
        .accessibilityHidden(true)
    }
}
