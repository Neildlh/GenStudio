import XCTest
@testable import GenStudio

/// Verifying a multi-gigabyte model file costs ~1.7 GB/s of SHA-256 on the reference Mac (about 15 s for
/// LTX-2.3). A file that has not changed since it was verified is trusted across launches by the same
/// identity the in-session check already uses (path, size, file number, modification time); any change
/// to that identity is hashed again.
final class ModelVerificationMemoryTests: XCTestCase {
    func testAVerifiedFileIsNotHashedAgainAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "verify-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        _ = try await library.resolveInstalledModel(id: recipe.id)
        let firstLaunchHashes = await library.hashedComponentCount
        XCTAssertEqual(firstLaunchHashes, 1)

        let relaunched = ModelLibrary(root: root.appending(path: "ModelLibrary"), catalog: [recipe], diskAvailable: { _ in Int64.max })
        _ = try await relaunched.resolveInstalledModel(id: recipe.id)
        let secondLaunchHashes = await relaunched.hashedComponentCount
        XCTAssertEqual(secondLaunchHashes, 0, "An unchanged, already verified file is trusted on the next launch")
    }

    func testAFileChangedSinceVerificationIsHashedAgainAndRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "verify-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        let installed = try await library.resolveInstalledModel(id: recipe.id)
        let file = installed.components[0].fileURL
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)

        let relaunched = ModelLibrary(root: root.appending(path: "ModelLibrary"), catalog: [recipe], diskAvailable: { _ in Int64.max })
        do {
            _ = try await relaunched.resolveInstalledModel(id: recipe.id)
            XCTFail("A changed file must be hashed again and fail its pinned checksum")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Checksum mismatch"), error.localizedDescription)
        }
        let hashes = await relaunched.hashedComponentCount
        XCTAssertEqual(hashes, 1)
    }

    func testAnUnreadableVerificationRecordOnlyCostsARehash() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "verify-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, recipe) = try await UpscaleFixtures.installedLibrary(root: root)
        _ = try await library.resolveInstalledModel(id: recipe.id)
        try Data("not json".utf8).write(to: root.appending(path: "ModelLibrary/verified-components.json"))

        let relaunched = ModelLibrary(root: root.appending(path: "ModelLibrary"), catalog: [recipe], diskAvailable: { _ in Int64.max })
        _ = try await relaunched.resolveInstalledModel(id: recipe.id)
        let hashes = await relaunched.hashedComponentCount
        XCTAssertEqual(hashes, 1, "A damaged record never blocks a run; the file is simply verified again")
    }
}
