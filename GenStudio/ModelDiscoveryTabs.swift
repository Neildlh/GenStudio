import SwiftUI

struct ModelDiscoveryTabs: View {
    let selection: DiscoveryCategory
    var select: (DiscoveryCategory) -> Void

    var body: some View {
        ModelPurposeFlowLayout(spacing: Space.sm) {
            ForEach(DiscoveryCategory.allCases, id: \.self) { category in
                let selected = selection == category
                let tint = category.purpose.tint
                Button { select(category) } label: {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? tint : Color.secondary)
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.md - 2)
                        .background(selected ? tint.opacity(0.15) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(selected ? tint.opacity(0.8) : Color.primary.opacity(0.13), lineWidth: selected ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(category.title) model category")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(category.explanation)
            }
        }
    }
}

extension DiscoveryCategory {
    var purpose: ModelPurpose {
        switch self {
        case .all: .unknown
        case .images: .imageGeneration
        case .video: .videoGeneration
        case .sound: .audioGeneration
        case .text: .textWriting
        case .understanding: .imageUnderstanding
        }
    }
    var explanation: String {
        switch self {
        case .all: "Browse models across all uses, or select a category to narrow your search."
        case .images: "Find models that create new images or edit existing images."
        case .video: "Find models that turn written prompts or reference images into video."
        case .sound: "Find sound and speech generation, transcription and audio processing models."
        case .text: "Find models for writing, summaries, translation and text analysis."
        case .understanding: "Find models that describe images or answer visual questions."
        }
    }
}
