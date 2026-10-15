import Foundation

/// Disk download metadata, never an estimate of memory use or runtime compatibility.
struct ModelSizeSummary: Codable, Sendable, Equatable {
    let minBytes: Int64?
    let maxBytes: Int64?
    let label: String
    let detail: String

    var title: String {
        guard let minBytes, let maxBytes else { return "Size unavailable" }
        let low = ByteCountFormatter.string(fromByteCount: minBytes, countStyle: .file)
        let high = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
        return minBytes == maxBytes || low == high ? low : "\(low) – \(high)"
    }

    static let unavailable = ModelSizeSummary(minBytes: nil, maxBytes: nil, label: "File size", detail: "The publisher has not supplied usable model file sizes. Inspect the files for more information.")

    static func summarize(repository: String, revision: String?, files: [DiscoveryFile], recipes: [ModelRecipe] = ModelCatalog.recipes) -> ModelSizeSummary {
        // Only a complete, immutable, hash-matched component recipe is a download total.
        let packages = recipes.filter { recipe in
            !recipe.components.isEmpty && recipe.components.allSatisfy { component in
                component.repository == repository && component.revision == revision && files.contains {
                    $0.path == component.filename && $0.bytes == component.byteSize && $0.sha256 == component.sha256
                }
            }
        }.compactMap { sum($0.components.map(\.byteSize)) }
        if let minimum = packages.min(), let maximum = packages.max() {
            return .init(minBytes: minimum, maxBytes: maximum, label: "Download", detail: "Complete download\(packages.count > 1 ? "s; choose a version for its exact size" : ""), including supporting files. Installation needs temporary space too.")
        }
        let gguf = files.filter { $0.format == "gguf" && !$0.path.lowercased().contains("mmproj") }
        if !gguf.isEmpty { return fileSummary(gguf, label: "GGUF files", detail: "Individual GGUF versions or complete shard sets. Choose one version; supporting files may be extra.") }
        let weights = files.filter {
            ["safetensors", "ckpt", "pt", "pth", "onnx", "h5"].contains($0.format) ||
            ($0.format == "bin" && ["pytorch_model", "diffusion_pytorch_model", "model", "adapter_model"].contains(where: URL(fileURLWithPath: $0.path).lastPathComponent.lowercased().hasPrefix))
        }
        return fileSummary(weights, label: "Weight files", detail: "Individual weight files or complete shard sets, not complete downloads. A model may need several components and supporting files.")
    }

    private static func fileSummary(_ files: [DiscoveryFile], label: String, detail: String) -> ModelSizeSummary {
        var sizes: [Int64] = []
        var groups: [String: [(index: Int, total: Int, bytes: Int64?)]] = [:]
        var incomplete = false
        let pattern = try! NSRegularExpression(pattern: #"^(.*)-(\d{5})-of-(\d{5})(\.[^.]+)$"#)
        for file in files {
            let path = file.path as NSString
            if let match = pattern.firstMatch(in: file.path, range: NSRange(location: 0, length: path.length)),
               let index = Int(path.substring(with: match.range(at: 2))), let total = Int(path.substring(with: match.range(at: 3))) {
                let key = path.substring(with: match.range(at: 1)) + path.substring(with: match.range(at: 4))
                groups[key, default: []].append((index, total, file.bytes))
            } else if let bytes = file.bytes, bytes > 0 { sizes.append(bytes) }
            else { incomplete = true }
        }
        for group in groups.values {
            let total = group[0].total
            guard total > 0, group.count == total, group.allSatisfy({ $0.total == total && $0.index > 0 && $0.index <= total }),
                  Set(group.map(\.index)).count == total, group.allSatisfy({ ($0.bytes ?? 0) > 0 }),
                  let bytes = sum(group.compactMap(\.bytes)) else { incomplete = true; continue }
            sizes.append(bytes)
        }
        guard let minimum = sizes.min(), let maximum = sizes.max() else { return .unavailable }
        return .init(minBytes: minimum, maxBytes: maximum, label: incomplete ? "Known \(label.lowercased())" : label,
            detail: detail + (incomplete ? " Some sizes or shards are missing; the range covers only known complete files or sets." : ""))
    }

    private static func sum(_ bytes: [Int64]) -> Int64? {
        guard !bytes.isEmpty else { return nil }
        var result: Int64 = 0
        for value in bytes {
            guard value > 0 else { return nil }
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }
}
