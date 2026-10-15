import Foundation

/// A business's name, offer, contact details, colours and logo, stored once in Application Support so every
/// new End Card, caption and Start Video Ad is already branded. The logo is copied in, so moving or deleting
/// the original file does not break it.
struct BrandKit: Codable, Hashable, Sendable {
    static let fileName = "brand-kit.json"
    static let folderName = "BrandKit"

    var businessName = ""
    var offer = ""
    var contact = ""
    var website = ""
    var backgroundHex = "#111827"
    var textHex = "#FFFFFF"
    var accentHex = "#F5B700"
    /// File name inside the BrandKit folder; nil when there is no logo.
    var logoFileName: String?

    var isEmpty: Bool {
        [businessName, offer, contact, website].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && logoFileName == nil
    }

    func logoURL(root: URL) -> URL? {
        guard let logoFileName else { return nil }
        let url = root.appending(path: Self.folderName, directoryHint: .isDirectory).appending(path: logoFileName)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// Copies the chosen picture into the kit's own folder. Each adoption gets a new name, so a node that
    /// already uses the previous logo keeps its picture.
    mutating func adoptLogo(from source: URL, root: URL) throws {
        _ = try FrameSequenceEncoder.loadImage(source)
        let folder = root.appending(path: Self.folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let name = "logo-\(UUID().uuidString.prefix(8)).\(ext)"
        try FileManager.default.copyItem(at: source, to: folder.appending(path: name))
        logoFileName = name
    }

    /// Fills a card with what the kit has; an empty kit field never wipes the card's own text.
    func fill(_ card: inout EndCardSettings) {
        func use(_ value: String, _ keyPath: WritableKeyPath<EndCardSettings, String>) {
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { card[keyPath: keyPath] = value }
        }
        use(businessName, \.headline); use(offer, \.offer); use(contact, \.contact); use(website, \.website)
        if EndCardSettings.color(backgroundHex) != nil { card.backgroundHex = backgroundHex }
        if EndCardSettings.color(textHex) != nil { card.textHex = textHex }
        if EndCardSettings.color(accentHex) != nil { card.accentHex = accentHex }
    }

    /// Makes a finished card the kit (the logo is chosen separately).
    mutating func take(_ card: EndCardSettings) {
        businessName = card.headline; offer = card.offer; contact = card.contact; website = card.website
        backgroundHex = card.backgroundHex; textHex = card.textHex; accentHex = card.accentHex
    }

    static func load(root: URL) -> BrandKit {
        guard let data = try? Data(contentsOf: root.appending(path: fileName)),
              let kit = try? JSONDecoder().decode(BrandKit.self, from: data) else { return BrandKit() }
        return kit
    }

    func save(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appending(path: Self.fileName), options: .atomic)
    }
}

extension BrandKit {
    private enum CodingKeys: String, CodingKey { case businessName, offer, contact, website, backgroundHex, textHex, accentHex, logoFileName }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        businessName = try c.decodeIfPresent(String.self, forKey: .businessName) ?? ""
        offer = try c.decodeIfPresent(String.self, forKey: .offer) ?? ""
        contact = try c.decodeIfPresent(String.self, forKey: .contact) ?? ""
        website = try c.decodeIfPresent(String.self, forKey: .website) ?? ""
        backgroundHex = try c.decodeIfPresent(String.self, forKey: .backgroundHex) ?? backgroundHex
        textHex = try c.decodeIfPresent(String.self, forKey: .textHex) ?? textHex
        accentHex = try c.decodeIfPresent(String.self, forKey: .accentHex) ?? accentHex
        logoFileName = try c.decodeIfPresent(String.self, forKey: .logoFileName)
    }
}
