import XCTest
@testable import GenStudio

final class ImagePromptNodeTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "GenStudioImagePromptTests-\(UUID().uuidString)") }

    func testStructuredBriefCompilesIntoAUsefulImagePrompt() {
        var settings = ImagePromptSettings()
        settings.subject = "a woman in an olive overshirt standing in a bright studio"
        settings.composition = "Full body"
        settings.lighting = "Studio softbox"
        settings.visualLook = "Luxury editorial"
        settings.aspectRatio = "3:4 portrait"

        let prompt = settings.compiledPrompt
        XCTAssertTrue(prompt.contains("a woman in an olive overshirt"))
        XCTAssertTrue(prompt.contains("Full body"))
        XCTAssertTrue(prompt.contains("Studio softbox"))
        XCTAssertTrue(prompt.contains("Luxury editorial"))
        XCTAssertTrue(prompt.contains("3:4 portrait"))
    }

    func testImagePromptPersistsAndEmitsText() async throws {
        let temp = root()
        defer { try? FileManager.default.removeItem(at: temp) }
        var node = StudioNode(kind: .imagePrompt, label: "Brief", position: .init(x: 0, y: 0))
        node.imagePromptSettings?.subject = "a red leather chair in a quiet reading room"
        let project = WorkflowProject(name: "prompt", nodes: [node], edges: [])
        let store = StudioPersistence(root: temp)
        try await store.saveProject(project)

        let reopenedProjects = try await store.loadProjects()
        let reopened = try XCTUnwrap(reopenedProjects.first)
        XCTAssertEqual(reopened.nodes[0].imagePromptSettings?.subject, "a red leather chair in a quiet reading room")
        let result = try await ExecutionQueue(engine: StubEngine(), persistence: store).execute(project: reopened, targetID: reopened.nodes[0].id)
        guard case .text(let output)? = result.values[.init(nodeID: reopened.nodes[0].id, portID: "text")] else {
            return XCTFail("Image Prompt should emit text")
        }
        XCTAssertTrue(output.contains("red leather chair"))
    }
}
