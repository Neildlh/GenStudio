import SwiftUI
import XCTest
@testable import GenStudio

@MainActor
final class PromptEditingTests: XCTestCase {
    func testReferenceMentionsOfferConnectedSocketsAndResolveTheirRunOrder() throws {
        let prompt = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0))
        let first = StudioNode(kind: .imageInput, label: "First", position: .init(x: 0, y: 200))
        let third = StudioNode(kind: .imageInput, label: "Third", position: .init(x: 0, y: 400))
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 400, y: 0))
        let project = WorkflowProject(name: "References", nodes: [prompt, first, third, generator], edges: [
            .init(sourceID: prompt.id, sourcePortID: "text", targetID: generator.id, targetPortID: "prompt", type: .text),
            .init(sourceID: first.id, sourcePortID: "image", targetID: generator.id, targetPortID: "referenceImage", type: .image),
            .init(sourceID: third.id, sourcePortID: "image", targetID: generator.id, targetPortID: "referenceImage3", type: .image)
        ])

        let mentions = ReferenceMentionCatalog.suggestions(forPromptNodeID: prompt.id, in: project)
        XCTAssertEqual(mentions.map(\.token), ["@reference 1", "@reference 3"])
        XCTAssertEqual(mentions.map(\.detail), ["Reference 1", "Reference 3 → image 2"])
        XCTAssertEqual(ReferenceMentionCatalog.inserting(mentions[0], into: "Use @ref"), "Use @reference 1 ")
        XCTAssertEqual(try ReferenceMentionCatalog.resolve("Keep @reference 3's setting.", for: generator, connectedPortIDs: ["referenceImage", "referenceImage3"]), "Keep Reference image 2's setting.")
    }

    func testReferenceMentionFailsWhenItsSocketIsNoLongerConnected() throws {
        let generator = StudioNode(kind: .imageGenerator, label: "Generator", position: .init(x: 0, y: 0))
        XCTAssertThrowsError(try ReferenceMentionCatalog.resolve("Use @reference 2.", for: generator, connectedPortIDs: ["referenceImage"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("not connected"))
        }
    }

    func testCanvasAndInspectorEditsStaySynchronizedAndPreserveGraph() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = StudioNode(kind: .prompt, label: "Campaign prompt", position: .init(x: 120, y: 80), prompt: "Original")
        let preview = StudioNode(kind: .textPreview, label: "Preview", position: .init(x: 580, y: 80))
        let other = StudioNode(kind: .prompt, label: "Other prompt", position: .init(x: 120, y: 460), prompt: "Leave this alone")
        let edge = StudioEdge(sourceID: source.id, sourcePortID: "text", targetID: preview.id, targetPortID: "text", type: .text)
        let project = WorkflowProject(name: "Prompt editing", nodes: [source, preview, other], edges: [edge])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id
        let canvas = model.promptBinding(for: source)
        let inspector = model.promptBinding(for: source)

        canvas.wrappedValue = "KEEP:\n- Product\n\nCHANGES:\n- Saturated background"
        XCTAssertEqual(inspector.wrappedValue, canvas.wrappedValue)
        inspector.wrappedValue += "\n\nAVOID:\n- Altering the label"
        XCTAssertEqual(canvas.wrappedValue, inspector.wrappedValue)
        XCTAssertTrue(canvas.wrappedValue.hasSuffix("- Altering the label"))
        let updated = try XCTUnwrap(model.currentProject)
        XCTAssertEqual(updated.nodes.map(\.position), project.nodes.map(\.position))
        XCTAssertEqual(updated.edges, project.edges)
        XCTAssertEqual(Array(updated.nodes.dropFirst()), [preview, other])
        var expectedSource = source
        expectedSource.prompt = canvas.wrappedValue
        XCTAssertEqual(updated.nodes.first, expectedSource)

        await model.flushProjectWrites()
        let restored = try await StudioPersistence(root: root).loadProjects()
        XCTAssertEqual(restored.first(where: { $0.id == project.id })?.nodes.first?.prompt, canvas.wrappedValue)
    }

    func testBindingFromPreviousWorkflowCannotReadOrOverwriteNewWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalNode = StudioNode(kind: .prompt, label: "Prompt", position: .init(x: 0, y: 0), prompt: "Original workflow")
        // Reusing a node identity makes this verify the project guard, not just a missing-node lookup.
        var secondNode = originalNode
        secondNode.prompt = "Second workflow"
        let original = WorkflowProject(name: "Original", nodes: [originalNode], edges: [])
        let second = WorkflowProject(name: "Second", nodes: [secondNode], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [original, second]; model.currentProjectID = original.id
        let stale = model.promptBinding(for: originalNode)
        model.selectProject(second.id)

        XCTAssertEqual(stale.wrappedValue, originalNode.prompt)
        stale.wrappedValue = "Late editor callback"
        XCTAssertEqual(model.currentProject?.nodes.first?.prompt, secondNode.prompt)
        XCTAssertEqual(model.projects.first(where: { $0.id == original.id })?.nodes.first?.prompt, originalNode.prompt)
        await model.flushProjectWrites()
    }

    func testBindingToRemovedNodeCannotRestoreItOrModifyAnotherNode() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = StudioNode(kind: .prompt, label: "Removed", position: .init(x: 0, y: 0), prompt: "Original text")
        let retained = StudioNode(kind: .prompt, label: "Retained", position: .init(x: 400, y: 0), prompt: "Retained text")
        let project = WorkflowProject(name: "Removal", nodes: [removed, retained], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]; model.currentProjectID = project.id
        let stale = model.promptBinding(for: removed)
        model.mutateProject { $0.nodes.removeAll(where: { $0.id == removed.id }) }

        XCTAssertEqual(stale.wrappedValue, removed.prompt)
        stale.wrappedValue = "Late editor callback"
        XCTAssertEqual(model.currentProject?.nodes, [retained])
        await model.flushProjectWrites()
    }

    func testPromptCardBindingsEditStructuredImageAndVideoDirections() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = StudioNode(kind: .imagePrompt, label: "Image Prompt", position: .init(x: 0, y: 0))
        let video = StudioNode(kind: .videoPrompt, label: "Video Prompt", position: .init(x: 400, y: 0))
        let project = WorkflowProject(name: "Direct prompt editing", nodes: [image, video], edges: [])
        let model = StudioModel(persistence: StudioPersistence(root: root), engine: StubEngine())
        model.projects = [project]
        model.currentProjectID = project.id

        model.promptBinding(for: image).wrappedValue = "A chef plates a bright summer dish while guests gather around the table"
        model.promptBinding(for: video).wrappedValue = "The chef places the final garnish, looks up, and the camera slowly reveals the guests"

        let updated = try XCTUnwrap(model.currentProject)
        XCTAssertEqual(updated.nodes[0].imagePromptSettings?.subject, "A chef plates a bright summer dish while guests gather around the table")
        XCTAssertEqual(updated.nodes[1].videoPromptSettings?.action, "The chef places the final garnish, looks up, and the camera slowly reveals the guests")
        XCTAssertTrue(updated.nodes[0].imagePromptSettings?.compiledPrompt.contains("Scene direction:") == true)
        XCTAssertTrue(updated.nodes[1].videoPromptSettings?.compiledPrompt.hasPrefix("The chef places the final garnish") == true)

        await model.flushProjectWrites()
        let reopened = try await StudioPersistence(root: root).loadProjects()
        XCTAssertEqual(reopened.first?.nodes[0].imagePromptSettings?.subject, updated.nodes[0].imagePromptSettings?.subject)
        XCTAssertEqual(reopened.first?.nodes[1].videoPromptSettings?.action, updated.nodes[1].videoPromptSettings?.action)
    }
}
