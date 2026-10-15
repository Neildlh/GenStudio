import Foundation

/// One generation timed on the reference M1 Max through the app's own launcher, with the prompt
/// encoding already cached. Recorded on the capability so estimates come from this Mac, not guesses.
struct VideoSpeedAnchor: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let frames: Int
    let fastDraft: Bool
    let seconds: Double

    var workload: Double { Double(width) * Double(height) * Double(frames) }
}

/// "About how long will a take be?" from this Mac's measurements. Time grows faster than the pixel ×
/// frame count (attention cost), so two measured sizes give the growth rate between and beyond them;
/// with one measurement a conservative 1.4 power is used. Estimates are labelled as such in the UI,
/// and a route with no measurement here gets none.
enum VideoTimeEstimate {
    static let singleAnchorExponent = 1.4
    /// Estimates stay within this factor of a measured workload. Far below it, fixed model-load time dominates;
    /// far above it, memory pressure does. Outside the range the honest answer is "not measured".
    static let extrapolationLimit = 4.0

    static func seconds(_ settings: VideoGenerationSettings, capability: VideoCapability) -> Double? {
        let fast = capability.supportsFastDraft && settings.fastDraft == true
        let matching: [VideoSpeedAnchor] = capability.speedAnchors.filter { $0.fastDraft == fast }
        let anchors = matching.sorted { (a: VideoSpeedAnchor, b: VideoSpeedAnchor) in a.workload < b.workload }
        guard let first = anchors.first, settings.width > 0, settings.height > 0, settings.frameCount > 0 else { return nil }
        let workload = Double(settings.width) * Double(settings.height) * Double(settings.frameCount)
        guard let last = anchors.last, workload >= first.workload / extrapolationLimit, workload <= last.workload * extrapolationLimit else { return nil }
        guard anchors.count > 1 else { return first.seconds * pow(workload / first.workload, singleAnchorExponent) }
        let upper = anchors.firstIndex { $0.workload > workload }.map { max(1, $0) } ?? anchors.count - 1
        let low = anchors[upper - 1], high = anchors[upper]
        let exponent = log(high.seconds / low.seconds) / log(high.workload / low.workload)
        return low.seconds * pow(workload / low.workload, exponent)
    }

    /// Rounded the way a person would say it: "about 45 s", "about 1½ min", "about 1 h 10 min".
    static func label(_ seconds: Double) -> String {
        if seconds < 75 { return "about \(max(5, Int((seconds / 5).rounded()) * 5)) s" }
        let minutes = seconds / 60
        if minutes < 10 {
            let halves = Int((minutes * 2).rounded())
            return "about \(halves / 2)\(halves % 2 == 1 ? "½" : "") min"
        }
        if minutes < 60 { return "about \(Int(minutes.rounded())) min" }
        let total = Int((minutes / 5).rounded()) * 5
        return total % 60 == 0 ? "about \(total / 60) h" : "about \(total / 60) h \(total % 60) min"
    }
}
