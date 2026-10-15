import SwiftUI

/// Shared colours keep purpose tags recognizable in search, recommendations and installed models.
/// The app is dark-mode-only, so this is a flat token lookup rather than a light/dark branch.
extension ModelPurpose {
    var tint: Color {
        switch self {
        case .textWriting, .translation: ModelPurposeColor.writing
        case .textAnalysis, .documentUnderstanding: ModelPurposeColor.analysis
        case .imageGeneration, .imageEditing: ModelPurposeColor.imageGeneration
        case .imageUpscaling: ModelPurposeColor.imageUpscaling
        case .imageUnderstanding, .imageAnalysis: ModelPurposeColor.imageUnderstanding
        case .videoGeneration: ModelPurposeColor.videoGeneration
        case .speechGeneration, .audioGeneration, .musicGeneration, .audioAnalysis, .transcription: ModelPurposeColor.audio
        case .unknown: ModelPurposeColor.unknown
        }
    }
}

struct ModelPurposeTags: View {
    let purposes: [ModelPurpose]

    var body: some View {
        ModelPurposeFlowLayout(spacing: Space.sm) {
            ForEach(purposes, id: \.self) { purpose in
                let tint = purpose.tint
                Label(purpose.title, systemImage: purpose.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, Space.md).padding(.vertical, Space.xs + 3)
                    .background(tint.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 1))
                    .help(purpose.summary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ModelAudienceTag: View {
    let isAdultContent: Bool

    var body: some View {
        if isAdultContent {
            Label("NSFW / adult", systemImage: "18.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
                .padding(.horizontal, Space.md).padding(.vertical, Space.xs + 3)
                .background(.red.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(.red.opacity(0.35), lineWidth: 1))
                .help("The publisher marked this Hugging Face repository as not for all audiences.")
                .accessibilityLabel("NSFW or adult content")
        }
    }
}

struct ModelPurposeFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var points: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), points)
    }
}
