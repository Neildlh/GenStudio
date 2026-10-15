import XCTest
@testable import GenStudio

final class StartupMaintenanceTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "maintenance-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ path: String, in root: URL, age: TimeInterval = 0) throws -> URL {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        if age > 0 {
            let date = Date().addingTimeInterval(-age)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.deletingLastPathComponent().path)
        }
        return file
    }

    func testThePreRuntimeLibraryPythonEnvironmentIsRemoved() throws {
        let support = try root(); defer { try? FileManager.default.removeItem(at: support) }
        _ = try write("Runtime/mlx-vlm/pyvenv.cfg", in: support)
        _ = try write("Runtime/mlx-vlm/bin/python3", in: support)
        let unrelated = try write("Runtime/notes.txt", in: support)
        StartupMaintenance.removeLegacyRuntime(supportRoot: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: "Runtime/mlx-vlm").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "Only the exact legacy environment is removed")
    }

    func testAFolderThatIsNotThatEnvironmentIsLeftAlone() throws {
        let support = try root(); defer { try? FileManager.default.removeItem(at: support) }
        let file = try write("Runtime/mlx-vlm/something-else.txt", in: support)
        StartupMaintenance.removeLegacyRuntime(supportRoot: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "No pyvenv.cfg means it is not the legacy venv")
    }

    func testOnlyScratchLeftOverForADayIsSwept() throws {
        let support = try root(); defer { try? FileManager.default.removeItem(at: support) }
        let old = try write("GenerationScratch/old.png", in: support, age: 2 * 86_400)
        let oldFolder = try write("GenerationScratch/video-old/frame.png", in: support, age: 2 * 86_400)
        let recent = try write("GenerationScratch/in-progress.png", in: support, age: 600)
        StartupMaintenance.sweepScratch(supportRoot: support)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFolder.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "A recent file may belong to a run in another open GenStudio")
    }
}
