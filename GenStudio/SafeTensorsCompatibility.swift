import Foundation

/// Repairs a stable-diffusion.cpp namespace bug without modifying or downloading the
/// installed checkpoint. The pinned runtime discards raw `vision_model.*` tensors before
/// applying its external-file `clip_vision.` prefix. A derived, app-owned cache file makes
/// that prefix explicit in the safetensors header while copying the payload byte-for-byte.
enum SafeTensorsCompatibility {
    private static let transformVersion = "sdcpp-clip-vision-prefix-v1"
    private static let chunkBytes = 8 * 1024 * 1024

    static func prepareWanClipVision(source: URL, verifiedSourceSHA256: String) throws -> URL {
        let target = source.deletingLastPathComponent()
            .appending(path: ".clipVision-\(transformVersion)-\(verifiedSourceSHA256.prefix(12)).safetensors")
        if (try? validatePrepared(target, sourceSHA256: verifiedSourceSHA256)) != nil { return target }

        if FileManager.default.fileExists(atPath: target.path) {
            // This is only a reproducible derived cache; the verified installed source is untouched.
            try FileManager.default.removeItem(at: target)
        }
        let sourceSize = try fileSize(source)
        let free = HardwareProfile.current(storageURL: source.deletingLastPathComponent()).freeDiskBytes
        guard sourceSize <= free - min(256 * 1024 * 1024, max(0, free)) else {
            throw StudioError.validation("Wan start/end video needs about \(sourceSize / 1_048_576) MB once to prepare its CLIP vision checkpoint for the bundled runtime. Free disk space and try again; the installed model was not changed.")
        }

        let parsed = try readHeader(source)
        let transformed = try transformedHeader(parsed.object, sourceSHA256: verifiedSourceSHA256)
        let paddedHeader = try paddedJSON(transformed)
        let temporary = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw StudioError.validation("Could not create the prepared Wan CLIP vision cache file.")
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        try output.write(contentsOf: littleEndianBytes(UInt64(paddedHeader.count)))
        try output.write(contentsOf: paddedHeader)
        try input.seek(toOffset: UInt64(8 + parsed.length))
        while let chunk = try input.read(upToCount: chunkBytes), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        try output.close()
        try input.close()
        try FileManager.default.moveItem(at: temporary, to: target)
        try validatePrepared(target, sourceSHA256: verifiedSourceSHA256)
        return target
    }

    private static func transformedHeader(_ root: [String: Any], sourceSHA256: String) throws -> [String: Any] {
        var result: [String: Any] = [:]
        var tensorCount = 0
        for (name, value) in root where name != "__metadata__" {
            guard name.hasPrefix("vision_model.") || name.hasPrefix("visual_projection.") || name.hasPrefix("clip_vision.") else {
                throw StudioError.validation("The installed Wan CLIP vision file has an unsupported tensor namespace: \(name). It was preserved unchanged.")
            }
            result[name.hasPrefix("clip_vision.") ? name : "clip_vision.\(name)"] = value
            tensorCount += 1
        }
        guard tensorCount > 0 else { throw StudioError.validation("The installed Wan CLIP vision file contains no model tensors.") }
        var metadata = root["__metadata__"] as? [String: String] ?? [:]
        metadata["genstudio.transform"] = transformVersion
        metadata["genstudio.source_sha256"] = sourceSHA256.lowercased()
        result["__metadata__"] = metadata
        return result
    }

    private static func validatePrepared(_ url: URL, sourceSHA256: String) throws {
        let parsed = try readHeader(url)
        let metadata = parsed.object["__metadata__"] as? [String: String]
        guard metadata?["genstudio.transform"] == transformVersion,
              metadata?["genstudio.source_sha256"] == sourceSHA256.lowercased() else {
            throw StudioError.validation("The prepared Wan CLIP vision cache does not match its installed source.")
        }
        let names = parsed.object.keys.filter { $0 != "__metadata__" }
        guard !names.isEmpty, names.allSatisfy({ $0.hasPrefix("clip_vision.") }) else {
            throw StudioError.validation("The prepared Wan CLIP vision cache has an invalid tensor namespace.")
        }
        let payloadBytes = try fileSize(url) - Int64(8 + parsed.length)
        let maximumEnd = names.compactMap { name -> Int64? in
            guard let tensor = parsed.object[name] as? [String: Any],
                  let offsets = tensor["data_offsets"] as? [NSNumber], offsets.count == 2 else { return nil }
            return offsets[1].int64Value
        }.max()
        guard maximumEnd == payloadBytes else {
            throw StudioError.validation("The prepared Wan CLIP vision cache has incomplete tensor data.")
        }
    }

    private static func readHeader(_ url: URL) throws -> (length: Int, object: [String: Any]) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw StudioError.validation("The Wan CLIP vision safetensors header is truncated.")
        }
        let length64 = prefix.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
        guard length64 > 1, length64 <= 64 * 1024 * 1024, let length = Int(exactly: length64),
              let data = try handle.read(upToCount: length), data.count == length,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudioError.validation("The Wan CLIP vision safetensors header is invalid.")
        }
        return (length, object)
    }

    private static func paddedJSON(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let padding = (8 - (data.count % 8)) % 8
        if padding > 0 { data.append(Data(repeating: 0x20, count: padding)) }
        return data
    }

    private static func littleEndianBytes(_ value: UInt64) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        guard let number = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            throw StudioError.validation("Could not read the Wan CLIP vision file size.")
        }
        return number.int64Value
    }
}
