import XCTest
@testable import GenStudio

final class FlowRecipeTests: XCTestCase {
    private func recipe(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> FlowRecipe {
        switch FlowDocumentParser.parse(json) {
        case .success(.recipe(let recipe)): return recipe
        case .success: XCTFail("Parsed as a backup, not a recipe", file: file, line: line); throw CancellationError()
        case .failure(let failure): XCTFail(failure.message, file: file, line: line); throw CancellationError()
        }
    }
    private let compiler = FlowRecipeCompiler()

    // MARK: Catalog

    /// A default that lies outside its own declared range would make every exported recipe unimportable.
    func testEverySettingsDefaultIsValidAndSettable() {
        for kind in NodeKind.allCases {
            let node = StudioNode(kind: kind, label: kind.title, position: .init(x: 0, y: 0))
            for setting in FlowSettingCatalog.settings(for: kind) {
                let value = setting.get(node)
                XCTAssertNil(FlowRecipeCompiler.check(value, against: setting.type), "\(kind.rawValue).\(setting.key) default \(value) violates \(setting.type.summary)")
                var copy = node
                XCTAssertNoThrow(try setting.set(&copy, value), "\(kind.rawValue).\(setting.key)")
            }
        }
    }

    func testSettingKeysAreUniquePerKind() {
        for kind in NodeKind.allCases {
            let keys = FlowSettingCatalog.settings(for: kind).map(\.key)
            XCTAssertEqual(keys.count, Set(keys).count, "\(kind.rawValue) has a duplicate setting key")
        }
    }

    func testEveryKindCompilesOnItsOwn() throws {
        for kind in NodeKind.allCases {
            let result = compiler.compile(FlowRecipe(name: "t", nodes: [.init(id: "n", kind: kind.rawValue)], wires: []))
            XCTAssertTrue(result.errors.isEmpty, "\(kind.rawValue): \(result.report())")
            XCTAssertEqual(result.project?.nodes.count, 1)
        }
    }

    // MARK: Examples in the briefing

    func testEveryBriefingExampleImportsWithoutErrors() throws {
        XCTAssertFalse(FlowBriefing.examples.isEmpty)
        for example in FlowBriefing.examples {
            let result = compiler.compile(try recipe(example.json))
            XCTAssertTrue(result.errors.isEmpty, "\(example.title): \(result.report())")
            let project = try XCTUnwrap(result.project, example.title)
            XCTAssertFalse(project.edges.isEmpty, example.title)
            XCTAssertEqual(Set(project.nodes.map(\.position.x)).count > 1, true, "\(example.title) was not laid out")
        }
    }

    func testEveryNodeKindIsCoveredBySomeExampleOrReferenceEntry() {
        let reference = FlowBriefing.nodeReference()
        for kind in NodeKind.allCases { XCTAssertTrue(reference.contains("`\(kind.rawValue)`"), "\(kind.rawValue) missing from the reference") }
    }

    /// The checked-in briefing is what the user gives their AI. It must always match the code.
    /// Regenerate with: GENSTUDIO_WRITE_BRIEFING=1 xcodebuild test -only-testing GenStudioTests/FlowRecipeTests/testCheckedInBriefingIsCurrent
    func testCheckedInBriefingIsCurrent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appending(path: "docs/ai-authoring/\(FlowBriefing.fileName)")
        let current = FlowBriefing.markdown()
        if ProcessInfo.processInfo.environment["GENSTUDIO_WRITE_BRIEFING"] == "1" {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try current.write(to: file, atomically: true, encoding: .utf8)
        }
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(saved, current, "docs/ai-authoring/\(FlowBriefing.fileName) is out of date. Regenerate it (see this test's comment).")
    }

    // MARK: Compilation

    func testCharacterSheetKnownHeightSurvivesFlowExportImport() throws {
        let flow = try recipe(#"{"nodes":[{"id":"sheet","kind":"characterSheet","settings":{"subject":"animal","heightCM":55.5}}],"wires":[]}"#)
        let project = try XCTUnwrap(compiler.compile(flow).project)
        let exported = FlowRecipeExporter.recipe(from: project)
        let reopened = try XCTUnwrap(compiler.compile(exported).project?.nodes.first)
        XCTAssertEqual(reopened.characterSheetSubject, .animal)
        XCTAssertEqual(reopened.characterSheetHeightCM, 55.5)
        XCTAssertTrue(reopened.characterSheetBrief.contains("Shoulder height: 55.5 cm"))
    }

    func testCharacterSheetExplicitPoseSurvivesFlowExportImport() throws {
        let flow = try recipe(#"{"nodes":[{"id":"sheet","kind":"characterSheet","settings":{"subject":"person","pose":"seated"}}],"wires":[]}"#)
        let project = try XCTUnwrap(compiler.compile(flow).project)
        let reopened = try XCTUnwrap(compiler.compile(FlowRecipeExporter.recipe(from: project)).project?.nodes.first)
        XCTAssertEqual(reopened.characterSheetPose, .seated)
        XCTAssertTrue(reopened.characterSheetBrief.contains("subject seated on the same surface"))
    }

    func testCompilesAssignsFreshIDsAndLaysOut() throws {
        let result = compiler.compile(try recipe(FlowBriefing.examples[0].json))
        let project = try XCTUnwrap(result.project)
        XCTAssertEqual(project.name, "Product Hero Still")
        XCTAssertEqual(project.nodes.map(\.kind), [.imagePrompt, .imageGenerator, .imageUpscale, .imagePreview])
        XCTAssertEqual(project.edges.map(\.type), [.text, .image, .image])
        XCTAssertEqual(project.nodes[1].width, 832)
        XCTAssertEqual(project.nodes[2].upscaleScale, 2)
        XCTAssertEqual(project.nodes[0].imagePromptSettings?.subjectCategory, "Product")
        XCTAssertEqual(Set(project.nodes.map(\.id)).count, 4)
    }

    func testCompiledFlowOpensOnFirstAuthoredProductionNode() throws {
        let json = #"{"nodes":[{"id":"note","kind":"stickyNote"},{"id":"p","kind":"prompt","settings":{"text":"hello"}},{"id":"g","kind":"imageGenerator"}],"wires":["p.text -> g.prompt"]}"#
        let project = try XCTUnwrap(compiler.compile(try recipe(json)).project)
        let firstProduction = try XCTUnwrap(project.nodes.first { $0.kind != .stickyNote })
        XCTAssertEqual(project.viewport.offset.x + firstProduction.position.x * project.viewport.zoom, 48, accuracy: 0.001)
        XCTAssertEqual(project.viewport.offset.y + firstProduction.position.y * project.viewport.zoom, 48, accuracy: 0.001)
    }

    func testDefaultsWarnAboutModelsAndFilesButDoNotBlock() throws {
        let result = compiler.compile(try recipe(FlowBriefing.examples[1].json))
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.message.contains("needs a file") })
        XCTAssertTrue(result.warnings.contains { $0.message.contains("no model") })
    }

    func testDeclaredInputsBecomeAddressableSocketsAndRolesLandOnPorts() throws {
        let project = try XCTUnwrap(compiler.compile(try recipe(FlowBriefing.examples[2].json)).project)
        let template = try XCTUnwrap(project.nodes.first { $0.kind == .promptTemplate })
        XCTAssertEqual(template.dynamicInputs.map(\.label), ["product", "feel"])
        XCTAssertEqual(PromptTemplateSyntax.variables(in: template.prompt), ["product", "feel"])
        let roles = try XCTUnwrap(compiler.compile(try recipe(FlowBriefing.examples[1].json)).project?.nodes.first { $0.kind == .imageGenerator }?.referenceRoles)
        XCTAssertEqual(Set(roles.keys), ["referenceImage", "referenceImage2"])
    }

    func testShotSequenceFramesBecomeInputs() throws {
        let project = try XCTUnwrap(compiler.compile(try recipe(FlowBriefing.examples[5].json)).project)
        let sequence = try XCTUnwrap(project.nodes.first { $0.kind == .shotSequence })
        XCTAssertEqual(sequence.inputPorts.map(\.id), ["open", "middle", "close"])
        XCTAssertEqual(project.edges.filter { $0.targetID == sequence.id }.map(\.targetPortID).sorted(), ["close", "middle", "open"])
    }

    func testOmittedPortsResolveWhenUnambiguous() throws {
        let json = #"{"nodes":[{"id":"a","kind":"prompt","settings":{"text":"hi"}},{"id":"b","kind":"textPreview"}],"wires":["a -> b"]}"#
        let result = compiler.compile(try recipe(json))
        XCTAssertTrue(result.errors.isEmpty, result.report())
        XCTAssertEqual(result.project?.edges.first?.targetPortID, "text")
    }

    // MARK: Errors

    func testReportsEveryProblemAtOnceWithFixes() throws {
        let json = #"""
        {"nodes":[
          {"id":"a","kind":"imageGen"},
          {"id":"b","kind":"imageGenerator","settings":{"width":"big","colour":"red","seed":-4}},
          {"id":"b","kind":"prompt"},
          {"id":"c","kind":"imageUpscale"},
          {"id":"d","kind":"prompt","inputs":["x"]}],
         "wires":["b.image -> c.image","b.text -> c.image","zzz.text -> c.image","c.image -> b.prompt","b.foo -> c.image"]}
        """#
        let result = compiler.compile(try recipe(json))
        XCTAssertNil(result.project)
        let messages = result.errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("'imageGen' is not a node kind"), messages)
        XCTAssertTrue(messages.contains("imageGenerator"), messages)
        XCTAssertTrue(messages.contains("expected whole number"), messages)
        XCTAssertTrue(messages.contains("'colour' is not a setting of imageGenerator"), messages)
        XCTAssertTrue(messages.contains("used twice"), messages)
        XCTAssertTrue(messages.contains("has fixed inputs"), messages)
        XCTAssertTrue(messages.contains("'zzz' is not a node id"), messages)
        XCTAssertTrue(messages.contains("no output 'foo'"), messages)
        XCTAssertGreaterThanOrEqual(result.errors.count, 6)
        XCTAssertTrue(result.report().contains("Fix these"))
    }

    func testTypeMismatchAndSecondWireAreExplained() throws {
        let json = #"""
        {"nodes":[{"id":"p","kind":"prompt"},{"id":"q","kind":"prompt"},{"id":"g","kind":"imageGenerator"},{"id":"v","kind":"imagePreview"}],
         "wires":["p.text -> v.image","p.text -> g.prompt","q.text -> g.prompt"]}
        """#
        let messages = compiler.compile(try recipe(json)).errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("Wires only connect matching types"), messages)
        XCTAssertTrue(messages.contains("already has a wire"), messages)
    }

    func testCycleIsRejected() throws {
        let json = #"{"nodes":[{"id":"a","kind":"imageResize"},{"id":"b","kind":"imageBlur"}],"wires":["a.image -> b.image","b.image -> a.image"]}"#
        let result = compiler.compile(try recipe(json))
        XCTAssertNil(result.project)
        XCTAssertTrue(result.errors.contains { $0.message.contains("cycle") })
    }

    func testRangeAndChoiceViolationsNameTheAllowedValues() throws {
        let json = #"{"nodes":[{"id":"u","kind":"imageUpscale","settings":{"scale":9}},{"id":"m","kind":"imagePrompt","settings":{"lighting":"disco"}}],"wires":[]}"#
        let messages = compiler.compile(try recipe(json)).errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(messages.contains("between 2 and 4"), messages)
        XCTAssertTrue(messages.contains("\"Soft daylight\""), messages)
    }

    // MARK: Parsing pasted text

    func testParserStripsFencesAndProse() throws {
        let reply = "Here is your flow!\n\n```json\n\(FlowBriefing.examples[0].json)\n```\n\n**You need to:** nothing."
        guard case .success(.recipe(let parsed)) = FlowDocumentParser.parse(reply) else { return XCTFail("did not parse") }
        XCTAssertEqual(parsed.nodes.count, 4)
    }

    func testParserIgnoresBracesInsideStrings() throws {
        let json = #"{"name":"a } b","nodes":[{"id":"n","kind":"prompt","settings":{"text":"{{x}} \" }"}}]} trailing words {"#
        guard case .success(.recipe(let parsed)) = FlowDocumentParser.parse(json) else { return XCTFail("did not parse") }
        XCTAssertEqual(parsed.nodes.count, 1)
    }

    func testParserRejectsNonJSONWithAHelpfulMessage() {
        guard case .failure(let none) = FlowDocumentParser.parse("no json here") else { return XCTFail() }
        XCTAssertTrue(none.message.contains("No JSON"))
        guard case .failure(let broken) = FlowDocumentParser.parse(#"{"nodes": [ {"id": "a" "kind": "prompt"} ]}"#) else { return XCTFail() }
        XCTAssertTrue(broken.message.contains("not valid JSON"))
        guard case .failure(let missing) = FlowDocumentParser.parse(#"{"nodes":[{"id":"a"}]}"#) else { return XCTFail() }
        XCTAssertTrue(missing.message.contains("kind"), missing.message)
    }

    func testFullBackupIsRecognisedAndRecipeVersionIsChecked() throws {
        let project = WorkflowProject(name: "Backup", nodes: [StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0))], edges: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard case .success(.fullProject(let restored)) = FlowDocumentParser.parse(String(decoding: try encoder.encode(project), as: UTF8.self)) else { return XCTFail("backup not recognised") }
        XCTAssertEqual(restored.name, "Backup")
        let future = compiler.compile(try recipe(#"{"version":9,"nodes":[{"id":"a","kind":"prompt"}]}"#))
        XCTAssertTrue(future.errors.contains { $0.path == "version" })
    }

    // MARK: Round trip

    func testExportThenImportPreservesStructureAndSettings() throws {
        for example in FlowBriefing.examples {
            let original = try XCTUnwrap(compiler.compile(try recipe(example.json)).project, example.title)
            let data = try FlowRecipeExporter.data(FlowRecipeExporter.recipe(from: original))
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("/Users/"), "no personal paths in a shareable file")
            let again = try XCTUnwrap({ () -> WorkflowProject? in
                let result = compiler.compile(try recipe(text)); XCTAssertTrue(result.errors.isEmpty, "\(example.title): \(result.report())"); return result.project
            }(), example.title)
            XCTAssertEqual(again.nodes.map(\.kind), original.nodes.map(\.kind), example.title)
            XCTAssertEqual(again.nodes.map(\.label), original.nodes.map(\.label), example.title)
            XCTAssertEqual(again.edges.count, original.edges.count, example.title)
            for (a, b) in zip(again.nodes, original.nodes) {
                for setting in FlowSettingCatalog.settings(for: a.kind) { XCTAssertEqual(setting.get(a), setting.get(b), "\(example.title) \(a.label).\(setting.key)") }
            }
        }
    }

    func testExportNeverContainsModelsOrPaths() throws {
        var node = StudioNode(kind: .imageGenerator, label: "Gen", position: .init(x: 0, y: 0))
        node.model = "some-private-model"
        var input = StudioNode(kind: .imageInput, label: "Photo", position: .init(x: 0, y: 0))
        input.imagePath = "/Users/someone/secret.png"
        let project = WorkflowProject(name: "P", nodes: [node, input], edges: [])
        let text = String(decoding: try FlowRecipeExporter.data(FlowRecipeExporter.recipe(from: project)), as: UTF8.self)
        XCTAssertFalse(text.contains("some-private-model"))
        XCTAssertFalse(text.contains("secret.png"))
    }

}
