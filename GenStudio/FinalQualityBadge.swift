import SwiftUI

/// Marks a final-quality model: slower on this Mac, but better output for the final render. Shown beside every
/// model picker and on the node's card, so a long wait is chosen knowingly. Fast models show nothing; the badge
/// stays rare and meaningful. The text says it too, so colour is never the only signal.
struct FinalQualityBadge: View {
    let recipeID: String
    /// The canvas card uses the short form; inspectors spell out the wait.
    var compact = false

    static let tint = Color.orange

    /// "Final quality · about 25 min a clip", or nil for a fast or unassessed model. Nonisolated so the
    /// nonisolated `ModelAdvisor.pickerNote` can call it; it only reads static catalogue data.
    nonisolated static func text(recipeID: String) -> String? {
        guard let verdict = MacFitStandard.finalQuality(recipeID: recipeID) else { return nil }
        return verdict.wait.map { "Final quality · \($0)" } ?? "Final quality"
    }

    nonisolated static func help(recipeID: String) -> String? {
        guard let verdict = MacFitStandard.finalQuality(recipeID: recipeID) else { return nil }
        let draft = verdict.draftWith.flatMap { ModelAdvisor.displayName($0) }.map { " Draft and check with \($0) first, then switch this node for the final render." } ?? ""
        return "Final-quality model: slower here, \(verdict.wait ?? "a long wait"), for the best output. \(verdict.outranksDraft ?? "")\(draft)"
    }

    var body: some View {
        if let text = Self.text(recipeID: recipeID) {
            Label {
                Text(compact ? "Final · \(MacFitStandard.finalQuality(recipeID: recipeID)?.wait ?? "slow")" : text)
            } icon: {
                Image(systemName: "clock.fill").foregroundStyle(Self.tint)
            }
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                // Material underneath keeps it legible over a thumbnail on the canvas.
                .background(Self.tint.opacity(0.18), in: Capsule())
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Self.tint.opacity(0.5), lineWidth: 0.5))
                .help(Self.help(recipeID: recipeID) ?? text)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
        }
    }
}
