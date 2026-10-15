import Foundation

public struct GGUFMetadata: Sendable, Equatable {
    public let version: UInt32
    public let architecture: String
}

public enum GGUFParser {
    private static let maximumMetadataBytes: UInt64 = 16 * 1_024 * 1_024
    private static let maximumEntries: UInt64 = 100_000
    private static let supportedArchitectures = ["qwen2", "qwen3moe"]

    public static func parse(url: URL) throws -> GGUFMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reader = Reader(handle: handle)
        guard try reader.read(count: 4) == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw ModelLibraryError.invalidGGUF("missing GGUF magic")
        }
        let version: UInt32 = try reader.integer()
        guard version == 2 || version == 3 else { throw ModelLibraryError.unsupportedGGUFVersion(version) }
        _ = try reader.integer() as UInt64
        let count: UInt64 = try reader.integer()
        guard count <= maximumEntries else { throw ModelLibraryError.invalidGGUF("metadata entry limit exceeded") }
        for _ in 0..<count {
            let key = try reader.string()
            let type: UInt32 = try reader.integer()
            if key == "general.architecture" {
                guard type == 8 else { throw ModelLibraryError.invalidGGUF("architecture is not a string") }
                let architecture = try reader.string()
                guard !architecture.isEmpty else { throw ModelLibraryError.invalidGGUF("empty general.architecture") }
                guard supportedArchitectures.contains(architecture) else {
                    throw ModelLibraryError.unsupportedFile("architecture \(architecture) is not verified for llama.cpp 7100")
                }
                return GGUFMetadata(version: version, architecture: architecture)
            } else {
                try reader.skipValue(type: type, depth: 0)
            }
            guard reader.offset <= maximumMetadataBytes else { throw ModelLibraryError.invalidGGUF("metadata byte limit exceeded") }
        }
        throw ModelLibraryError.invalidGGUF("missing general.architecture")
    }

    private struct Reader {
        let handle: FileHandle
        var offset: UInt64 = 0

        mutating func read(count: Int) throws -> Data {
            guard count >= 0, count <= Int(GGUFParser.maximumMetadataBytes) else { throw ModelLibraryError.invalidGGUF("invalid field size") }
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ModelLibraryError.invalidGGUF("truncated header") }
            offset += UInt64(count)
            return data
        }

        mutating func integer<T: FixedWidthInteger>() throws -> T {
            let data = try read(count: MemoryLayout<T>.size)
            return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }

        mutating func string() throws -> String {
            let length: UInt64 = try integer()
            guard length <= GGUFParser.maximumMetadataBytes, length <= UInt64(Int.max) else { throw ModelLibraryError.invalidGGUF("string too large") }
            guard let value = String(data: try read(count: Int(length)), encoding: .utf8) else { throw ModelLibraryError.invalidGGUF("invalid UTF-8") }
            return value
        }

        mutating func skipValue(type: UInt32, depth: Int) throws {
            guard depth < 8 else { throw ModelLibraryError.invalidGGUF("array nesting limit exceeded") }
            switch type {
            case 0, 1, 7: _ = try read(count: 1)
            case 2, 3: _ = try read(count: 2)
            case 4, 5, 6: _ = try read(count: 4)
            case 8: _ = try string()
            case 9:
                let elementType: UInt32 = try integer()
                let count: UInt64 = try integer()
                guard count <= GGUFParser.maximumEntries else { throw ModelLibraryError.invalidGGUF("array too large") }
                for _ in 0..<count { try skipValue(type: elementType, depth: depth + 1) }
            case 10, 11, 12: _ = try read(count: 8)
            default: throw ModelLibraryError.invalidGGUF("unknown metadata type \(type)")
            }
        }
    }
}
