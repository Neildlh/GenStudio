import Foundation
import UniformTypeIdentifiers

/// Files dragged in from Finder. Classification is by the file's declared type
/// so the canvas only creates input nodes the graph can actually use.
enum DroppedMedia {
    static func nodeKind(for url: URL) -> NodeKind? {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .imageInput }
        if type.conforms(to: .movie) { return .videoInput }
        return nil
    }

    /// Resolves every file URL in a drop, preserving Finder's selection order,
    /// then delivers them on the main actor. Loads start immediately because the
    /// providers are only valid during the drop callback.
    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping @MainActor @Sendable ([URL]) -> Void) {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let results = DropResults(count: fileProviders.count)
        let group = DispatchGroup()
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { results.set(url, at: index) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { completion(results.urls) } }
    }
}

private final class DropResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [URL?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ url: URL, at index: Int) { lock.withLock { slots[index] = url } }
    var urls: [URL] { lock.withLock { slots.compactMap { $0 } } }
}
