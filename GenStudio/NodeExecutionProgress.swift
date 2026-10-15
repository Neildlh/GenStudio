import Foundation
import SwiftUI

struct EngineProgress: Sendable {
    let stage: String
    /// Only supply a fraction backed by a measured engine stage, never elapsed-time estimates.
    var fraction: Double? = nil
}

enum GenerationProgressContext {
    @TaskLocal static var report: (@Sendable (EngineProgress) -> Void)?
}

/// Lets an engine hand its own process time and log tail back to the run record without changing the engine
/// protocol: image runs vary a lot run to run, and this separates engine time from setup and file checks.
enum EngineRunLog {
    @TaskLocal static var record: (@Sendable (_ engineSeconds: Double, _ logTail: String) -> Void)?

    static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious (throttling)"
        case .critical: "critical (throttling)"
        @unknown default: "unknown"
        }
    }
}

/// Collects what an engine reported through `EngineRunLog` during one run.
final class EngineRunLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (seconds: Double, tail: String)?
    var recorded: (seconds: Double, tail: String)? { lock.withLock { value } }
    func store(_ seconds: Double, _ tail: String) { lock.withLock { value = (seconds, tail) } }
}

enum NodeExecutionEvent: Sendable {
    case started(UUID)
    case progress(UUID, EngineProgress)
    case completed(UUID)
    /// The node's existing output was consumed; it did no work in this run.
    case skipped(UUID)
}

struct NodeExecutionProgress: Sendable {
    enum Status: String, Sendable { case queued, running, completed, failed, cancelled, blocked }
    var status: Status = .queued
    var stage = "Queued"
    var fraction: Double?
    var queuedAt = Date()
    var finishedAt: Date?
    var active: Bool { status == .queued || status == .running }
    func elapsed(at date: Date) -> TimeInterval { max(0, (finishedAt ?? date).timeIntervalSince(queuedAt)) }
}

struct WorkflowProgress: Sendable {
    let runID: UUID
    let project: WorkflowProject
    let target: UUID
    var nodes: [UUID: NodeExecutionProgress]

    init(runID: UUID, project: WorkflowProject, target: UUID) {
        self.runID = runID; self.project = project; self.target = target
        nodes = Dictionary(uniqueKeysWithValues: Self.ancestors(of: target, project: project).map { ($0, NodeExecutionProgress()) })
    }
    static func ancestors(of target: UUID, project: WorkflowProject) -> Set<UUID> {
        var ids: Set<UUID> = [target], pending = [target]
        while let id = pending.popLast() {
            for edge in project.edges where edge.targetID == id {
                if ids.insert(edge.sourceID).inserted { pending.append(edge.sourceID) }
            }
        }
        return ids
    }
    mutating func receive(_ event: NodeExecutionEvent) {
        switch event {
        case .started(let id):
            guard nodes[id]?.status == .queued else { return }
            nodes[id]?.status = .running; nodes[id]?.stage = "Processing"
        case .progress(let id, let update):
            guard nodes[id]?.status == .running else { return }
            nodes[id]?.stage = update.stage
            nodes[id]?.fraction = update.fraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        case .completed(let id):
            guard nodes[id]?.status == .running else { return }
            nodes[id]?.status = .completed; nodes[id]?.stage = "Done"; nodes[id]?.fraction = nil; nodes[id]?.finishedAt = Date()
        case .skipped(let id):
            nodes[id] = nil
        }
    }
    mutating func finish(error: Error?) {
        for id in Array(nodes.keys) where nodes[id]?.active == true {
            let cancelled = error is CancellationError
            nodes[id]?.status = cancelled ? .cancelled : .blocked
            nodes[id]?.stage = cancelled ? "Cancelled" : "Blocked · run failed"
            nodes[id]?.fraction = nil; nodes[id]?.finishedAt = Date()
        }
    }
    mutating func failActive(error: Error) {
        for id in Array(nodes.keys) where nodes[id]?.status == .running {
            nodes[id]?.status = error is CancellationError ? .cancelled : .failed
            nodes[id]?.stage = error is CancellationError ? "Cancelled" : "Failed"
            nodes[id]?.fraction = nil; nodes[id]?.finishedAt = Date()
        }
        finish(error: error)
    }
    func display(for node: StudioNode) -> NodeExecutionProgress? {
        guard var own = nodes[node.id] else { return nil }
        if own.status == .queued {
            let ancestors = Self.ancestors(of: node.id, project: project)
            if let upstream = project.nodes.first(where: { ancestors.contains($0.id) && nodes[$0.id]?.status == .running }), let progress = nodes[upstream.id] {
                own.stage = "\(upstream.label): \(progress.stage)"
                own.fraction = progress.fraction
            } else { own.stage = "Waiting for inputs" }
        }
        return own
    }
}

struct NodeProgressBar: View {
    let progress: NodeExecutionProgress
    /// A finished run over its own result: a small corner pill instead of a full-width bar.
    var compact = false
    var body: some View {
        if progress.active {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in content(at: timeline.date) }
        } else if compact {
            pill
        } else { content(at: progress.finishedAt ?? .now) }
    }
    private var pill: some View {
        HStack(spacing: 4) {
            Image(systemName: progress.status == .completed ? "checkmark.circle.fill" : "circle.fill")
                .foregroundStyle(progress.status == .completed ? Color.green : Color.secondary)
            Text(progress.stage).lineLimit(1)
            Text(Duration.seconds(progress.elapsed(at: progress.finishedAt ?? .now)).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: CanvasType.micro, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }
    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(progress.stage).lineLimit(1)
                Spacer(minLength: 3)
                Text(Duration.seconds(progress.elapsed(at: date)).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
            }.font(.system(size: CanvasType.micro))
            if progress.active {
                StudioLinearProgress(value: progress.fraction)
            } else {
                Capsule().fill(progress.status == .completed ? Color.green : Color.secondary).frame(height: 3)
            }
        }.padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius))
            .accessibilityElement(children: .combine)
    }
}
