@preconcurrency import AppKit
import SwiftUI

/// AppKit supplies right-click coordinates and a native menu; SwiftUI owns insertion state.
struct CanvasContextMenu: NSViewRepresentable {
    let makeMenu: (CGPoint) -> NSMenu
    let deleteSelectedNode: () -> Bool
    /// Evaluated at click time so viewport motion never invalidates the overlay.
    var excludedRects: () -> [CGRect] = { [] }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasMenuView {
        let view = CanvasMenuView()
        view.makeMenu = makeMenu
        view.excludedRects = excludedRects
        context.coordinator.attach(to: view)
        context.coordinator.deleteSelectedNode = deleteSelectedNode
        return view
    }
    func updateNSView(_ view: CanvasMenuView, context: Context) {
        view.makeMenu = makeMenu
        view.excludedRects = excludedRects
        context.coordinator.deleteSelectedNode = deleteSelectedNode
    }

    final class Coordinator {
        weak var view: CanvasMenuView?
        var deleteSelectedNode: (() -> Bool)?
        private var keyMonitor: Any?

        func attach(to view: CanvasMenuView) {
            self.view = view
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let view = self.view,
                      view.owningWindowNumber == event.windowNumber,
                      event.keyCode == 51 || event.keyCode == 117,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      self.deleteSelectedNode?() == true else { return event }
                return nil
            }
        }

        deinit {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
    }
}

final class CanvasMenuView: NSView {
    var makeMenu: ((CGPoint) -> NSMenu)?
    var excludedRects: () -> [CGRect] = { [] }
    nonisolated(unsafe) var owningWindowNumber = -1
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owningWindowNumber = window?.windowNumber ?? -1
    }
    // Native hit-test traversal bounds this to the actual canvas hierarchy. No window-wide monitor.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .rightMouseDown,
              bounds.contains(convert(point, from: superview)) else { return nil }
        let localPoint = convert(point, from: superview)
        guard !excludedRects().contains(where: { $0.contains(localPoint) }) else { return nil }
        return self
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?(convert(event.locationInWindow, from: nil))
    }
}

final class CanvasMenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Canvas menu items are created programmatically") }
    @objc private func invoke() { handler() }
}
