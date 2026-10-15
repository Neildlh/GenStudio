import Foundation

/// Discovery labels describe publisher-declared tasks. They never grant runtime compatibility.
enum ModelPurpose: String, Codable, CaseIterable, Hashable, Sendable {
    case textWriting, imageGeneration, imageEditing, imageUpscaling, imageUnderstanding, videoGeneration
    case speechGeneration, audioGeneration, musicGeneration, transcription, translation
    case imageAnalysis, audioAnalysis, textAnalysis, documentUnderstanding, unknown

    var title: String {
        switch self {
        case .textWriting: "Text & writing"
        case .imageGeneration: "Image generation"
        case .imageEditing: "Image editing"
        case .imageUpscaling: "Image upscaling"
        case .imageUnderstanding: "Image understanding"
        case .videoGeneration: "Video generation"
        case .speechGeneration: "Speech generation"
        case .audioGeneration: "Sound generation"
        case .musicGeneration: "Music generation"
        case .transcription: "Audio transcription"
        case .translation: "Translation"
        case .imageAnalysis: "Image analysis"
        case .audioAnalysis: "Audio analysis"
        case .textAnalysis: "Text analysis"
        case .documentUnderstanding: "Document understanding"
        case .unknown: "Unclassified"
        }
    }

    var systemImage: String {
        switch self {
        case .textWriting, .textAnalysis: "text.alignleft"
        case .imageGeneration: "photo"
        case .imageEditing: "slider.horizontal.3"
        case .imageUpscaling: "arrow.up.left.and.arrow.down.right.rectangle"
        case .imageUnderstanding, .imageAnalysis: "eye"
        case .videoGeneration: "film"
        case .speechGeneration: "waveform.and.mic"
        case .audioGeneration, .audioAnalysis: "waveform"
        case .musicGeneration: "music.note"
        case .transcription: "text.bubble"
        case .translation: "character.bubble"
        case .documentUnderstanding: "doc.text.viewfinder"
        case .unknown: "questionmark.circle"
        }
    }

    var summary: String {
        switch self {
        case .textWriting: "Writes and develops text, such as prompts, captions, scripts and ideas."
        case .imageGeneration: "Creates images from a written description."
        case .imageEditing: "Transforms an existing image; supported edits depend on the model."
        case .imageUpscaling: "Enlarges an existing image while reconstructing plausible detail; this is not a pixel-exact resize."
        case .imageUnderstanding: "Reads images to describe their contents or answer questions about them."
        case .videoGeneration: "Generates video from text or images, depending on its declared inputs."
        case .speechGeneration: "Turns written text into spoken audio."
        case .audioGeneration: "Creates audio from a description; check the model card for supported sounds."
        case .musicGeneration: "Generates music; check the model card for duration and control options."
        case .transcription: "Converts recorded speech into written text."
        case .translation: "Translates text between supported languages."
        case .imageAnalysis: "Identifies, classifies or separates objects and regions in images."
        case .audioAnalysis: "Classifies or transforms existing audio, depending on the task."
        case .textAnalysis: "Classifies, searches or extracts information from text."
        case .documentUnderstanding: "Answers questions about the contents and layout of documents."
        case .unknown: "The publisher has not supplied a recognized task. Inspect the model card to learn its intended use."
        }
    }

    static func declared(pipelineTag: String?, tags: [String]) -> [ModelPurpose] {
        // Exact Hugging Face task tags only: names, prose and format tags are not capability evidence.
        let taskMap: [String: ModelPurpose] = [
            "text-generation": .textWriting, "text2text-generation": .textWriting,
            "summarization": .textWriting, "text-to-image": .imageGeneration,
            "image-to-image": .imageEditing, "image-text-to-text": .imageUnderstanding,
            "image-to-text": .imageUnderstanding, "visual-question-answering": .imageUnderstanding,
            "text-to-video": .videoGeneration, "image-to-video": .videoGeneration,
            "video-to-video": .videoGeneration, "text-to-speech": .speechGeneration,
            "text-to-audio": .audioGeneration, "text-to-music": .musicGeneration,
            "music-generation": .musicGeneration, "automatic-speech-recognition": .transcription,
            "translation": .translation, "image-classification": .imageAnalysis,
            "object-detection": .imageAnalysis, "image-segmentation": .imageAnalysis,
            "depth-estimation": .imageAnalysis, "audio-classification": .audioAnalysis,
            "audio-to-audio": .audioAnalysis, "text-classification": .textAnalysis,
            "token-classification": .textAnalysis, "question-answering": .textAnalysis,
            "sentence-similarity": .textAnalysis, "feature-extraction": .textAnalysis,
            "document-question-answering": .documentUnderstanding
        ]
        var result: [ModelPurpose] = []
        for tag in [pipelineTag].compactMap({ $0 }) + tags {
            if let purpose = taskMap[tag], !result.contains(purpose) { result.append(purpose) }
        }
        return result.isEmpty ? [.unknown] : result
    }
}

/// Bounded, plain-text excerpts of publisher material, not instructions or compatibility evidence.
enum PublisherModelDescription {
    static let maximumCardBytes = 256 * 1024
    static let maximumExcerptCharacters = 420

    static func excerpt(from markdown: String) -> String? {
        guard markdown.utf8.count <= maximumCardBytes else { return nil }
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        text = replacing(#"(?s)<!--.*?-->|<script\b[^>]*>.*?</script>|<style\b[^>]*>.*?</style>"#, in: text, with: "")
        var paragraphs: [String] = []
        var features: [String] = []
        var current: [String] = []
        var fence: String?
        var preferredSection = false
        func flush() {
            if !current.isEmpty {
                let paragraph = current.joined(separator: " ")
                if preferredSection { features.append(paragraph) } else { paragraphs.append(paragraph) }
                current = []
            }
        }
        for line in text.components(separatedBy: "\n") {
            var line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3)); if fence == marker { fence = nil } else if fence == nil { fence = marker }; flush(); continue
            }
            if fence != nil { continue }
            if line.isEmpty { flush(); continue }
            let heading = replacing(#"^[#\s]+"#, in: line, with: "").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            let featureHeading = #"(?i)^(?:key features|key enhancements|capabilities|intended use|model description)(?:\s*:\s*|\s*$)"#
            if let match = heading.range(of: featureHeading, options: .regularExpression) {
                flush(); preferredSection = true
                let remainder = String(heading[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty { current.append(remainder) }
                continue
            }
            let isStandaloneBoldHeading = (line.hasPrefix("**") && line.hasSuffix("**")) || (line.hasPrefix("__") && line.hasSuffix("__"))
            if line.hasPrefix("#") || isStandaloneBoldHeading { flush(); preferredSection = false; continue }
            let isBullet = line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            if isBullet {
                flush()
                guard preferredSection else { continue }
                line = String(line.dropFirst(2))
            }
            if line.hasPrefix("|") || line.hasPrefix(">") || line == "---" || line.hasPrefix("[!") { flush(); continue }
            current.append(line)
        }
        flush()
        func plainProse(_ paragraph: String) -> String? {
            var clean = replacing(#"!\[[^\]]*\]\([^)]*\)|!\[[^\]]*\]\[[^\]]*\]"#, in: paragraph, with: "")
            clean = replacing(#"\[([^\]]+)\]\([^)]*\)"#, in: clean, with: "$1")
            clean = replacing(#"<[^>]+>|https?://\S+|\[\^[^\]]+\]"#, in: clean, with: "")
            clean = clean.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
            clean = replacing(#"\s+"#, in: clean, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 40, clean.split(separator: " ").count >= 7,
                  !clean.hasPrefix("@"), !clean.hasPrefix("["), !clean.lowercased().hasPrefix("copyright ") else { return nil }
            return clean
        }
        let preferred = features.compactMap(plainProse).prefix(2).joined(separator: " ")
        guard let selected = preferred.isEmpty ? paragraphs.compactMap(plainProse).first : preferred else { return nil }
        if selected.count <= maximumExcerptCharacters { return selected }
        let prefix = String(selected.prefix(maximumExcerptCharacters - 1))
        return (prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix) + "…"
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
