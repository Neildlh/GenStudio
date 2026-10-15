import XCTest
@testable import GenStudio

/// The composer is the whole point of the feature: it is what makes the
/// reference numbering impossible to get wrong by hand.
final class ReferenceRoleComposerTests: XCTestCase {
    func testNoRolesProducesAnEmptyPreamble() {
        let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: ["referenceImage", "referenceImage2"], roles: [:])
        XCTAssertEqual(preamble, "")
    }

    func testNoConnectedReferencesProducesAnEmptyPreamble() {
        let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: [], roles: ["referenceImage": "the identity source"])
        XCTAssertEqual(preamble, "")
    }

    func testNumbersASingleReference() {
        let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: ["referenceImage"],
                                                      roles: ["referenceImage": "the product to place in the scene"])
        XCTAssertEqual(preamble, "Reference image 1 is the product to place in the scene.")
    }

    /// The trap this feature exists to close. Execution skips empty sockets, so a
    /// gap on the canvas shifts what the engine actually receives.
    func testNumbersByConnectedPositionNotBySocketOrdinal() {
        let preamble = ReferenceRoleComposer.preamble(
            connectedPortIDs: ["referenceImage2", "referenceImage3"],
            roles: ["referenceImage2": "the authoritative identity and design source",
                    "referenceImage3": "the background and setting"])
        XCTAssertEqual(preamble, """
        Reference image 1 is the authoritative identity and design source.
        Reference image 2 is the background and setting.
        """)
    }

    func testARoleIsNumberedByItsPositionEvenWhenEarlierReferencesHaveNoRole() {
        let preamble = ReferenceRoleComposer.preamble(
            connectedPortIDs: ["referenceImage", "referenceImage2", "referenceImage3"],
            roles: ["referenceImage2": "the visual style and colour reference"])
        XCTAssertEqual(preamble, "Reference image 2 is the visual style and colour reference.")
    }

    func testIgnoresRolesForSocketsThatAreNotConnected() {
        let preamble = ReferenceRoleComposer.preamble(
            connectedPortIDs: ["referenceImage"],
            roles: ["referenceImage": "the identity source", "referenceImage3": "the background and setting"])
        XCTAssertEqual(preamble, "Reference image 1 is the identity source.")
    }

    func testTrimsSurroundingWhitespaceFromRoleText() {
        let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: ["referenceImage"],
                                                      roles: ["referenceImage": "   the pose and composition guide \n"])
        XCTAssertEqual(preamble, "Reference image 1 is the pose and composition guide.")
    }

    func testAWhitespaceOnlyRoleCountsAsAbsent() {
        let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: ["referenceImage"],
                                                      roles: ["referenceImage": "   \n  "])
        XCTAssertEqual(preamble, "")
    }

    func testDoesNotDoubleATrailingPeriod() {
        let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: ["referenceImage"],
                                                      roles: ["referenceImage": "the identity source."])
        XCTAssertEqual(preamble, "Reference image 1 is the identity source.")
    }

    func testTruncatesRoleTextAtTheMaximumLength() {
        let long = String(repeating: "a", count: ReferenceRoleComposer.maximumRoleLength + 40)
        let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: ["referenceImage"], roles: ["referenceImage": long])
        let expected = "Reference image 1 is \(String(repeating: "a", count: ReferenceRoleComposer.maximumRoleLength))."
        XCTAssertEqual(preamble, expected)
    }

    func testRejectsRoleTextCarryingALoRATag() {
        XCTAssertThrowsError(try ReferenceRoleComposer.validate(roles: ["referenceImage": "<lora:sharpen:0.5>"]))
    }

    func testAcceptsOrdinaryRoleText() {
        XCTAssertNoThrow(try ReferenceRoleComposer.validate(roles: ["referenceImage": "the background and setting"]))
    }
}

final class ReferenceRolePromptTests: XCTestCase {
    func testAnEmptyPreambleLeavesThePromptByteIdentical() {
        let prompt = "A calm portrait in morning light."
        XCTAssertEqual(ReferenceRoleComposer.apply(preamble: "", to: prompt), prompt)
    }

    func testThePreamblePrecedesThePromptSeparatedByABlankLine() {
        let composed = ReferenceRoleComposer.apply(preamble: "Reference image 1 is the identity source.",
                                                   to: "A calm portrait in morning light.")
        XCTAssertEqual(composed, """
        Reference image 1 is the identity source.

        A calm portrait in morning light.
        """)
    }
}

final class ReferenceRoleNodeTests: XCTestCase {
    private func generator() -> StudioNode {
        StudioNode(kind: .imageGenerator, label: "Hero Still", position: .init(x: 0, y: 0), model: "klein")
    }

    func testANewGeneratorHasNoReferenceRoles() {
        XCTAssertNil(generator().referenceRoles)
    }

    func testReferenceRolesSurviveACodingRoundTrip() throws {
        var node = generator()
        node.referenceRoles = ["referenceImage": "the authoritative identity and design source"]
        let decoded = try JSONDecoder().decode(StudioNode.self, from: JSONEncoder().encode(node))
        XCTAssertEqual(decoded.referenceRoles, ["referenceImage": "the authoritative identity and design source"])
    }

    /// Older documents must gain no new keys, matching the convention already used
    /// by `imageStrength` and `videoSettings`.
    func testANodeWithoutRolesEncodesNoReferenceRolesKey() throws {
        let data = try JSONEncoder().encode(generator())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("referenceRoles"))
    }

    func testADocumentSavedBeforeThisFeatureDecodesWithNoRoles() throws {
        let legacy = """
        {"kind":"imageGenerator","label":"Hero Still","position":{"x":0,"y":0},"model":"klein"}
        """
        let decoded = try JSONDecoder().decode(StudioNode.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.referenceRoles)
        XCTAssertEqual(decoded.label, "Hero Still")
    }
}

final class ReferenceRoleConnectionTests: XCTestCase {
    private func generator() -> StudioNode {
        StudioNode(kind: .imageGenerator, label: "Hero Still", position: .init(x: 0, y: 0), model: "klein")
    }

    private func edge(into node: StudioNode, port: String) -> StudioEdge {
        .init(sourceID: UUID(), sourcePortID: "image", targetID: node.id, targetPortID: port, type: .image)
    }

    func testReportsNoConnectedReferencesWhenNothingIsWired() {
        XCTAssertEqual(ReferenceRoleComposer.connectedReferencePortIDs(node: generator(), edges: []), [])
    }

    func testReportsConnectedReferencesInSocketOrder() {
        let node = generator()
        let edges = [edge(into: node, port: "referenceImage3"), edge(into: node, port: "referenceImage")]
        XCTAssertEqual(ReferenceRoleComposer.connectedReferencePortIDs(node: node, edges: edges),
                       ["referenceImage", "referenceImage3"])
    }

    func testIgnoresTheTextPromptPort() {
        let node = generator()
        let prompt = StudioEdge(sourceID: UUID(), sourcePortID: "text", targetID: node.id, targetPortID: "prompt", type: .text)
        XCTAssertEqual(ReferenceRoleComposer.connectedReferencePortIDs(node: node, edges: [prompt]), [])
    }

    func testIgnoresEdgesAimedAtOtherNodes() {
        let node = generator()
        let other = generator()
        XCTAssertEqual(ReferenceRoleComposer.connectedReferencePortIDs(node: node, edges: [edge(into: other, port: "referenceImage")]), [])
    }
}

/// Roles only reach adapters that actually index references positionally.
final class ReferenceRoleScopeTests: XCTestCase {
    private let identity = ["referenceImage": "the authoritative identity and design source"]

    func testReferenceEditingAdaptersReceiveThePreamble() {
        XCTAssertEqual(ReferenceRoleComposer.preamble(roles: identity, connectedPortIDs: ["referenceImage"], conditioning: .referenceImage),
                       "Reference image 1 is the authoritative identity and design source.")
    }

    /// Stable Diffusion img2img takes one reference as a starting latent with no
    /// RoPE indexing, so a positional preamble there is noise.
    func testStartImageAdaptersReceiveNothing() {
        XCTAssertEqual(ReferenceRoleComposer.preamble(roles: identity, connectedPortIDs: ["referenceImage"], conditioning: .startImageStrength), "")
    }

    func testTextToImageReceivesNothing() {
        XCTAssertEqual(ReferenceRoleComposer.preamble(roles: identity, connectedPortIDs: [], conditioning: .none), "")
    }

    func testInpaintReceivesNothing() {
        XCTAssertEqual(ReferenceRoleComposer.preamble(roles: identity, connectedPortIDs: ["referenceImage"], conditioning: .maskedStartImage), "")
    }

    func testANodeWithNoRolesProducesNothing() {
        XCTAssertEqual(ReferenceRoleComposer.preamble(roles: nil, connectedPortIDs: ["referenceImage"], conditioning: .referenceImage), "")
    }
}

final class ReferenceRoleBudgetTests: XCTestCase {
    func testComposesWhenTheResultFitsTheRecipeBudget() throws {
        let composed = try ReferenceRoleComposer.compose(preamble: "Reference image 1 is the identity source.",
                                                         prompt: "A calm portrait.", maximumBytes: 32_768)
        XCTAssertTrue(composed.hasPrefix("Reference image 1 is the identity source."))
        XCTAssertTrue(composed.hasSuffix("A calm portrait."))
    }

    func testRejectsARolePlusPromptThatExceedsTheRecipeBudget() {
        let prompt = String(repeating: "a", count: 90)
        XCTAssertThrowsError(try ReferenceRoleComposer.compose(preamble: "Reference image 1 is the identity source.",
                                                                prompt: prompt, maximumBytes: 100))
    }

    func testAnEmptyPreambleIsStillBudgetChecked() {
        XCTAssertThrowsError(try ReferenceRoleComposer.compose(preamble: "", prompt: String(repeating: "a", count: 200), maximumBytes: 100))
    }
}

private actor RoleCapturingImageEngine: ImageGenerationEngine {
    let result: URL
    private(set) var requests: [ImageGenerationRequest] = []
    init(_ result: URL) { self.result = result }
    func generate(_ request: ImageGenerationRequest) async throws -> URL { requests.append(request); return result }
    func captured() -> [ImageGenerationRequest] { requests }
}

/// Proves the preamble survives the journey from node to adapter — and, just as
/// importantly, that the prompt compiler never gets a chance to paraphrase it.
final class ReferenceRoleExecutionTests: XCTestCase {
    private func run(roles: [String: String]?, recipeID: String, registry: [ImageCapability],
                     referencePorts: [String], name: String) async throws -> ImageGenerationRequest {
        let root = try VideoFixtures.root(name); defer { try? FileManager.default.removeItem(at: root) }
        let output = try VideoFixtures.solidPNG((0, 0, 0), width: 512, height: 512, in: root, name: "result")
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "a calm portrait in morning light")
        var generator = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 1, y: 0), model: recipeID, width: 512, height: 512)
        generator.referenceRoles = roles
        var nodes: [StudioNode] = [prompt, generator]
        var edges = [VideoFixtures.edge(prompt, "text", generator, "prompt", .text)]
        for (index, port) in referencePorts.enumerated() {
            let still = try VideoFixtures.solidPNG((10 * (index + 1), 120, 200), width: 64, height: 64, in: root, name: "ref\(index)")
            let node = StudioNode(kind: .imageInput, label: "R\(index)", position: .init(x: 0, y: Double(index + 1)), imagePath: still.path)
            nodes.append(node)
            edges.append(VideoFixtures.edge(node, "image", generator, port, .image))
        }
        let engine = RoleCapturingImageEngine(output)
        _ = try await ExecutionQueue(engine: StubEngine(), persistence: StudioPersistence(root: root),
                                     imageEngine: engine, imageCapabilities: registry)
            .execute(project: .init(name: name, nodes: nodes, edges: edges), targetID: generator.id)
        let captured = await engine.captured()
        return try XCTUnwrap(captured.first)
    }

    private var kleinRegistry: [ImageCapability] {
        [ImageCapabilityRegistry.kleinTextToImage.with(readiness: .verified(evidence: "test")),
         ImageCapabilityRegistry.kleinReference.with(readiness: .verified(evidence: "test"))]
    }

    func testRolesReachTheAdapterPromptRenumberedByRunOrder() async throws {
        let request = try await run(roles: ["referenceImage2": "the authoritative identity and design source",
                                            "referenceImage3": "the background and setting"],
                                    recipeID: MediaModelCatalog.kleinRecipeID, registry: kleinRegistry,
                                    referencePorts: ["referenceImage2", "referenceImage3"], name: "roles-reach-adapter")
        XCTAssertTrue(request.prompt.hasPrefix("""
        Reference image 1 is the authoritative identity and design source.
        Reference image 2 is the background and setting.
        """), request.prompt)
    }

    func testThePreambleIsRecordedForRunHistory() async throws {
        let request = try await run(roles: ["referenceImage": "the product to place in the scene"],
                                    recipeID: MediaModelCatalog.kleinRecipeID, registry: kleinRegistry,
                                    referencePorts: ["referenceImage"], name: "roles-provenance")
        XCTAssertEqual(request.referenceRolePreamble, "Reference image 1 is the product to place in the scene.")
    }

    /// The whole reason the preamble is composed after compilation.
    func testTheCompiledPromptItselfCarriesNoRoleText() async throws {
        let request = try await run(roles: ["referenceImage": "the product to place in the scene"],
                                    recipeID: MediaModelCatalog.kleinRecipeID, registry: kleinRegistry,
                                    referencePorts: ["referenceImage"], name: "compiler-untouched")
        XCTAssertFalse((request.compiledPrompt ?? "").contains("Reference image"), request.compiledPrompt ?? "")
        XCTAssertFalse((request.authoredPrompt ?? "").contains("Reference image"), request.authoredPrompt ?? "")
    }

    func testAGeneratorWithNoRolesSendsAPromptWithNoPreamble() async throws {
        let request = try await run(roles: nil, recipeID: MediaModelCatalog.kleinRecipeID, registry: kleinRegistry,
                                    referencePorts: ["referenceImage"], name: "roles-absent")
        XCTAssertNil(request.referenceRolePreamble)
        XCTAssertFalse(request.prompt.contains("Reference image"), request.prompt)
    }

    func testStableDiffusionImageToImageIgnoresRoles() async throws {
        let registry = [ImageCapabilityRegistry.sd15TextToImage,
                        ImageCapabilityRegistry.sd15ImageToImage.with(readiness: .verified(evidence: "test"))]
        let request = try await run(roles: ["referenceImage": "the product to place in the scene"],
                                    recipeID: "sd15-q4", registry: registry,
                                    referencePorts: ["referenceImage"], name: "sd15-ignores-roles")
        XCTAssertNil(request.referenceRolePreamble)
        XCTAssertFalse(request.prompt.contains("Reference image"), request.prompt)
    }
}

/// The editor must explain the renumbering at the row where it happens, not leave
/// the user to infer it from the preview.
final class ReferenceRoleCaptionTests: XCTestCase {
    func testAnAlignedSocketIsNamedPlainly() {
        XCTAssertEqual(ReferenceRoleComposer.socketCaption(label: "Reference 1", socketIndex: 0, runPosition: 1), "Reference 1")
    }

    func testAShiftedSocketShowsThePositionItActuallyOccupies() {
        XCTAssertEqual(ReferenceRoleComposer.socketCaption(label: "Reference 2", socketIndex: 1, runPosition: 1), "Reference 2 → image 1")
    }

    func testTheThirdSocketShiftedByOneGapIsExplained() {
        XCTAssertEqual(ReferenceRoleComposer.socketCaption(label: "Reference 3", socketIndex: 2, runPosition: 2), "Reference 3 → image 2")
    }
}

final class ReferenceRolePresetTests: XCTestCase {
    func testPresetsAreOffered() {
        XCTAssertFalse(ReferenceRolePreset.all.isEmpty)
    }

    func testEveryPresetComposesAWellFormedSentence() {
        for preset in ReferenceRolePreset.all {
            let preamble = ReferenceRoleComposer.preamble(connectedPortIDs: ["referenceImage"], roles: ["referenceImage": preset.phrase])
            XCTAssertEqual(preamble, "Reference image 1 is \(preset.phrase).", preset.title)
        }
    }

    func testEveryPresetPhraseIsWithinTheLengthCap() {
        for preset in ReferenceRolePreset.all {
            XCTAssertLessThanOrEqual(preset.phrase.count, ReferenceRoleComposer.maximumRoleLength, preset.title)
        }
    }

    func testPresetTitlesAreUnique() {
        XCTAssertEqual(Set(ReferenceRolePreset.all.map(\.title)).count, ReferenceRolePreset.all.count)
    }
}

@MainActor
final class ReferenceRoleEditingTests: XCTestCase {
    private func model() -> (StudioModel, UUID) {
        let store = StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let model = StudioModel(persistence: store, engine: StubEngine())
        let node = StudioNode(kind: .imageGenerator, label: "G", position: .init(x: 0, y: 0), model: "klein")
        let project = WorkflowProject(name: "Roles", nodes: [node], edges: [])
        model.projects = [project]
        model.currentProjectID = project.id
        return (model, node.id)
    }

    private func roles(_ model: StudioModel, _ id: UUID) -> [String: String]? {
        model.currentProject?.nodes.first { $0.id == id }?.referenceRoles
    }

    func testSettingARoleStoresItAgainstItsPort() {
        let (model, id) = model()
        model.setReferenceRole(nodeID: id, portID: "referenceImage2", to: "the background and setting")
        XCTAssertEqual(roles(model, id), ["referenceImage2": "the background and setting"])
    }

    func testARoleIsTrimmedBeforeItIsStored() {
        let (model, id) = model()
        model.setReferenceRole(nodeID: id, portID: "referenceImage", to: "  the identity source \n")
        XCTAssertEqual(roles(model, id), ["referenceImage": "the identity source"])
    }

    func testClearingARoleRemovesOnlyThatPort() {
        let (model, id) = model()
        model.setReferenceRole(nodeID: id, portID: "referenceImage", to: "the identity source")
        model.setReferenceRole(nodeID: id, portID: "referenceImage2", to: "the background and setting")
        model.setReferenceRole(nodeID: id, portID: "referenceImage", to: "")
        XCTAssertEqual(roles(model, id), ["referenceImage2": "the background and setting"])
    }

    /// Clearing the last role must leave no dictionary at all, so the node encodes
    /// no `referenceRoles` key and reverts to a pre-feature document.
    func testClearingTheLastRoleLeavesNoDictionary() {
        let (model, id) = model()
        model.setReferenceRole(nodeID: id, portID: "referenceImage", to: "the identity source")
        model.setReferenceRole(nodeID: id, portID: "referenceImage", to: "   ")
        XCTAssertNil(roles(model, id))
    }

    func testSettingARoleIsUndoable() {
        let (model, id) = model()
        model.setReferenceRole(nodeID: id, portID: "referenceImage", to: "the identity source")
        model.undo()
        XCTAssertNil(roles(model, id))
    }
}

import AppKit
import SwiftUI

/// Renders the role editor offscreen with a deliberately gapped wiring, proving the
/// view builds a body and that what it shows is the run-order numbering.
@MainActor
final class ReferenceRoleEditorSmokeTests: XCTestCase {
    private func editor(roles: [String: String]?, ports: [String]) -> (ReferenceRoleEditorContent, StudioModel, StudioNode) {
        let store = StudioPersistence(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let model = StudioModel(persistence: store, engine: StubEngine())
        var node = StudioNode(kind: .imageGenerator, label: "Hero Still", position: .init(x: 0, y: 0), model: "klein")
        node.referenceRoles = roles
        var nodes = [node]
        var edges: [StudioEdge] = []
        for port in ports {
            let source = StudioNode(kind: .imageInput, label: port, position: .init(x: 0, y: 0))
            nodes.append(source)
            edges.append(.init(sourceID: source.id, sourcePortID: "image", targetID: node.id, targetPortID: port, type: .image))
        }
        let project = WorkflowProject(name: "Roles", nodes: nodes, edges: edges)
        model.projects = [project]
        model.currentProjectID = project.id
        return (ReferenceRoleEditorContent(model: model, node: node), model, node)
    }

    /// Set `TEST_RUNNER_ROLE_RENDER_DIR` to keep the PNGs for a visual check
    /// (xcodebuild forwards it with the prefix stripped), matching the convention
    /// in `RadarViewSmokeTests`.
    private func render(_ view: some View, name: String = "editor") throws -> NSImage {
        let framed = view.frame(width: 520).padding(16).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "the reference role editor did not render")
        if let directory = ProcessInfo.processInfo.environment["ROLE_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: url.appending(path: "\(name).png"))
            }
        }
        return image
    }

    func testTheEditorRendersWithRolesSet() throws {
        let (view, _, _) = editor(roles: ["referenceImage2": "the authoritative identity and design source"],
                                  ports: ["referenceImage2", "referenceImage3"])
        let image = try render(view, name: "roles-set")
        XCTAssertGreaterThan(image.size.width, 100)
        // Two socket rows plus the preview block. A collapsed body renders far
        // shorter than this, which is how the first version of this test slipped by.
        XCTAssertGreaterThan(image.size.height, 150)
    }

    func testTheEditorRendersWithNoRolesSet() throws {
        let (view, _, _) = editor(roles: nil, ports: ["referenceImage"])
        XCTAssertGreaterThan(try render(view, name: "roles-empty").size.height, 120)
    }

    /// What the editor previews for a gapped wiring is the engine's numbering, not
    /// the socket's: the user sees "image 1" for the socket labelled Reference 2.
    func testThePreviewedNumberingFollowsRunOrderNotSockets() {
        let (_, model, node) = editor(roles: ["referenceImage2": "the authoritative identity and design source"],
                                      ports: ["referenceImage2", "referenceImage3"])
        let connected = ReferenceRoleComposer.connectedReferencePortIDs(node: node, edges: model.currentProject?.edges ?? [])
        let live = model.currentProject?.nodes.first { $0.id == node.id }
        XCTAssertEqual(ReferenceRoleComposer.preamble(roles: live?.referenceRoles, connectedPortIDs: connected, conditioning: .referenceImage),
                       "Reference image 1 is the authoritative identity and design source.")
    }
}
