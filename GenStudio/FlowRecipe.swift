import Foundation

// MARK: - Recipe file format

/// Minimal JSON value so a recipe's `settings` can carry any per-kind field without a schema per node.
enum FlowValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), array([FlowValue]), object([String: FlowValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([FlowValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: FlowValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var kindName: String {
        switch self { case .string: "text"; case .number: "number"; case .bool: "true/false"; case .array: "list"; case .object: "object"; case .null: "null" }
    }
}

struct FlowNodeSpec: Codable, Hashable, Sendable {
    var id: String
    var kind: String
    var label: String?
    var settings: [String: FlowValue]?
    /// Labels of the sockets on nodes whose inputs are declared by the author (Combine Text, Prompt Template, Image Describer, Assemble…).
    var inputs: [String]?
}

struct FlowRecipe: Codable, Hashable, Sendable {
    static let formatName = "genstudio.flow"
    static let currentVersion = 1
    var format: String? = FlowRecipe.formatName
    var version: Int? = FlowRecipe.currentVersion
    var name: String?
    var description: String?
    var nodes: [FlowNodeSpec]
    var wires: [String]

    init(name: String?, description: String? = nil, nodes: [FlowNodeSpec], wires: [String]) {
        self.name = name; self.description = description; self.nodes = nodes; self.wires = wires
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        nodes = try c.decode([FlowNodeSpec].self, forKey: .nodes)
        wires = try c.decodeIfPresent([String].self, forKey: .wires) ?? []
    }
    private enum CodingKeys: String, CodingKey { case format, version, name, description, nodes, wires }
}

// MARK: - Issues

struct FlowIssue: Hashable, Sendable {
    enum Severity: String, Sendable { case error, warning }
    var severity: Severity
    /// Where in the recipe, for example `nodes[2].settings.width` or `wires[4]`.
    var path: String
    var message: String
    var line: String { "\(severity == .error ? "ERROR" : "WARNING") \(path): \(message)" }
}

struct FlowCompileResult: Sendable {
    var project: WorkflowProject?
    var issues: [FlowIssue]
    var errors: [FlowIssue] { issues.filter { $0.severity == .error } }
    var warnings: [FlowIssue] { issues.filter { $0.severity == .warning } }

    /// Written so it can be pasted straight back into a chat with the AI that authored the recipe.
    func report(for name: String? = nil) -> String {
        var lines: [String] = []
        if !errors.isEmpty {
            lines.append("GenStudio could not import\(name.map { " “\($0)”" } ?? " this flow"). Fix these \(errors.count) problem\(errors.count == 1 ? "" : "s") and send back the complete corrected JSON:")
            lines += errors.map { "- " + $0.line }
        }
        if !warnings.isEmpty {
            lines.append(errors.isEmpty ? "Imported with notes:" : "Also noted:")
            lines += warnings.map { "- " + $0.line }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Settings catalog (single source of truth for compiler, exporter and briefing)

struct FlowSetting: @unchecked Sendable {
    enum ValueType {
        case text, bool
        case integer(ClosedRange<Int>)
        case number(ClosedRange<Double>)
        case choice([String])
        /// Structured value validated by its own setter. The string describes the shape for the briefing.
        case structured(String)

        var summary: String {
            switch self {
            case .text: "text"
            case .bool: "true / false"
            case .integer(let r): "whole number \(r.lowerBound)…\(r.upperBound)"
            case .number(let r): "number \(FlowNaming.plain(r.lowerBound))…\(FlowNaming.plain(r.upperBound))"
            case .choice(let options): options.map { "\"\($0)\"" }.joined(separator: " | ")
            case .structured(let shape): shape
            }
        }
    }
    let key: String
    let kinds: [NodeKind]
    let type: ValueType
    let summary: String
    let get: (StudioNode) -> FlowValue
    let set: (inout StudioNode, FlowValue) throws -> Void
}

struct FlowSettingError: Error { let message: String }

enum FlowSettingCatalog {
    static func settings(for kind: NodeKind) -> [FlowSetting] { all.filter { $0.kinds.contains(kind) } }
    static func setting(_ key: String, for kind: NodeKind) -> FlowSetting? { all.first { $0.key == key && $0.kinds.contains(kind) } }

    private static func str(_ v: FlowValue) -> String { if case .string(let s) = v { s } else { "" } }
    private static func num(_ v: FlowValue) -> Double { if case .number(let n) = v { n } else { 0 } }
    private static func flag(_ v: FlowValue) -> Bool { if case .bool(let b) = v { b } else { false } }

    private static func text(_ key: String, _ kinds: [NodeKind], _ summary: String, _ kp: WritableKeyPath<StudioNode, String>) -> FlowSetting {
        FlowSetting(key: key, kinds: kinds, type: .text, summary: summary, get: { .string($0[keyPath: kp]) }, set: { $0[keyPath: kp] = str($1) })
    }
    private static func int(_ key: String, _ kinds: [NodeKind], _ range: ClosedRange<Int>, _ summary: String, _ kp: WritableKeyPath<StudioNode, Int>) -> FlowSetting {
        FlowSetting(key: key, kinds: kinds, type: .integer(range), summary: summary, get: { .number(Double($0[keyPath: kp])) }, set: { $0[keyPath: kp] = Int(num($1)) })
    }
    private static func dbl(_ key: String, _ kinds: [NodeKind], _ range: ClosedRange<Double>, _ summary: String, _ kp: WritableKeyPath<StudioNode, Double>) -> FlowSetting {
        FlowSetting(key: key, kinds: kinds, type: .number(range), summary: summary, get: { .number($0[keyPath: kp]) }, set: { $0[keyPath: kp] = num($1) })
    }
    private static func bool(_ key: String, _ kinds: [NodeKind], _ summary: String, _ kp: WritableKeyPath<StudioNode, Bool>) -> FlowSetting {
        FlowSetting(key: key, kinds: kinds, type: .bool, summary: summary, get: { .bool($0[keyPath: kp]) }, set: { $0[keyPath: kp] = flag($1) })
    }
    /// A string field inside Image Prompt's structured brief, restricted to the choices the app's own pickers offer.
    private static func imagePrompt(_ key: String, _ options: [String]?, _ summary: String, _ kp: WritableKeyPath<ImagePromptSettings, String>) -> FlowSetting {
        FlowSetting(key: key, kinds: [.imagePrompt], type: options.map { .choice($0) } ?? .text, summary: summary,
                    get: { .string(($0.imagePromptSettings ?? .init())[keyPath: kp]) },
                    set: { node, value in var s = node.imagePromptSettings ?? .init(); s[keyPath: kp] = str(value); node.imagePromptSettings = s })
    }
    private static func videoPrompt(_ key: String, _ options: [String]?, _ summary: String, _ kp: WritableKeyPath<VideoPromptSettings, String>) -> FlowSetting {
        FlowSetting(key: key, kinds: [.videoPrompt], type: options.map { .choice($0) } ?? .text, summary: summary,
                    get: { .string(($0.videoPromptSettings ?? .init())[keyPath: kp]) },
                    set: { node, value in var s = node.videoPromptSettings ?? .init(); s[keyPath: kp] = str(value); node.videoPromptSettings = s })
    }

    private static func endCard(_ key: String, _ summary: String, _ kp: WritableKeyPath<EndCardSettings, String>) -> FlowSetting {
        FlowSetting(key: key, kinds: [.endCard], type: .text, summary: summary,
                    get: { .string(($0.endCardSettings ?? .init())[keyPath: kp]) },
                    set: { node, value in var s = node.endCardSettings ?? .init(); s[keyPath: kp] = str(value); node.endCardSettings = s })
    }

    static let videoKinds: [NodeKind] = [.textToVideo, .imageToVideo, .startEndVideo, .guidedShot, .videoToVideo]
    private static let modelKinds: [NodeKind] = [.textModel, .promptEnhancer, .imageDescriber]

    static let all: [FlowSetting] = {
        var list: [FlowSetting] = []
        // Text and numbers
        list.append(text("text", [.prompt, .promptTemplate, .stickyNote], "The text of the node. For Prompt Template, write {{name}} placeholders that match the node's `inputs` labels.", \.prompt))
        list.append(dbl("value", [.number], -1_000_000...1_000_000, "The number this node supplies.", \.numberValue))
        list.append(text("separator", [.combineText], "Text placed between the joined parts. The default is a line break.", \.separator))
        list.append(text("delimiter", [.textArray], "What splits the text into items. The default `\\n` means one item per line.", \.arrayDelimiter))
        list.append(bool("trim", [.textArray], "Trim whitespace around each item.", \.arrayTrim))
        list.append(int("index", [.listSelect], 1...256, "Which item to pick, counting from 1.", \.listIndex))
        // Structured prompt builders
        list.append(imagePrompt("subject", nil, "What the image shows. Required for the node to produce a prompt.", \.subject))
        list.append(imagePrompt("subjectCategory", ImagePromptSettings.subjectCategories, "Kind of subject.", \.subjectCategory))
        list.append(imagePrompt("composition", ImagePromptSettings.compositions, "Framing.", \.composition))
        list.append(imagePrompt("cameraAngle", ImagePromptSettings.cameraAngles, "Camera angle.", \.cameraAngle))
        list.append(imagePrompt("lighting", ImagePromptSettings.lightings, "Lighting.", \.lighting))
        list.append(imagePrompt("colourTreatment", ImagePromptSettings.colourTreatments, "Colour treatment.", \.colourTreatment))
        list.append(imagePrompt("visualLook", ImagePromptSettings.visualLooks, "Overall look.", \.visualLook))
        list.append(imagePrompt("mood", ImagePromptSettings.moods, "Mood.", \.mood))
        list.append(imagePrompt("aspectRatio", ImagePromptSettings.aspectRatios, "Target aspect ratio described in the prompt. It does not resize the Image Generator; set that node's width and height too.", \.aspectRatio))
        list.append(imagePrompt("outputIntent", ImagePromptSettings.outputIntents, "What the image is for.", \.outputIntent))
        list.append(FlowSetting(key: "mode", kinds: [.videoPrompt], type: .choice(VideoPromptMode.allCases.map(\.rawValue)), summary: "Which video node this prompt is written for.",
                                get: { .string(($0.videoPromptSettings ?? .init()).mode.rawValue) },
                                set: { node, value in var s = node.videoPromptSettings ?? .init(); s.mode = VideoPromptMode(rawValue: str(value)) ?? s.mode; node.videoPromptSettings = s }))
        list.append(videoPrompt("action", nil, "What happens in the shot. Required for the node to produce a prompt.", \.action))
        list.append(videoPrompt("subjectScene", nil, "Who or what is in the shot and where.", \.subjectScene))
        list.append(videoPrompt("framing", VideoPromptSettings.framings, "Framing.", \.framing))
        list.append(videoPrompt("cameraMovement", VideoPromptSettings.cameraMovements, "Camera movement.", \.cameraMovement))
        list.append(videoPrompt("cameraPace", VideoPromptSettings.cameraPaces, "Camera pace.", \.cameraPace))
        list.append(videoPrompt("motionStyle", VideoPromptSettings.motionStyles, "Style of movement.", \.motionStyle))
        list.append(videoPrompt("lighting", VideoPromptSettings.lightings, "Lighting.", \.lighting))
        list.append(videoPrompt("visualLook", VideoPromptSettings.visualLooks, "Overall look.", \.visualLook))
        list.append(videoPrompt("mood", VideoPromptSettings.moods, "Mood.", \.mood))
        list.append(videoPrompt("avoid", nil, "Things the shot must not contain.", \.avoid))
        list.append(videoPrompt("ambience", nil, "Sound of the setting, for LTX-2.3 clips (which make sound), e.g. \"Busy street outside\".", \.ambience))
        list.append(videoPrompt("music", nil, "Music under the shot, for LTX-2.3 clips, e.g. \"Upbeat acoustic guitar\".", \.music))
        list.append(videoPrompt("speaker", nil, "Who says the spoken line, e.g. \"The barber\".", \.speaker))
        list.append(videoPrompt("spokenLine", nil, "A short line spoken in the shot (about 12 words for five seconds), for LTX-2.3 clips.", \.spokenLine))
        func caption(_ key: String, _ type: FlowSetting.ValueType, _ summary: String, get: @escaping (TextOverlaySettings) -> FlowValue, set: @escaping (inout TextOverlaySettings, FlowValue) -> Void) -> FlowSetting {
            FlowSetting(key: key, kinds: [.textOverlay], type: type, summary: summary, get: { get($0.textOverlaySettings ?? .init()) },
                        set: { node, value in var s = node.textOverlaySettings ?? .init(); set(&s, value); node.textOverlaySettings = s })
        }
        list.append(FlowSetting(key: "format", kinds: [.instagramExport], type: .choice(DeliveryFormat.allCases.map(\.rawValue)), summary: "Delivery shape: vertical 9:16, feed 4:5, square 1:1 or landscape 16:9.",
                                get: { .string($0.format.rawValue) }, set: { node, value in node.format = DeliveryFormat(rawValue: str(value)) ?? node.format }))
        func voiceover(_ key: String, _ type: FlowSetting.ValueType, _ summary: String, get: @escaping (VoiceoverSettings) -> FlowValue, set: @escaping (inout VoiceoverSettings, FlowValue) -> Void) -> FlowSetting {
            FlowSetting(key: key, kinds: [.voiceover], type: type, summary: summary, get: { get($0.voiceoverSettings ?? .init()) },
                        set: { node, value in var s = node.voiceoverSettings ?? .init(); set(&s, value); node.voiceoverSettings = s })
        }
        list.append(voiceover("script", .text, "What the voice says. Short: about 2½ words per second of video.", get: { .string($0.script) }, set: { $0.script = str($1) }))
        list.append(voiceover("voice", .text, "The voice in plain words, e.g. \"A warm, friendly South African woman in her thirties\".", get: { .string($0.voice) }, set: { $0.voice = str($1) }))
        list.append(voiceover("startSeconds", .number(0...600), "When the voice starts.", get: { .number($0.startSeconds) }, set: { $0.startSeconds = num($1) }))
        list.append(caption("text", .text, "The caption, e.g. \"From R150\". Required.", get: { .string($0.text) }, set: { $0.text = str($1) }))
        list.append(caption("subtext", .text, "Optional smaller second line.", get: { .string($0.subtext) }, set: { $0.subtext = str($1) }))
        list.append(caption("position", .choice(TextOverlaySettings.Position.allCases.map(\.rawValue)), "Where the caption sits.", get: { .string($0.position.rawValue) }, set: { $0.position = .init(rawValue: str($1)) ?? $0.position }))
        list.append(caption("style", .choice(TextOverlaySettings.Style.allCases.map(\.rawValue)), "Band behind the caption or text with a shadow.", get: { .string($0.style.rawValue) }, set: { $0.style = .init(rawValue: str($1)) ?? $0.style }))
        list.append(caption("startSeconds", .number(0...600), "When the caption appears.", get: { .number($0.startSeconds) }, set: { $0.startSeconds = num($1) }))
        list.append(caption("durationSeconds", .number(0...600), "How long it stays; 0 means until the clip ends.", get: { .number($0.durationSeconds) }, set: { $0.durationSeconds = num($1) }))
        list.append(endCard("headline", "Largest line of the closing card, usually the business name.", \.headline))
        list.append(endCard("offer", "The offer, in the accent colour, e.g. \"Fresh cuts from R150\".", \.offer))
        list.append(endCard("contact", "How to get in touch, e.g. \"WhatsApp 082 123 4567\".", \.contact))
        list.append(endCard("website", "Web address or social handle.", \.website))
        list.append(FlowSetting(key: "durationSeconds", kinds: [.endCard], type: .number(EndCardSettings.durationRange), summary: "How long the card shows, in seconds.",
                                get: { .number(($0.endCardSettings ?? .init()).durationSeconds) },
                                set: { node, value in var s = node.endCardSettings ?? .init(); s.durationSeconds = num(value); node.endCardSettings = s }))
        // Language and vision models
        list.append(dbl("temperature", modelKinds, 0...2, "Sampling temperature.", \.temperature))
        list.append(int("maxTokens", modelKinds, 1...8192, "Longest reply, in tokens.", \.maxTokens))
        list.append(FlowSetting(key: "writeFor", kinds: [.promptEnhancer], type: .choice(["auto"] + PromptEnhancerTarget.allCases.map(\.rawValue)), summary: "What the enhanced prompt is written for. `auto` (the default) follows the node its output feeds.",
                                get: { .string($0.promptEnhancerTarget?.rawValue ?? "auto") },
                                set: { node, value in node.promptEnhancerTarget = PromptEnhancerTarget(rawValue: str(value)) }))
        list.append(text("instructions", [.imageDescriber], "What to describe and how. The default is a general description of at most 500 characters.", \.prompt))
        list.append(FlowSetting(key: "subject", kinds: [.characterSheet], type: .choice(CharacterSheetSubject.allCases.map(\.rawValue)), summary: "Which fixed turnaround layout to write.",
                                get: { .string($0.characterSheetSubject.rawValue) },
                                set: { node, value in
                                    guard let subject = CharacterSheetSubject(rawValue: str(value)) else { return }
                                    node.characterSheetSubject = subject; node.prompt = node.characterSheetBrief
                                }))
        list.append(FlowSetting(key: "pose", kinds: [.characterSheet], type: .choice(CharacterSheetPose.allCases.map(\.rawValue)), summary: "People/Character body pose. Choose seated for a seated baby or standing for a standing subject; original asks the image model to retain the source pose. Other categories ignore this setting.",
                                get: { .string($0.characterSheetPose.rawValue) },
                                set: { node, value in
                                    node.characterSheetPose = CharacterSheetPose(rawValue: str(value)) ?? .original
                                    node.prompt = node.characterSheetBrief
                                }))
        list.append(FlowSetting(key: "heightCM", kinds: [.characterSheet], type: .number(0...100_000), summary: "Known height in centimetres; infant body length for People, shoulder height for quadruped Animals. Omit or use 0 when unknown; never estimate from a picture.",
                                get: { .number($0.characterSheetHeightCM ?? 0) },
                                set: { node, value in
                                    let height = num(value)
                                    node.characterSheetHeightCM = height > 0 ? height : nil
                                    node.prompt = node.characterSheetBrief
                                }))
        // Image generation
        list.append(int("width", [.imageGenerator, .imageResize], 64...4096, "Pixels. FLUX.2 Klein accepts 512–1024 in multiples of 16; other recipes have their own limits.", \.width))
        list.append(int("height", [.imageGenerator, .imageResize], 64...4096, "Pixels. FLUX.2 Klein accepts 512–1024 in multiples of 16; other recipes have their own limits.", \.height))
        list.append(FlowSetting(key: "seed", kinds: [.imageGenerator], type: .integer(0...2_147_483_647), summary: "Fixes the seed so runs repeat. Leave out to get a fresh seed on every run.",
                                get: { .number(Double($0.imageSeed)) }, set: { $0.imageSeed = Int(num($1)); $0.seedLocked = true }))
        list.append(FlowSetting(key: "strength", kinds: [.imageGenerator], type: .number(0...1), summary: "Image-to-image strength when a reference is wired. 0.75 by default.",
                                get: { .number($0.imageStrength ?? 0.75) }, set: { $0.imageStrength = num($1) }))
        list.append(FlowSetting(key: "referenceRoles", kinds: [.imageGenerator], type: .structured("object mapping a reference port to what it supplies, e.g. {\"referenceImage\": \"the character's face and outfit\", \"referenceImage2\": \"the room to place her in\"}"),
                                summary: "Names what each reference image supplies. FLUX.2 Klein only.",
                                get: { node in .object((node.referenceRoles ?? [:]).mapValues { .string($0) }) },
                                set: { node, value in
                                    guard case .object(let roles) = value else { throw FlowSettingError(message: "must be an object like {\"referenceImage\": \"what it supplies\"}.") }
                                    var result: [String: String] = [:]
                                    for (port, role) in roles {
                                        guard NodeKind.imageGeneratorReferencePortIDs.contains(port) else { throw FlowSettingError(message: "'\(port)' is not a reference port. Use \(NodeKind.imageGeneratorReferencePortIDs.joined(separator: ", ")).") }
                                        guard case .string(let text) = role else { throw FlowSettingError(message: "the role for \(port) must be text.") }
                                        result[port] = text
                                    }
                                    node.referenceRoles = result.isEmpty ? nil : result
                                }))
        // Image editing
        list.append(dbl("cropX", [.imageCrop], 0...1, "Left edge, 0–1 of the image width.", \.cropX))
        list.append(dbl("cropY", [.imageCrop], 0...1, "Top edge, 0–1 of the image height.", \.cropY))
        list.append(dbl("cropWidth", [.imageCrop], 0...1, "Width, 0–1. cropX + cropWidth must not exceed 1.", \.cropWidth))
        list.append(dbl("cropHeight", [.imageCrop], 0...1, "Height, 0–1. cropY + cropHeight must not exceed 1.", \.cropHeight))
        list.append(dbl("opacity", [.imageBlend], 0...1, "Foreground opacity when the Opacity input is not wired.", \.opacity))
        list.append(int("selection", [.imageCompare], 0...1, "Which image flows through Selected: 0 = Image A, 1 = Image B.", \.comparisonSelection))
        list.append(int("quarterTurns", [.imageRotateFlip], 0...3, "Clockwise 90° turns.", \.quarterTurns))
        list.append(bool("flipHorizontal", [.imageRotateFlip], "Mirror left to right.", \.flipHorizontal))
        list.append(bool("flipVertical", [.imageRotateFlip], "Mirror top to bottom.", \.flipVertical))
        list.append(dbl("blurRadius", [.imageBlur], 0...200, "Gaussian blur radius in pixels.", \.blurRadius))
        list.append(bool("invert", [.maskOperations], "Invert the mask.", \.maskInvert))
        list.append(int("growShrink", [.maskOperations], -64...64, "Positive grows the white area, negative shrinks it, in pixels.", \.maskGrowShrink))
        list.append(dbl("feather", [.maskOperations], 0...64, "Edge softening in pixels.", \.maskFeather))
        list.append(int("scale", [.imageUpscale, .videoUpscale], 2...4, "Enlargement factor: 2 or 4.", \.upscaleScale))
        list.append(int("tileSize", [.imageUpscale, .videoUpscale], 0...256, "0 (auto), 64, 128 or 256. Leave at the default unless memory is a problem.", \.upscaleTileSize))
        list.append(int("fps", [.frameInterpolate, .instagramExport], 1...120, "Delivery frame rate.", \.deliveryFPS))
        // Video generation
        func video<T>(_ key: String, _ type: FlowSetting.ValueType, _ summary: String, get: @escaping (VideoGenerationSettings) -> T, toValue: @escaping (T) -> FlowValue, set: @escaping (inout VideoGenerationSettings, FlowValue) -> Void) -> FlowSetting {
            FlowSetting(key: key, kinds: videoKinds, type: type, summary: summary, get: { toValue(get($0.video)) }, set: { node, value in var s = node.video; set(&s, value); node.video = s })
        }
        list.append(video("negativePrompt", .text, "What the clip must avoid.", get: { $0.negativePrompt }, toValue: { .string($0) }, set: { $0.negativePrompt = str($1) }))
        list.append(video("width", .integer(64...4096), "Pixels. Clips are small by default; enlarge afterwards with Video Upscale rather than raising this.", get: { $0.width }, toValue: { .number(Double($0)) }, set: { $0.width = Int(num($1)) }))
        list.append(video("height", .integer(64...4096), "Pixels. Clips are small by default; enlarge afterwards with Video Upscale rather than raising this.", get: { $0.height }, toValue: { .number(Double($0)) }, set: { $0.height = Int(num($1)) }))
        list.append(video("fps", .integer(1...60), "Frames per second of the generated clip.", get: { $0.fps }, toValue: { .number(Double($0)) }, set: { $0.fps = Int(num($1)); $0.frameCount = max(1, Int(($0.requestedDurationSeconds * Double($0.fps)).rounded())) }))
        list.append(video("durationSeconds", .number(0.25...30), "Clip length in seconds. The exact recipe rounds it to the frame counts it supports.", get: { $0.requestedDurationSeconds }, toValue: { .number($0) }, set: { $0.requestedDurationSeconds = num($1); $0.frameCount = max(1, Int(($0.requestedDurationSeconds * Double($0.fps)).rounded())) }))
        list.append(video("steps", .integer(1...100), "Sampling steps.", get: { $0.steps }, toValue: { .number(Double($0)) }, set: { $0.steps = Int(num($1)) }))
        list.append(video("cfgScale", .number(0...30), "Prompt guidance strength.", get: { $0.cfgScale }, toValue: { .number($0) }, set: { $0.cfgScale = num($1) }))
        list.append(video("seed", .integer(-1...2_147_483_647), "-1 picks a random seed each run.", get: { $0.seed }, toValue: { .number(Double($0)) }, set: { $0.seed = Int(num($1)) }))
        list.append(video("strength", .number(0...1), "How far a start image may change. 0.75 by default.", get: { $0.strength ?? 0.75 }, toValue: { .number($0) }, set: { $0.strength = num($1) }))
        // Sequencing and assembly
        list.append(FlowSetting(key: "frames", kinds: [.shotSequence], type: .structured("list of {\"id\": \"frame-1\", \"label\": \"Setup\", \"holdSeconds\": 2, \"transitionNote\": \"…\", \"boundary\": \"cut\" | \"continuous\"}. Each frame id becomes an image input on the node"),
                                summary: "The ordered stills. Wire an image to a frame with `sequenceNode.frameId`.",
                                get: { node in .array(node.sequence.anchors.map { a in .object(["id": .string(a.id), "label": .string(a.label), "holdSeconds": .number(a.holdSeconds), "transitionNote": .string(a.transitionNote), "boundary": .string(a.boundaryToNext.rawValue)]) }) },
                                set: { node, value in
                                    guard case .array(let items) = value else { throw FlowSettingError(message: "must be a list of frame objects.") }
                                    guard items.count <= ShotSequenceSpec.maximumAnchors else { throw FlowSettingError(message: "a Shot Sequence holds at most \(ShotSequenceSpec.maximumAnchors) frames.") }
                                    var anchors: [ShotAnchor] = []
                                    for (index, item) in items.enumerated() {
                                        guard case .object(let f) = item else { throw FlowSettingError(message: "frames[\(index)] must be an object.") }
                                        let allowed: Set<String> = ["id", "label", "holdSeconds", "transitionNote", "boundary"]
                                        if let extra = f.keys.first(where: { !allowed.contains($0) }) { throw FlowSettingError(message: "frames[\(index)] has unknown key '\(extra)'. Allowed: id, label, holdSeconds, transitionNote, boundary.") }
                                        var anchor = ShotAnchor(id: "frame-\(index + 1)", label: "Frame \(index + 1)")
                                        if case .string(let id)? = f["id"] { anchor.id = id }
                                        if case .string(let label)? = f["label"] { anchor.label = label }
                                        if case .number(let hold)? = f["holdSeconds"] { anchor.holdSeconds = hold }
                                        if case .string(let note)? = f["transitionNote"] { anchor.transitionNote = note }
                                        if case .string(let boundary)? = f["boundary"] {
                                            guard let value = ShotBoundary(rawValue: boundary) else { throw FlowSettingError(message: "frames[\(index)].boundary must be \"cut\" or \"continuous\".") }
                                            anchor.boundaryToNext = value
                                        }
                                        anchors.append(anchor)
                                    }
                                    guard Set(anchors.map(\.id)).count == anchors.count else { throw FlowSettingError(message: "frame ids must be unique.") }
                                    var spec = node.sequence; spec.anchors = anchors; node.sequence = spec
                                }))
        func sequence(_ key: String, _ type: FlowSetting.ValueType, _ summary: String, get: @escaping (ShotSequenceSpec) -> Double, set: @escaping (inout ShotSequenceSpec, Double) -> Void) -> FlowSetting {
            FlowSetting(key: key, kinds: [.shotSequence], type: type, summary: summary, get: { .number(get($0.sequence)) }, set: { node, value in var s = node.sequence; set(&s, num(value)); node.sequence = s })
        }
        list.append(sequence("finalHoldSeconds", .number(0...60), "How long the last frame stays.", get: { $0.finalHoldSeconds }, set: { $0.finalHoldSeconds = $1 }))
        list.append(sequence("fps", .integer(1...60), "Frame rate of the rendered animatic.", get: { Double($0.fps) }, set: { $0.fps = Int($1) }))
        list.append(sequence("width", .integer(64...4096), "Animatic width in pixels.", get: { Double($0.width) }, set: { $0.width = Int($1) }))
        list.append(sequence("height", .integer(64...4096), "Animatic height in pixels.", get: { Double($0.height) }, set: { $0.height = Int($1) }))
        func assembly(_ key: String, _ type: FlowSetting.ValueType, _ summary: String, get: @escaping (AssemblySettings) -> FlowValue, set: @escaping (inout AssemblySettings, FlowValue) -> Void) -> FlowSetting {
            FlowSetting(key: key, kinds: [.assembleVideo], type: type, summary: summary, get: { get($0.assembly) }, set: { node, value in var s = node.assembly; set(&s, value); node.assembly = s })
        }
        list.append(assembly("width", .integer(0...4096), "Output width. 0 matches the first clip.", get: { .number(Double($0.width)) }, set: { $0.width = Int(num($1)) }))
        list.append(assembly("height", .integer(0...4096), "Output height. 0 matches the first clip.", get: { .number(Double($0.height)) }, set: { $0.height = Int(num($1)) }))
        list.append(assembly("fps", .integer(1...60), "Output frame rate.", get: { .number(Double($0.fps)) }, set: { $0.fps = Int(num($1)) }))
        list.append(assembly("audio", .choice(AssemblyAudioPolicy.allCases.map(\.rawValue)), "Keep each clip's sound or mute it.", get: { .string($0.audio.rawValue) }, set: { $0.audio = AssemblyAudioPolicy(rawValue: str($1)) ?? $0.audio }))
        list.append(assembly("transition", .choice(AssemblyTransition.allCases.map(\.rawValue)), "Default join between clips: hard cut, cross-dissolve or dip to black.", get: { .string($0.transition.rawValue) }, set: { $0.transition = AssemblyTransition(rawValue: str($1)) ?? $0.transition }))
        list.append(assembly("framing", .choice(AssemblyFraming.allCases.map(\.rawValue)), "fit shows each whole clip with bars; fill crops edges so mixed shapes fill the frame.", get: { .string($0.framing.rawValue) }, set: { $0.framing = AssemblyFraming(rawValue: str($1)) ?? $0.framing }))
        list.append(assembly("skipRepeatedJoinFrame", .bool, "Skip each later clip's first frame when shots are frame-chained (each starts on the previous clip's last frame).", get: { .bool($0.skipRepeatedJoinFrame) }, set: { $0.skipRepeatedJoinFrame = flag($1) }))
        list.append(assembly("transitionSeconds", .number(0.2...1.5), "Length of each cross-dissolve or dip in seconds.", get: { .number($0.transitionSeconds) }, set: { $0.transitionSeconds = num($1) }))
        list.append(assembly("fadeIn", .bool, "Fade in from black at the start.", get: { .bool($0.fadeIn) }, set: { $0.fadeIn = flag($1) }))
        list.append(assembly("fadeOut", .bool, "Fade out to black at the end.", get: { .bool($0.fadeOut) }, set: { $0.fadeOut = flag($1) }))
        return list
    }()
}

// MARK: - Naming

enum FlowNaming {
    /// "Part 1" → "part-1". Used for sockets declared by label.
    static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let parts = mapped.split(separator: "-", omittingEmptySubsequences: true)
        return parts.isEmpty ? "item" : parts.joined(separator: "-")
    }
    /// Locale-independent number text: the briefing and error reports are read by an AI, never localised.
    static func plain(_ n: Double) -> String { n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n) }
    static func isValidNodeID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
