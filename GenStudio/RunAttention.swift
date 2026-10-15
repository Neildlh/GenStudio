import AppKit
import Foundation
import UserNotifications

/// Keeps the Mac from idling to sleep while local generation runs or waits in the queue. The display may
/// still sleep, which also keeps MLX clear of the macOS GPU watchdog during long unattended batches.
@MainActor
final class RunWakeGuard {
    private var activity: NSObjectProtocol?
    var isHolding: Bool { activity != nil }

    func hold(reason: String) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
    }

    func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

/// What ran between the queue starting and emptying, for the "finished" notification.
struct RunBatchRecord: Sendable {
    enum Outcome: Sendable { case succeeded, failed, cancelled }
    let startedAt: Date
    private(set) var labels: [String] = []
    private(set) var succeeded = 0, failed = 0, cancelled = 0

    init(startedAt: Date) { self.startedAt = startedAt }

    mutating func record(label: String, outcome: Outcome) {
        labels.append(label)
        switch outcome {
        case .succeeded: succeeded += 1
        case .failed: failed += 1
        case .cancelled: cancelled += 1
        }
    }

    /// A notification is worth it only for work over a minute that finished while GenStudio was in the background.
    static func shouldNotify(elapsed: TimeInterval, appActive: Bool) -> Bool { elapsed >= 60 && !appActive }

    func notice(finishedAt: Date) -> (title: String, body: String) {
        let after = Self.duration(finishedAt.timeIntervalSince(startedAt))
        let total = succeeded + failed + cancelled
        if total == 1, let label = labels.first {
            switch (succeeded, failed) {
            case (1, _): return ("\(label) is ready", "Finished after \(after).")
            case (_, 1): return ("\(label) failed", "Stopped after \(after). Open GenStudio to see why.")
            default: return ("\(label) was cancelled", "Stopped after \(after).")
            }
        }
        var parts = ["\(succeeded) done"]
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return ("\(total) runs finished", parts.joined(separator: ", ") + ", after \(after).")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Posts the finished notice through Notification Centre, asking permission the first time it is needed.
enum RunFinishNotifier {
    static func post(title: String, body: String) {
        // Tests host the app; never prompt for notification permission from a test run.
        guard NSClassFromString("XCTestCase") == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            // Fetched here rather than captured: the centre is not Sendable, and `current()` is the same shared instance.
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
