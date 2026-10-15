import XCTest
import SwiftUI
import AppKit
@testable import GenStudio

/// Measures how much main-thread time one viewport change costs on a busy
/// stage. Navigation cost used to grow with node count because every pan or
/// zoom sample rebuilt every node card.
@MainActor
final class CanvasNavigationPerformanceTests: XCTestCase {
    private struct StageHost: View {
        @ObservedObject var model: StudioModel
        let viewportState: CanvasViewportState
        var body: some View {
            if let project = model.currentProject { CanvasView(model: model, project: project, viewportState: viewportState) }
        }
    }

    static func busyProject(nodeCount: Int) -> WorkflowProject {
        let kinds: [NodeKind] = [.prompt, .imagePrompt, .imageGenerator, .imagePreview, .textModel, .textPreview]
        var nodes: [StudioNode] = []
        for index in 0..<nodeCount {
            let column = index % 10, row = index / 10
            nodes.append(StudioNode(kind: kinds[index % kinds.count], label: "Node \(index)", position: .init(x: Double(column) * 460, y: Double(row) * 560)))
        }
        var edges: [StudioEdge] = []
        for index in 1..<nodes.count {
            let source = nodes[index - 1], target = nodes[index]
            guard let output = source.outputPorts.first,
                  let input = target.inputPorts.first(where: { $0.type == output.type }) else { continue }
            edges.append(StudioEdge(sourceID: source.id, sourcePortID: output.id, targetID: target.id, targetPortID: input.id, type: output.type))
        }
        return WorkflowProject(name: "Busy stage", nodes: nodes, edges: edges)
    }

    private func makeStage(nodeCount: Int) throws -> (StudioModel, CanvasViewportState, NSWindow) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: nil)
        let project = Self.busyProject(nodeCount: nodeCount)
        model.projects = [project]
        model.currentProjectID = project.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let viewportState = CanvasViewportState()
        window.contentView = NSHostingView(rootView: StageHost(model: model, viewportState: viewportState))
        window.orderFront(nil)
        settle(window)
        return (model, viewportState, window)
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func testCommittedViewportChangeCost() throws {
        for count in [10, 40, 90] {
            let (model, _, window) = try makeStage(nodeCount: count)
            defer { window.orderOut(nil) }
            let steps = 60
            let start = CFAbsoluteTimeGetCurrent()
            for step in 0..<steps {
                model.mutateProject { $0.viewport.offset = .init(x: Double(step) * 9, y: Double(step) * 5) }
                settle(window)
            }
            let perStep = (CFAbsoluteTimeGetCurrent() - start) / Double(steps) * 1000
            print("PERF committed-viewport nodes=\(count) ms/step=\(String(format: "%.2f", perStep))")
        }
    }

    private func measureTransient(_ label: String, zooming: Bool) throws {
        for count in [10, 40, 90] {
            let (_, viewportState, window) = try makeStage(nodeCount: count)
            defer { window.orderOut(nil) }
            let steps = 60
            let start = CFAbsoluteTimeGetCurrent()
            for step in 0..<steps {
                viewportState.transient = .init(offset: .init(x: Double(step) * 9, y: Double(step) * 5), zoom: zooming ? 1 + Double(step) * 0.01 : 1)
                settle(window)
            }
            let perStep = (CFAbsoluteTimeGetCurrent() - start) / Double(steps) * 1000
            print("PERF \(label) nodes=\(count) ms/step=\(String(format: "%.2f", perStep))")
        }
    }

    /// The path a live trackpad pan takes: transient viewport only.
    func testTransientPanCost() throws { try measureTransient("transient-pan", zooming: false) }
    func testTransientZoomCost() throws { try measureTransient("transient-zoom", zooming: true) }
}
