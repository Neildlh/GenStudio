import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

actor ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private var cache: [String: Data] = [:]
    private var order: [String] = []

    func thumbnail(_ url: URL) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = "\(url.path)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(attributes.fileSize ?? 0)"
        if let existing = cache[key] { return existing }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw StudioError.validation("Image cannot be decoded.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw StudioError.validation("Image preview unavailable.") }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw StudioError.validation("Image preview unavailable.") }
        let encoded = data as Data
        cache[key] = encoded; order.append(key)
        if order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }
        return encoded
    }
}

struct LocalImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .accessibilityLabel("Image preview: \(url.lastPathComponent)")
            } else if failed {
                Label("Image missing or unreadable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            } else { StudioSpinner() }
        }
        .task(id: url) {
            image = nil; failed = false
            do {
                let data = try await ImageThumbnailCache.shared.thumbnail(url)
                try Task.checkCancellation()
                image = NSImage(data: data); failed = image == nil
            } catch is CancellationError { }
            catch { failed = true }
        }
    }
}
