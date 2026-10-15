import CryptoKit
import XCTest
@testable import GenStudio

private struct TinyGGUFTransport: ModelDownloadTransport {
    let bytes: Data
    func download(from: URL, to: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        try bytes.write(to: to)
        progress(Int64(bytes.count))
    }
}

final class GGUFTextInspectorTests: XCTestCase {
    private typealias Entry = (String, UInt32, Data)
    private func integer<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    private func string(_ value: String) -> Data { integer(UInt64(value.utf8.count)) + Data(value.utf8) }
    private func metadata(_ architecture: String = "qwen2", template: String? = "{{ messages }}") -> [Entry] {
        var entries: [Entry] = [("general.architecture", 8, string(architecture))]
        if let template { entries.append(("tokenizer.chat_template", 8, string(template))) }
        return entries
    }
    /// Metadata fixture only: declared tensor count deliberately does not imply a runnable tensor payload.
    private func fixture(_ entries: [Entry], version: UInt32 = 3, tensors: UInt64 = 1) -> Data {
        var data = Data("GGUF".utf8) + integer(version) + integer(tensors) + integer(UInt64(entries.count))
        for (key, type, value) in entries { data += string(key) + integer(type) + value }
        return data
    }
    private func withFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "GGUFInspector-\(UUID()).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        try body(url)
    }

    func testValidMetadataSkipsUnrelatedArraysAndPreservesTemplate() throws {
        let tokens = integer(UInt32(8)) + integer(UInt64(3)) + string("hello") + string("🌍") + string("")
        let entries: [Entry] = [("tokenizer.ggml.tokens", 9, tokens)] + metadata()
        try withFile(fixture(entries)) { url in
            let result = try GGUFTextInspector.inspect(url)
            XCTAssertEqual(result.architecture, "qwen2")
            XCTAssertEqual(result.chatTemplate, "{{ messages }}")
        }
        try withFile(fixture(metadata("llama"), version: 2)) { try GGUFTextInspector.validate($0) }
    }

    func testMalformedAndTruncatedHeadersReject() throws {
        let valid = fixture(metadata())
        let cases = [Data(), Data("NOPE".utf8), Data(valid.prefix(12)), Data(valid.dropLast()), fixture(metadata(), version: 9), fixture(metadata(), tensors: 0)]
        for data in cases { try withFile(data) { XCTAssertThrowsError(try GGUFTextInspector.validate($0)) } }
    }

    func testUnsupportedArchitectureAndAbsentOrBlankTemplateReject() throws {
        for entries in [metadata("stable-diffusion"), metadata(template: nil), metadata(template: " \n\t"), [("general.architecture", UInt32(4), integer(UInt32(1)))] + metadata()] {
            try withFile(fixture(entries)) { XCTAssertThrowsError(try GGUFTextInspector.validate($0)) }
        }
    }

    func testSplitModelRejectionAndSinglePartAcceptance() throws {
        try withFile(fixture(metadata() + [("split.count", 2, integer(UInt16(2)))])) { XCTAssertThrowsError(try GGUFTextInspector.validate($0)) }
        try withFile(fixture(metadata() + [("split.count", 4, integer(UInt32(2)))])) { XCTAssertThrowsError(try GGUFTextInspector.validate($0)) }
        try withFile(fixture(metadata() + [("split.count", 2, integer(UInt16(1)))])) { try GGUFTextInspector.validate($0) }
    }

    func testArrayLimitsAndInspectionByteBudgetRejectBeforeLargeRead() throws {
        let excessCount = integer(UInt32(0)) + integer(UInt64(2_000_001))
        let nestedArray = integer(UInt32(9)) + integer(UInt64(1))
        for value in [excessCount, nestedArray] {
            try withFile(fixture([("tokens", 9, value)] + metadata())) { XCTAssertThrowsError(try GGUFTextInspector.validate($0)) }
        }
        // Sparse file separates the inspector's 64 MiB budget from an ordinary EOF rejection.
        let data = fixture([("oversized.ignored.string", 8, integer(UInt64(65 * 1024 * 1024)))])
        try withFile(data) { url in
            let file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: 66 * 1024 * 1024)
            try file.close()
            XCTAssertThrowsError(try GGUFTextInspector.validate(url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("oversized"))
            }
        }
    }

    func testAdmittedTextInstallRemainsUnverifiedAndReopensWithoutCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GGUFAdmission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = fixture(metadata())
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let recipe = ModelRecipe(id: "text-gguf-fixture", name: "Metadata test fixture", kind: .text, engineID: "llama.cpp", components: [.init(id: "model", role: "model", repository: "test/fixture", revision: String(repeating: "a", count: 40), filename: "fixture.gguf", byteSize: Int64(data.count), sha256: digest, license: "test")], runtimeReady: false, minimumMemoryBytes: 0)
        let library = ModelLibrary(root: root, catalog: [], transport: TinyGGUFTransport(bytes: data), diskAvailable: { _ in Int64.max })
        do { _ = try await library.install(recipe: recipe); XCTFail("Discovery recipe requires explicit admission") } catch { }
        try await library.admitTextRecipe(recipe)
        let installed = try await library.install(recipe: recipe)
        XCTAssertFalse(installed.inferenceVerified)
        XCTAssertEqual(installed.recipeSnapshot, recipe)
        let reopened = ModelLibrary(root: root, catalog: [])
        let resolved = try await reopened.resolveInstalledModel(id: installed.id)
        XCTAssertEqual(resolved.id, recipe.id)
        XCTAssertFalse(resolved.inferenceVerified)
        XCTAssertEqual(try Data(contentsOf: resolved.components[0].fileURL), data)
    }
}
