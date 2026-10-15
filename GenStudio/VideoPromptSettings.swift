import Foundation

enum VideoPromptMode: String, Codable, CaseIterable, Sendable {
    case textToVideo, imageToVideo, startEndVideo, videoToVideo, guidedShot

    var title: String {
        switch self {
        case .textToVideo: "Text to Video"
        case .imageToVideo: "Animate Start Image"
        case .startEndVideo: "Start/End Transition"
        case .videoToVideo: "Video Rework"
        case .guidedShot: "Guided Shot"
        }
    }

    var help: String {
        switch self {
        case .textToVideo: "Describe the subject, scene and action for a new shot."
        case .imageToVideo: "Describe only the motion and camera work; the connected image supplies identity and look."
        case .startEndVideo: "Describe the continuous change that takes the start frame to the end frame."
        case .videoToVideo: "Describe the intended edit while preserving the connected clip's useful details."
        case .guidedShot: "Describe the motion through the timed visual anchors."
        }
    }

    /// The shot starts from supplied pictures, which already fix identity, framing and look.
    var isImageDriven: Bool { self != .textToVideo }
}

/// A named camera move and the exact present-tense direction video models respond to. Titles are what
/// documents store; the first twelve are the names earlier versions saved, so old nodes keep their move.
struct VideoCameraMove: Hashable, Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable { case steady = "Steady", moving = "Moving", energetic = "Energetic", ad = "Ad shots" }
    let title: String
    let group: Group
    let direction: String
    /// False when the move has its own speed (a crash zoom) or no camera motion, so a pace would contradict it.
    var takesPace = true
    var id: String { title }

    static let all: [VideoCameraMove] = [
        .init(title: "Static locked camera", group: .steady, direction: "The camera is locked off on a tripod and does not move; only the people and the scene move.", takesPace: false),
        .init(title: "Gentle push in", group: .steady, direction: "The camera pushes in slowly and smoothly toward the subject, gradually tightening the frame."),
        .init(title: "Pull back reveal", group: .steady, direction: "The camera pulls back smoothly from the subject, revealing more of the surroundings."),
        .init(title: "Pan", group: .steady, direction: "The camera pans smoothly across the scene from one side to the other."),
        .init(title: "Pan left to right", group: .steady, direction: "The camera pans slowly from left to right across the scene, ending on the subject."),
        .init(title: "Tilt", group: .steady, direction: "The camera tilts smoothly up or down to follow the subject."),
        .init(title: "Tilt up reveal", group: .steady, direction: "The camera starts low on the ground and tilts up slowly to reveal the subject."),
        .init(title: "Rack focus", group: .steady, direction: "The camera holds its position while the focus shifts from the foreground to the subject."),
        .init(title: "Lateral tracking", group: .moving, direction: "The camera tracks sideways alongside the subject at the same pace, keeping them in frame."),
        .init(title: "Follow behind", group: .moving, direction: "The camera follows behind the subject as they move forward, keeping a steady distance."),
        .init(title: "Lead in front", group: .moving, direction: "The camera moves backward ahead of the subject as they walk toward it, keeping their face in frame."),
        .init(title: "Slow orbit", group: .moving, direction: "The camera arcs slowly around the subject in a smooth half circle, keeping them centred in frame."),
        .init(title: "Crane up", group: .moving, direction: "The camera rises smoothly upward, ending on a high view over the whole scene."),
        .init(title: "Crane down", group: .moving, direction: "The camera descends smoothly from a high angle down to the subject's eye level."),
        .init(title: "Handheld", group: .energetic, direction: "Handheld camera with subtle, natural shake that follows the action like a documentary."),
        .init(title: "Crash zoom", group: .energetic, direction: "The camera zooms in fast on the subject in one sudden, punchy crash zoom.", takesPace: false),
        .init(title: "Whip pan", group: .energetic, direction: "The camera whips quickly sideways in a fast, motion-blurred pan that lands on the subject.", takesPace: false),
        .init(title: "FPV fly-through", group: .energetic, direction: "A smooth first-person drone shot flies forward through the space, gliding close past the details."),
        .init(title: "Drone fly-over", group: .energetic, direction: "An aerial drone shot glides slowly forward high above the location, showing the whole area."),
        .init(title: "Product turntable", group: .ad, direction: "The product turns slowly on the spot while the camera stays still, showing it from every side.", takesPace: false),
        .init(title: "Hero low angle", group: .ad, direction: "A low-angle camera pushes in slowly toward the subject, making them look confident and important."),
        .init(title: "Detail glide", group: .ad, direction: "The camera glides slowly across close-up details of the subject, showing texture and finish."),
        .init(title: "Foreground reveal", group: .ad, direction: "The camera slides past a softly blurred object in the foreground to reveal the subject behind it.")
    ]

    static func named(_ title: String) -> VideoCameraMove? { all.first { $0.title == title } }
}

/// One-click starting points for common advert shots. A recipe sets how the shot is filmed (framing,
/// camera, focus, motion, look and output); it never touches what happens or who is in it.
struct VideoShotRecipe: Hashable, Identifiable, Sendable {
    let title: String
    let summary: String
    let framing: String, cameraMovement: String, cameraPace: String, focus: String, motionStyle: String
    let lighting: String, visualLook: String, mood: String, outputIntent: String
    var id: String { title }

    static let all: [VideoShotRecipe] = [
        .init(title: "Product hero", summary: "Turntable close-up with sculpted light: the product as the star.",
              framing: "Close-up", cameraMovement: "Product turntable", cameraPace: "Slow and controlled", focus: "Shallow depth of field", motionStyle: "Gentle and graceful",
              lighting: "Cinematic side light", visualLook: "Clean commercial", mood: "Confident and premium", outputIntent: "Product reveal"),
        .init(title: "Service in action", summary: "Handheld, documentary feel: your team doing the work.",
              framing: "Medium shot", cameraMovement: "Handheld", cameraPace: "Natural", focus: "Keep the main subject in focus", motionStyle: "Purposeful and clear",
              lighting: "Soft daylight", visualLook: "Natural documentary", mood: "Warm and inviting", outputIntent: "One continuous short shot"),
        .init(title: "Happy customer", summary: "Slow push in on a warm, genuine reaction.",
              framing: "Medium close-up", cameraMovement: "Gentle push in", cameraPace: "Slow and controlled", focus: "Shallow depth of field", motionStyle: "Natural, subtle movement",
              lighting: "Warm golden-hour light", visualLook: "Photorealistic editorial", mood: "Warm and inviting", outputIntent: "Character moment"),
        .init(title: "Location opener", summary: "Drone fly-over that sets the scene: where to find you.",
              framing: "Wide establishing shot", cameraMovement: "Drone fly-over", cameraPace: "Slow and controlled", focus: "Deep focus", motionStyle: "Gentle and graceful",
              lighting: "Warm golden-hour light", visualLook: "Cinematic film texture", mood: "Calm and cinematic", outputIntent: "Atmospheric establishing shot"),
        .init(title: "Social hook", summary: "Crash zoom for an attention-grabbing first second.",
              framing: "Medium shot", cameraMovement: "Crash zoom", cameraPace: "Energetic", focus: "Keep the main subject in focus", motionStyle: "Energetic",
              lighting: "Cinematic side light", visualLook: "Clean commercial", mood: "Playful", outputIntent: "Social-ready vertical moment"),
        .init(title: "Detail close-up", summary: "Glide over textures and finish: quality you can see.",
              framing: "Close-up", cameraMovement: "Detail glide", cameraPace: "Slow and controlled", focus: "Shallow depth of field", motionStyle: "Gentle and graceful",
              lighting: "Cinematic side light", visualLook: "Clean commercial", mood: "Confident and premium", outputIntent: "Product reveal"),
        .init(title: "Walk-in welcome", summary: "Camera leads a person walking toward it: an invitation.",
              framing: "Full body", cameraMovement: "Lead in front", cameraPace: "Steady", focus: "Keep the main subject in focus", motionStyle: "Natural, subtle movement",
              lighting: "Soft daylight", visualLook: "Photorealistic editorial", mood: "Warm and inviting", outputIntent: "One continuous short shot"),
        .init(title: "Big reveal", summary: "Slide past the foreground to reveal the result.",
              framing: "Medium shot", cameraMovement: "Foreground reveal", cameraPace: "Slow and controlled", focus: "Rack focus from foreground to subject", motionStyle: "Gentle and graceful",
              lighting: "Warm golden-hour light", visualLook: "Clean commercial", mood: "Confident and premium", outputIntent: "Product reveal")
    ]
}

/// Structured, single-shot direction. It deliberately produces plain text so
/// every local runtime can receive its own model-specific formatting downstream.
struct VideoPromptSettings: Codable, Hashable, Sendable {
    var mode: VideoPromptMode = .imageToVideo
    var subjectScene = ""
    var action = ""
    var framing = "Medium shot"
    var cameraMovement = "Gentle push in"
    var cameraPace = "Slow and controlled"
    var focus = "Keep the main subject in focus"
    var motionStyle = "Natural, subtle movement"
    var continuity = ""
    var lighting = "Preserve the established lighting"
    var visualLook = "Preserve the established visual style"
    var mood = "Calm and cinematic"
    var openingBeat = ""
    var middleBeat = ""
    var endingBeat = ""
    var outputIntent = "One continuous short shot"
    var avoid = ""
    /// Sound for models that make it (LTX-2.3). Empty means none is described.
    var ambience = ""
    var music = ""
    /// Who speaks the line; empty reads as "A voice".
    var speaker = ""
    var spokenLine = ""

    static let framings = ["Close-up", "Medium close-up", "Medium shot", "Full body", "Wide establishing shot", "Top-down", "Over-the-shoulder"]
    static var cameraMovements: [String] { VideoCameraMove.all.map(\.title) }
    static let cameraPaces = ["Slow and controlled", "Natural", "Steady", "Energetic"]
    static let focusOptions = ["Keep the main subject in focus", "Shallow depth of field", "Deep focus", "Rack focus from foreground to subject", "Rack focus from subject to background"]
    static let motionStyles = ["Natural, subtle movement", "Gentle and graceful", "Purposeful and clear", "Energetic", "Slow motion feel"]
    static let lightings = ["Preserve the established lighting", "Warm golden-hour light", "Soft daylight", "Cinematic side light", "Cool practical light", "High-contrast dramatic light"]
    static let visualLooks = ["Preserve the established visual style", "Photorealistic editorial", "Cinematic film texture", "Clean commercial", "Fashion campaign", "Natural documentary"]
    static let moods = ["Calm and cinematic", "Warm and inviting", "Quiet and intimate", "Confident and premium", "Dramatic", "Playful"]
    static let outputIntents = ["One continuous short shot", "Social-ready vertical moment", "Product reveal", "Character moment", "Atmospheric establishing shot"]
    static let ambienceSuggestions = ["Natural room tone", "Busy street outside", "Quiet café chatter", "Barbershop buzz and clippers", "Salon hairdryers and chatter", "Workshop tools", "Kitchen sizzle", "Birdsong and gentle wind", "Ocean waves", "Rain on the window"]
    static let musicSuggestions = ["Upbeat acoustic guitar", "Warm solo piano", "Uplifting corporate pop", "Amapiano-style log drum and piano groove", "Afro-house beat", "Gentle lo-fi beat", "Cinematic strings"]
    /// About 2½ spoken words a second fit a five-second clip.
    static let spokenWordLimit = 12

    var spokenLineIsLong: Bool { spokenLine.split(whereSeparator: \.isWhitespace).count > Self.spokenWordLimit }

    mutating func apply(_ recipe: VideoShotRecipe) {
        framing = recipe.framing; cameraMovement = recipe.cameraMovement; cameraPace = recipe.cameraPace; focus = recipe.focus
        motionStyle = recipe.motionStyle; lighting = recipe.lighting; visualLook = recipe.visualLook; mood = recipe.mood; outputIntent = recipe.outputIntent
    }

    /// One flowing, present-tense description: what happens leads, then how it is filmed, how it looks,
    /// and finally how it sounds. Settings that only say "preserve" add nothing a model can see, so the
    /// image-driven modes leave them out and close by tying the shot to its supplied pictures instead.
    var compiledPrompt: String {
        guard !Self.trimmed(action).isEmpty else { return "" }
        var sentences: [String] = []
        if let lead = modeLead { sentences.append(lead) }
        let action = Self.opening(action), scene = Self.opening(subjectScene), framing = Self.opening(framing)
        sentences += mode.isImageDriven ? [action, scene, framing] : [framing, scene, action]
        sentences.append(beats)
        let move = VideoCameraMove.named(cameraMovement)
        sentences.append(move?.direction ?? Self.sentence(cameraMovement))
        if move?.takesPace ?? true { sentences.append(Self.pacePhrases[cameraPace] ?? (Self.trimmed(cameraPace).isEmpty ? "" : "The camera moves \(Self.lowercasedFirst(Self.withoutClosingPunctuation(Self.trimmed(cameraPace)))).")) }
        sentences.append(Self.focusPhrases[focus] ?? Self.sentence(focus))
        sentences.append(Self.motionPhrases[motionStyle] ?? Self.sentence(motionStyle))
        sentences.append(look)
        if !Self.trimmed(continuity).isEmpty { sentences.append("Keep consistent: \(Self.sentence(Self.lowercasedFirst(Self.trimmed(continuity))))") }
        sentences.append(Self.outputPhrases[outputIntent] ?? Self.sentence(outputIntent))
        if let tail = modeTail { sentences.append(tail) }
        sentences.append(sound)
        return sentences.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var modeLead: String? {
        switch mode {
        case .textToVideo, .imageToVideo: nil
        case .startEndVideo: "One continuous shot with no cuts that moves from the opening frame to the closing frame."
        case .videoToVideo: "A rework of the source clip that keeps its people, action and timing."
        case .guidedShot: "One continuous shot that passes through each timed reference frame."
        }
    }

    private var modeTail: String? {
        switch mode {
        case .imageToVideo: "The people, clothing, setting and lighting stay exactly as in the starting image."
        case .startEndVideo: "Faces, clothing and setting stay consistent from start to end."
        case .textToVideo, .videoToVideo, .guidedShot: nil
        }
    }

    private var beats: String {
        let items = [openingBeat, middleBeat, endingBeat].map(Self.trimmed).filter { !$0.isEmpty }.map(Self.withoutClosingPunctuation)
        switch items.count {
        case 0: return ""
        case 1: return Self.sentence(items[0])
        case 2: return "First, \(items[0]). Then \(items[1])."
        default: return "First, \(items[0]). Then \(items[1]). Finally, \(items[2])."
        }
    }

    private var look: String {
        var parts: [String] = []
        let lighting = Self.trimmed(lighting), visualLook = Self.trimmed(visualLook), mood = Self.trimmed(mood)
        if !lighting.isEmpty, !lighting.hasPrefix("Preserve") { parts.append(lighting) }
        if !visualLook.isEmpty, !visualLook.hasPrefix("Preserve") { parts.append("\(Self.lowercasedFirst(visualLook)) look") }
        if !mood.isEmpty, !mood.hasPrefix("Preserve") { parts.append("\(Self.lowercasedFirst(mood)) mood") }
        guard !parts.isEmpty else { return "" }
        return Self.capitalizedFirst(parts.joined(separator: ", ")) + "."
    }

    private var sound: String {
        var sentences: [String] = []
        let described = [ambience, music].map(Self.trimmed).filter { !$0.isEmpty }.map { Self.lowercasedFirst(Self.withoutClosingPunctuation($0)) }
        if !described.isEmpty { sentences.append("Sound: \(described.joined(separator: ", ")).") }
        let line = Self.trimmed(spokenLine).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        if !line.isEmpty {
            let who = Self.trimmed(speaker).isEmpty ? "A voice" : Self.capitalizedFirst(Self.withoutClosingPunctuation(Self.trimmed(speaker)))
            sentences.append("\(who) says, \"\(Self.opening(line))\"")
        }
        return sentences.joined(separator: " ")
    }

    /// "Natural" adds nothing a model can act on, so it adds no sentence.
    private static let pacePhrases = [
        "Slow and controlled": "The camera moves slowly and with control.",
        "Natural": "",
        "Steady": "The camera moves steadily.",
        "Energetic": "The camera moves with energy."
    ]
    private static let focusPhrases = [
        "Keep the main subject in focus": "The subject stays in sharp focus.",
        "Shallow depth of field": "Shallow depth of field with a softly blurred background.",
        "Deep focus": "Deep focus keeps the whole scene sharp.",
        "Rack focus from foreground to subject": "Focus racks from the foreground to the subject.",
        "Rack focus from subject to background": "Focus racks from the subject to the background."
    ]
    private static let motionPhrases = [
        "Natural, subtle movement": "Movement is natural and subtle.",
        "Gentle and graceful": "Movement is gentle and graceful.",
        "Purposeful and clear": "Movement is purposeful and clear.",
        "Energetic": "Movement is energetic.",
        "Slow motion feel": "Movement has a slow-motion feel."
    ]
    private static let outputPhrases = [
        "One continuous short shot": "One continuous shot with no cuts.",
        "Social-ready vertical moment": "A punchy, social-ready moment in one continuous shot.",
        "Product reveal": "The shot builds to a clear reveal of the product.",
        "Character moment": "A focused character moment in one continuous shot.",
        "Atmospheric establishing shot": "An atmospheric establishing shot."
    ]

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func withoutClosingPunctuation(_ text: String) -> String {
        var value = text
        while let last = value.last, ".,;:".contains(last) { value.removeLast() }
        return trimmed(value)
    }
    /// Ends text with exactly one full stop unless it already ends a sentence (! ? or a closing quote).
    private static func sentence(_ text: String) -> String {
        let value = withoutClosingPunctuation(trimmed(text))
        guard let last = value.last else { return "" }
        return "!?\"”'".contains(last) ? value : value + "."
    }
    /// A sentence the person wrote, starting with a capital.
    private static func opening(_ text: String) -> String { sentence(capitalizedFirst(trimmed(text))) }
    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep acronyms and names that start with two capitals ("FPV", "LED").
        if text.count > 1, text.dropFirst().first?.isUppercase == true { return text }
        return first.lowercased() + text.dropFirst()
    }
    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

extension VideoPromptSettings {
    private enum CodingKeys: String, CodingKey {
        case mode, subjectScene, action, framing, cameraMovement, cameraPace, focus, motionStyle, continuity, lighting, visualLook, mood
        case openingBeat, middleBeat, endingBeat, outputIntent, avoid, ambience, music, speaker, spokenLine
    }

    /// Every field falls back to its default, so nodes saved before a field existed still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        mode = try c.decodeIfPresent(VideoPromptMode.self, forKey: .mode) ?? mode
        func text(_ key: CodingKeys, _ fallback: String) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? fallback }
        subjectScene = try text(.subjectScene, subjectScene); action = try text(.action, action); framing = try text(.framing, framing)
        cameraMovement = try text(.cameraMovement, cameraMovement); cameraPace = try text(.cameraPace, cameraPace); focus = try text(.focus, focus)
        motionStyle = try text(.motionStyle, motionStyle); continuity = try text(.continuity, continuity); lighting = try text(.lighting, lighting)
        visualLook = try text(.visualLook, visualLook); mood = try text(.mood, mood); openingBeat = try text(.openingBeat, openingBeat)
        middleBeat = try text(.middleBeat, middleBeat); endingBeat = try text(.endingBeat, endingBeat); outputIntent = try text(.outputIntent, outputIntent)
        avoid = try text(.avoid, avoid); ambience = try text(.ambience, ambience); music = try text(.music, music)
        speaker = try text(.speaker, speaker); spokenLine = try text(.spokenLine, spokenLine)
    }
}
