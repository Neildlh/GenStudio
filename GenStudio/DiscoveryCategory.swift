import Foundation

/// Human-facing browsing groups. Hub task filters are discovery metadata, not runtime approval.
enum DiscoveryCategory: String, CaseIterable, Hashable, Sendable {
    case all, images, video, sound, text, understanding

    var title: String {
        switch self {
        case .all: "Explore"
        case .images: "Images"
        case .video: "Video"
        case .sound: "Sound"
        case .text: "Text"
        case .understanding: "Image Understanding"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .images: "photo"
        case .video: "film"
        case .sound: "waveform"
        case .text: "text.alignleft"
        case .understanding: "eye"
        }
    }

    var availableTasks: [DiscoveryTask] {
        switch self {
        case .all: [.all]
        case .images: [.all, .image, .imageEditing]
        case .video: [.all, .video, .imageToVideo]
        case .sound: [.all, .audio, .speech, .transcription, .audioAnalysis, .audioEditing]
        case .text: [.all, .text, .summarization, .translation, .textAnalysis, .textExtraction, .questionAnswering, .similarity]
        case .understanding: [.all, .vision, .imageCaptioning, .visualQuestions, .documents]
        }
    }

    func tasks(for selectedTask: DiscoveryTask) -> [DiscoveryTask] {
        if selectedTask != .all && availableTasks.contains(selectedTask) { return [selectedTask] }
        return self == .all ? [.all] : availableTasks.filter { $0 != .all }
    }
}

/// Each task owns its own opaque cursor. Failed streams retain their position for retry.
struct DiscoveryStream: Sendable, Equatable {
    let task: DiscoveryTask
    var cursor: String?
    var finished: Bool = false
}

struct DiscoveryFeedPage: Sendable {
    let models: [DiscoveryModel]
    let streams: [DiscoveryStream]
    let fetchedAt: Date
    let isCached: Bool
    let warnings: [String]
    let successfulRequests: Int
    var hasMore: Bool { streams.contains { !$0.finished } }
}
