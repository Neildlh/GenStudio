import Foundation

/// A small, local creative brief that compiles to ordinary image-model text.
/// Keeping the values structured makes a useful prompt accessible without
/// hiding the final wording behind another model or a remote service.
struct ImagePromptSettings: Codable, Hashable, Sendable {
    var subject = ""
    var subjectCategory = "Person"
    var composition = "Medium shot"
    var cameraAngle = "Eye level"
    var compositionNotes = ""
    var lighting = "Soft daylight"
    var colourTreatment = "Natural colour"
    var lightNotes = ""
    var visualLook = "Photorealistic"
    var lookNotes = ""
    var mood = "Confident and polished"
    var moodNotes = ""
    var aspectRatio = "4:5 portrait"
    var outputIntent = "High-detail editorial image"
    var outputNotes = ""

    static let subjectCategories = ["Person", "Product", "Food", "Interior", "Architecture", "Landscape", "Animal", "Abstract"]
    static let compositions = ["Close-up", "Medium shot", "Full body", "Wide establishing shot", "Top-down flat lay", "Hero product shot", "Detail crop"]
    static let cameraAngles = ["Eye level", "Low angle", "High angle", "Bird's-eye view", "Worm's-eye view", "Straight-on"]
    static let lightings = ["Soft daylight", "Golden hour", "Overcast daylight", "Studio softbox", "Hard directional sun", "Cinematic side light", "Neon practical light"]
    static let colourTreatments = ["Natural colour", "Warm and sunlit", "Cool and restrained", "Rich contrast", "Muted editorial", "Black and white"]
    static let visualLooks = ["Photorealistic", "Luxury editorial", "Cinematic film still", "Clean product photography", "Fashion campaign", "Illustration", "3D render"]
    static let moods = ["Confident and polished", "Warm and inviting", "Quiet and intimate", "Energetic", "Dramatic", "Playful", "Minimal and calm"]
    static let aspectRatios = AspectRatioPreset.allCases.map { aspectRatioDescription($0) }
    static let outputIntents = ["High-detail editorial image", "Social-ready campaign image", "E-commerce product image", "Print-ready hero image", "Concept art frame", "Simple clean reference image"]

    var compiledPrompt: String {
        let cleanSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSubject.isEmpty else { return "" }
        var sentences = ["Create a \(subjectCategory.lowercased()) image.", "Scene direction: \(cleanSubject)."]
        sentences.append("Composition: \(composition), \(cameraAngle.lowercased()) camera angle\(withPrefix(compositionNotes)).")
        sentences.append("Light: \(lighting), \(colourTreatment.lowercased())\(withPrefix(lightNotes)).")
        sentences.append("Look: \(visualLook)\(withPrefix(lookNotes)).")
        sentences.append("Mood: \(mood)\(withPrefix(moodNotes)).")
        sentences.append("Output: \(aspectRatio), \(outputIntent.lowercased())\(withPrefix(outputNotes)).")
        return sentences.joined(separator: " ")
    }

    var aspectRatioPreset: AspectRatioPreset? {
        AspectRatioPreset.allCases.first { aspectRatio.hasPrefix($0.rawValue) }
    }

    static func aspectRatioDescription(_ preset: AspectRatioPreset) -> String {
        switch preset {
        case .square: "1:1 square"
        case .portrait: "4:5 portrait"
        case .portrait23: "2:3 portrait"
        case .vertical: "9:16 vertical"
        case .landscape32: "3:2 landscape"
        case .landscape43: "4:3 landscape"
        case .widescreen: "16:9 widescreen"
        case .cinema: "21:9 cinema"
        }
    }

    private func withPrefix(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "" : ", \(clean)"
    }
}
