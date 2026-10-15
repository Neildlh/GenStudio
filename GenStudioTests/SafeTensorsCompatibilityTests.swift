import XCTest
@testable import GenStudio

final class SafeTensorsCompatibilityTests: XCTestCase {
    func testRealInstalledWanClipPreparationWhenOptedIn() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_REAL_WAN_CLIP_PREP"] == "1",
              let libraryPath = environment["GENSTUDIO_MODEL_LIBRARY"] else {
            throw XCTSkip("Opt in with TEST_RUNNER_RUN_REAL_WAN_CLIP_PREP=1 and TEST_RUNNER_GENSTUDIO_MODEL_LIBRARY.")
        }
        let library = ModelLibrary(root: URL(fileURLWithPath: libraryPath))
        let installed = try await library.resolveInstalledModel(id: MediaModelCatalog.wan21FLFRecipeID)
        let component = try XCTUnwrap(installed.components.first { $0.role == "clipVision" })
        let prepared = try SafeTensorsCompatibility.prepareWanClipVision(
            source: component.fileURL,
            verifiedSourceSHA256: component.source.sha256
        )
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: prepared.path))
        let preparedBytes = (try FileManager.default.attributesOfItem(atPath: prepared.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(preparedBytes, component.source.byteSize)
    }

    func testWanClipPreparationPrefixesHeaderAndPreservesPayloadAndSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipCompat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "clipVision.safetensors")
        let payload = Data([1, 2, 3, 4, 5, 6])
        let original = try fixture(payload: payload, tensorName: "vision_model.encoder.layers.0.layer_norm1.weight")
        try original.write(to: source)

        let prepared = try SafeTensorsCompatibility.prepareWanClipVision(
            source: source,
            verifiedSourceSHA256: String(repeating: "a", count: 64)
        )
        XCTAssertNotEqual(prepared, source)
        XCTAssertEqual(try Data(contentsOf: source), original, "The installed source checkpoint must remain byte-identical")
        let parsed = try parse(prepared)
        XCTAssertNotNil(parsed.header["clip_vision.vision_model.encoder.layers.0.layer_norm1.weight"])
        XCTAssertNil(parsed.header["vision_model.encoder.layers.0.layer_norm1.weight"])
        XCTAssertEqual(parsed.payload, payload)
        XCTAssertEqual(
            (parsed.header["__metadata__"] as? [String: String])?["genstudio.source_sha256"],
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            try SafeTensorsCompatibility.prepareWanClipVision(source: source, verifiedSourceSHA256: String(repeating: "a", count: 64)),
            prepared,
            "A validated prepared component should be reused"
        )
    }

    func testWanClipPreparationRejectsUnexpectedNamespaceWithoutChangingSource() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClipCompat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "clipVision.safetensors")
        let original = try fixture(payload: Data([7, 8]), tensorName: "unexpected.weight")
        try original.write(to: source)
        XCTAssertThrowsError(try SafeTensorsCompatibility.prepareWanClipVision(source: source, verifiedSourceSHA256: String(repeating: "b", count: 64)))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func fixture(payload: Data, tensorName: String) throws -> Data {
        let header: [String: Any] = [
            "__metadata__": ["format": "pt"],
            tensorName: ["dtype": "U8", "shape": [payload.count], "data_offsets": [0, payload.count]]
        ]
        var encoded = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let padding = (8 - (encoded.count % 8)) % 8
        encoded.append(Data(repeating: 0x20, count: padding))
        var length = UInt64(encoded.count).littleEndian
        var file = withUnsafeBytes(of: &length) { Data($0) }
        file.append(encoded); file.append(payload)
        return file
    }

    private func parse(_ url: URL) throws -> (header: [String: Any], payload: Data) {
        let data = try Data(contentsOf: url)
        let length = data.prefix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << UInt64($1.offset * 8)) }
        let start = 8 + Int(length)
        let header = try XCTUnwrap(try JSONSerialization.jsonObject(with: data[8..<start]) as? [String: Any])
        return (header, Data(data[start...]))
    }
}
