import Foundation

struct GGUFTextMetadata: Sendable {
    let architecture: String
    let chatTemplate: String
}

/// Bounded metadata inspection; never loads tensors or runs repository code.
enum GGUFTextInspector {
    static let architectures: Set<String> = ["llama", "qwen2", "qwen2moe", "qwen3", "qwen3moe", "gemma", "gemma2", "phi3"]
    static func validate(_ url: URL) throws { _ = try inspect(url) }
    static func inspect(_ url: URL) throws -> GGUFTextMetadata {
        let reader = try Reader(url)
        defer { try? reader.file.close() }
        guard try reader.read(4) == Data("GGUF".utf8), [2, 3].contains(try reader.u32()) else { throw invalid("Unsupported GGUF header.") }
        guard try reader.u64() > 0 else { throw invalid("This GGUF contains no model tensors.") }
        let count = try reader.u64()
        guard count <= 100_000 else { throw invalid("GGUF metadata exceeds the inspection limit.") }
        var architecture: String?, template: String?
        var identityKeys: Set<String> = []
        for _ in 0..<count {
            let key = try reader.string(limit: 65_536)
            let type = try reader.u32()
            if ["general.architecture", "tokenizer.chat_template", "split.count"].contains(key), !identityKeys.insert(key).inserted {
                throw invalid("Duplicate GGUF identity metadata.")
            }
            if key == "general.architecture" || key == "tokenizer.chat_template" {
                guard type == 8 else { throw invalid("The model must contain a single embedded text chat template and architecture.") }
                let value = try reader.string(limit: 1_048_576)
                if key == "general.architecture" { architecture = value } else { template = value }
            } else if key == "split.count" {
                guard type == 2 || type == 4 else { throw invalid("Invalid split model metadata.") }
                let parts = type == 2 ? UInt32(try reader.u16()) : try reader.u32()
                guard parts <= 1 else { throw invalid("Split GGUF models need a complete multi-file recipe; choose a single-file model.") }
            } else { try reader.skipValue(type) }
        }
        guard let architecture, architectures.contains(architecture) else { throw invalid("This text architecture is not enabled in GenStudio's GGUF adapter.") }
        guard let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("Choose an instruction model with an embedded chat template.") }
        return .init(architecture: architecture, chatTemplate: template)
    }
    private static func invalid(_ message: String) -> GenerationLibraryError { .invalid(message) }
    private final class Reader {
        let file: FileHandle
        private var position: UInt64 = 0
        private let size: UInt64
        init(_ url: URL) throws {
            file = try FileHandle(forReadingFrom: url)
            size = try file.seekToEnd(); try file.seek(toOffset: 0)
        }
        func read(_ count: Int) throws -> Data {
            try Task.checkCancellation()
            guard count >= 0, position + UInt64(count) <= min(size, 64 * 1024 * 1024) else { throw invalid("Truncated or oversized GGUF metadata.") }
            guard let bytes = try file.read(upToCount: count), bytes.count == count else { throw invalid("Truncated GGUF metadata.") }
            position += UInt64(count); return bytes
        }
        func u16() throws -> UInt16 { try read(2).withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } }
        func u32() throws -> UInt32 { try read(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        func u64() throws -> UInt64 { try read(8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } }
        func string(limit: UInt64) throws -> String {
            let length = try u64()
            guard length <= limit, let value = String(data: try read(Int(length)), encoding: .utf8) else { throw invalid("Invalid GGUF metadata string.") }
            return value
        }
        func skip(_ bytes: UInt64) throws {
            try Task.checkCancellation()
            guard bytes <= 64 * 1024 * 1024, position + bytes <= min(size, 64 * 1024 * 1024) else { throw invalid("Truncated or oversized GGUF metadata.") }
            position += bytes; try file.seek(toOffset: position)
        }
        func skipValue(_ type: UInt32) throws {
            switch type {
            case 0, 1, 7: try skip(1)
            case 2, 3: try skip(2)
            case 4, 5, 6: try skip(4)
            case 10, 11, 12: try skip(8)
            case 8: try skip(u64())
            case 9:
                let element = try u32(), count = try u64()
                guard count <= 2_000_000, element != 9 else { throw invalid("Unsupported GGUF metadata array.") }
                for _ in 0..<count { try skipValue(element) }
            default: throw invalid("Unknown GGUF metadata type.")
            }
        }
    }
}
