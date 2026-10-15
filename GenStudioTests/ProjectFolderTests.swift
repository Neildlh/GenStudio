import XCTest
@testable import GenStudio

final class ProjectHomeTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "GenStudioHomeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func source(_ name: String, _ contents: String = "pixels") throws -> URL {
        let url = scratch.appending(path: "src-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testPrepareCreatesTheThreeTypeFolders() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        try home.prepare()
        for name in ["images", "video", "prompts"] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: home.links.appending(path: name).path, isDirectory: &isDirectory) && isDirectory.boolValue, name)
        }
    }

    func testLinkKindsFollowFileType() {
        XCTAssertEqual(LinkKind.kind(forExtension: "png"), .image)
        XCTAssertEqual(LinkKind.kind(forExtension: "JPG"), .image)
        XCTAssertEqual(LinkKind.kind(forExtension: "mp4"), .video)
        XCTAssertEqual(LinkKind.kind(forExtension: "mov"), .video)
        XCTAssertEqual(LinkKind.kind(forExtension: "txt"), .text)
        XCTAssertNil(LinkKind.kind(forExtension: "zip"))
    }

    func testFinalIsNamedAfterTheHeadingInTheRightFolder() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        let path = try home.writeFinal(from: try source("a1.png"), name: "Shot 11A Hand Approaches", kind: .image, claimed: [], own: nil)
        XCTAssertEqual(path, "Links/images/Shot 11A Hand Approaches.png")
        XCTAssertEqual(try String(contentsOf: home.url(for: path), encoding: .utf8), "pixels")
        let clip = try home.writeFinal(from: try source("v.mp4", "video"), name: "Door Opens", kind: .video, claimed: [], own: nil)
        XCTAssertEqual(clip, "Links/video/Door Opens.mp4")
        let prompt = try home.writeFinalText("A quiet hallway", name: "Hallway Prompt", claimed: [], own: nil)
        XCTAssertEqual(prompt, "Links/prompts/Hallway Prompt.txt")
        XCTAssertEqual(try String(contentsOf: home.url(for: prompt), encoding: .utf8), "A quiet hallway")
    }

    func testTwoNodesWithTheSameHeadingNeverShareOrOverwriteAFile() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        let first = try home.writeFinal(from: try source("a.png", "first"), name: "Hero", kind: .image, claimed: [], own: nil)
        let second = try home.writeFinal(from: try source("b.png", "second"), name: "Hero", kind: .image, claimed: [first], own: nil)
        XCTAssertEqual(first, "Links/images/Hero.png")
        XCTAssertEqual(second, "Links/images/Hero_2.png")
        XCTAssertEqual(try String(contentsOf: home.url(for: first), encoding: .utf8), "first")
    }

    func testAFileYouPutThereIsNeverOverwritten() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        try home.prepare()
        try Data("yours".utf8).write(to: home.url(for: "Links/images/Hero.png"))
        let path = try home.writeFinal(from: try source("a.png", "generated"), name: "Hero", kind: .image, claimed: [], own: nil)
        XCTAssertEqual(path, "Links/images/Hero_2.png")
        XCTAssertEqual(try String(contentsOf: home.url(for: "Links/images/Hero.png"), encoding: .utf8), "yours")
    }

    func testLockingAgainReplacesTheNodesOwnFile() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        let first = try home.writeFinal(from: try source("a.png", "one"), name: "Hero", kind: .image, claimed: [], own: nil)
        let again = try home.writeFinal(from: try source("b.png", "two"), name: "Hero", kind: .image, claimed: [], own: first)
        XCTAssertEqual(again, first)
        XCTAssertEqual(try String(contentsOf: home.url(for: first), encoding: .utf8), "two")
    }

    func testRenameFollowsTheHeadingIncludingACaseOnlyChange() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        let path = try home.writeFinal(from: try source("a.png"), name: "Hero", kind: .image, claimed: [], own: nil)
        let renamed = try home.renameFinal(at: path, to: "Hero Final", kind: .image, claimed: [])
        XCTAssertEqual(renamed, "Links/images/Hero Final.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.url(for: path).path))
        let recased = try home.renameFinal(at: renamed, to: "hero final", kind: .image, claimed: [])
        XCTAssertEqual(recased, "Links/images/hero final.png")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: home.folder(for: .image).path)).contains("hero final.png"))
    }

    func testRenameOfAFileThatWasRemovedLeavesTheRecordAlone() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        XCTAssertEqual(try home.renameFinal(at: "Links/images/gone.png", to: "New", kind: .image, claimed: []), "Links/images/gone.png")
    }

    func testRelativePathOnlyForFilesInsideLinks() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        let inside = try home.writeFinal(from: try source("a.png"), name: "Hero", kind: .image, claimed: [], own: nil)
        XCTAssertEqual(home.relativePath(of: home.url(for: inside)), inside)
        XCTAssertNil(home.relativePath(of: scratch.appending(path: "elsewhere.png")))
    }

    func testMissingMediaFinalIsDetectedButTextIsNot() throws {
        let home = ProjectHome(root: scratch.appending(path: "Client"))
        XCTAssertTrue(home.isMissing(.init(path: "Links/images/x.png", kind: .image, takeID: nil, lockedAt: Date())))
        XCTAssertFalse(home.isMissing(.init(path: "Links/prompts/x.txt", kind: .text, takeID: nil, lockedAt: Date(), text: "hi")))
    }

    func testOldProjectFilesWithoutTheNewFieldsStillLoad() throws {
        let json = #"{"schemaVersion":2,"name":"Old","nodes":[{"kind":"prompt","label":"P","position":{"x":0,"y":0}}],"edges":[]}"#
        let project = try JSONDecoder().decode(WorkflowProject.self, from: Data(json.utf8))
        XCTAssertNil(project.homeFolder)
        XCTAssertNil(project.nodes[0].finalized)
        let encoded = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        XCTAssertFalse(encoded.contains("homeFolder"), "a project without a folder gains no new keys")
        XCTAssertFalse(encoded.contains("finalized"))
    }
}

@MainActor
final class FinalLockingTests: XCTestCase {
    private var scratch: URL!
    private var model: StudioModel!
    private var project: WorkflowProject!
    private var generator: StudioNode!
    private var upscale: StudioNode!
    private var home: URL!
    private var take: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "GenStudioLockTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let appRoot = scratch.appending(path: "AppSupport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appRoot.appending(path: "Artifacts"), withIntermediateDirectories: true)
        home = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        model = StudioModel(persistence: StudioPersistence(root: appRoot), engine: StubEngine())
        generator = StudioNode(kind: .imageGenerator, label: "Shot 11A", position: .init(x: 0, y: 0))
        upscale = StudioNode(kind: .imageUpscale, label: "Upscale", position: .init(x: 400, y: 0))
        let edge = StudioEdge(sourceID: generator.id, sourcePortID: "image", targetID: upscale.id, targetPortID: upscale.inputPorts[0].id, type: .image)
        project = WorkflowProject(name: "Campaign", nodes: [generator, upscale], edges: [edge])
        take = appRoot.appending(path: "Artifacts/abc123.png")
        try Data("draft pixels".utf8).write(to: take)
        let artifact = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: generator.id, graphSnapshot: project,
                                         values: [PortAddress(nodeID: generator.id, portID: "image"): .image(take)],
                                         createdAt: Date(timeIntervalSince1970: 10), generatedNodeIDs: [generator.id])
        model.projects = [project]; model.currentProjectID = project.id; model.executionArtifacts = [artifact]
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private var live: WorkflowProject { model.projects[0] }
    private func node(_ id: UUID) -> StudioNode { live.nodes.first { $0.id == id }! }

    func testLockingSavesTheChosenTakeUnderTheHeadingAndFlowsDownstream() throws {
        try model.bindProjectFolder(home, to: project.id)
        XCTAssertTrue(model.lockFinal(generator.id))

        let locked = node(generator.id)
        XCTAssertTrue(locked.isLockedFinal)
        XCTAssertEqual(locked.finalized?.path, "Links/images/Shot 11A.png")
        XCTAssertEqual(try String(contentsOf: home.appending(path: "Links/images/Shot 11A.png"), encoding: .utf8), "draft pixels")
        guard case .image(let url) = model.displayedValue(for: locked) else { return XCTFail("a locked node shows its saved file") }
        XCTAssertEqual(url.standardizedFileURL.path, home.appending(path: "Links/images/Shot 11A.png").standardizedFileURL.path,
                       "the saved file, not the app's draft copy, is the node's value")
        XCTAssertEqual(model.finalBadgeState(for: locked), .locked)
        XCTAssertEqual(model.finalBadgeState(for: node(upscale.id)), .open, "a node with nothing saved shows the open lock")
    }

    func testEditingTheDraftAfterLockingChangesNothingDownstream() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        try Data("a different draw".utf8).write(to: take)
        guard case .image(let url) = model.displayedValue(for: node(generator.id)) else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "draft pixels")
    }

    func testALockedNodeCannotBeRunAndSaysWhy() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        model.selectedNodeID = generator.id
        model.runSelected()
        XCTAssertTrue(model.alertMessage?.contains("locked as final") == true)
        XCTAssertFalse(model.isRunning)
    }

    func testUnlockingReturnsToDraftAndRelockingReplacesTheSameFile() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        model.unlockFinal(generator.id)
        XCTAssertFalse(node(generator.id).isLockedFinal)
        XCTAssertEqual(model.finalBadgeState(for: node(generator.id)), .open)
        try Data("second draw".utf8).write(to: take)
        model.lockFinal(generator.id)
        XCTAssertEqual(node(generator.id).finalized?.path, "Links/images/Shot 11A.png", "no Shot 11A_2 beside it")
        XCTAssertEqual(try String(contentsOf: home.appending(path: "Links/images/Shot 11A.png"), encoding: .utf8), "second draw")
    }

    func testLockedNodesAreLeftOutOfTheRunPlanSoTheyCostNothing() throws {
        var locked = project!
        locked.nodes[0].finalized = FinalRecord(path: "Links/images/Shot 11A.png", kind: .image, takeID: nil, lockedAt: Date())
        let nodes = RunPlan.reachableNodes(project: locked, target: upscale.id)
        XCTAssertEqual(nodes.map(\.id), [upscale.id], "nothing behind a locked node is planned")
        XCTAssertEqual(RunPlan.reachableNodes(project: project, target: upscale.id).count, 2)
    }

    func testMissingFinalFileStopsARunWithAClearMessageInsteadOfRegenerating() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        try FileManager.default.removeItem(at: home.appending(path: "Links/images/Shot 11A.png"))
        XCTAssertEqual(model.finalBadgeState(for: node(generator.id)), .missing)
        XCTAssertThrowsError(try model.lockedFinalIssue(in: live, target: upscale.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("saved file"))
        }
    }

    func testRenamingTheHeadingRenamesTheFileAndUndoRenamesItBack() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        model.renameNode(generator.id, to: "Shot 11A Hand Approaches")
        XCTAssertEqual(node(generator.id).finalized?.path, "Links/images/Shot 11A Hand Approaches.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: "Links/images/Shot 11A Hand Approaches.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: "Links/images/Shot 11A.png").path))

        model.undo()
        XCTAssertEqual(node(generator.id).label, "Shot 11A")
        XCTAssertEqual(node(generator.id).finalized?.path, "Links/images/Shot 11A.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: "Links/images/Shot 11A.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: "Links/images/Shot 11A Hand Approaches.png").path))

        model.redo()
        XCTAssertEqual(node(generator.id).finalized?.path, "Links/images/Shot 11A Hand Approaches.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: "Links/images/Shot 11A Hand Approaches.png").path))
    }

    func testRenamingInTheImagesSidebarRenamesTheNodeAndItsFile() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        let item = try XCTUnwrap(model.galleryMediaItems.first)
        XCTAssertEqual(item.name, "Shot 11A", "a locked node's heading is its name")
        Task { await model.renameGalleryMedia(item, to: "Door Handle Final") }
        // renameGalleryMedia returns synchronously for locked nodes; give the main actor a turn regardless.
        let expectation = XCTestExpectation(description: "renamed")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(node(generator.id).label, "Door Handle Final")
        XCTAssertEqual(node(generator.id).finalized?.path, "Links/images/Door Handle Final.png")
        XCTAssertEqual(model.galleryMediaItems.first?.name, "Door Handle Final")
    }

    func testUndoNeverUnbindsTheProjectFolder() throws {
        model.renameNode(generator.id, to: "Renamed")
        try model.bindProjectFolder(home, to: project.id)
        model.undo()
        XCTAssertEqual(node(generator.id).label, "Shot 11A")
        XCTAssertEqual(live.homeFolder, home.standardizedFileURL.path)
    }

    func testDuplicatedNodesAndProjectsAreDraftsNotSecondOwnersOfTheFile() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        model.selectedNodeID = generator.id
        let copies = model.duplicateNodes([generator.id])
        let copy = try XCTUnwrap(live.nodes.first { copies.contains($0.id) })
        XCTAssertNil(copy.finalized)
        model.duplicateProject(project.id)
        let duplicate = try XCTUnwrap(model.projects.first { $0.id != project.id })
        XCTAssertNil(duplicate.homeFolder)
        XCTAssertTrue(duplicate.nodes.allSatisfy { $0.finalized == nil })
    }

    func testTwoProjectsCannotShareOneFolder() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.createProject()
        let other = model.projects[0]
        XCTAssertThrowsError(try model.bindProjectFolder(home, to: other.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already the folder"))
        }
    }

    func testTextPromptsLockToATxtFileAndAreReadFromTheRecord() throws {
        var prompt = StudioNode(kind: .prompt, label: "Hallway Prompt", position: .init(x: 0, y: 0))
        prompt.prompt = "A quiet hallway at dusk"
        var p = live; p.nodes.append(prompt)
        model.projects = [p]
        try model.bindProjectFolder(home, to: p.id)
        XCTAssertTrue(model.lockFinal(prompt.id))
        let locked = node(prompt.id)
        XCTAssertEqual(locked.finalized?.path, "Links/prompts/Hallway Prompt.txt")
        XCTAssertEqual(try String(contentsOf: home.appending(path: "Links/prompts/Hallway Prompt.txt"), encoding: .utf8), "A quiet hallway at dusk")
        XCTAssertEqual(model.displayedValue(for: locked), .text("A quiet hallway at dusk"))
    }

    func testLockingWithNothingGeneratedExplainsWhatToDo() throws {
        try model.bindProjectFolder(home, to: project.id)
        XCTAssertFalse(model.lockFinal(upscale.id))
        XCTAssertTrue(model.alertMessage?.contains("Run") == true)
    }

    // MARK: Folder file

    func testTheFolderKeepsAnUpToDateWorkflowFileWithRelativeLinks() async throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        await model.flushProjectWrites()
        let file = home.appending(path: "Campaign.genstudio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("Links/images/Shot 11A.png"))
        XCTAssertFalse(text.contains(scratch.path), "nothing machine-specific in the file")
        XCTAssertFalse(text.contains("homeFolder"))
        XCTAssertEqual(ProjectMirror.projectID(inFile: file), project.id)
    }

    func testRenamingTheProjectRenamesItsFileWithoutLeavingTheOldOne() async throws {
        try model.bindProjectFolder(home, to: project.id)
        await model.flushProjectWrites()
        var renamed = live; renamed.name = "Campaign Final"
        model.replace(renamed)
        await model.flushProjectWrites()
        let files = (try FileManager.default.contentsOfDirectory(atPath: home.path)).filter { $0.hasSuffix(".genstudio") }
        XCTAssertEqual(files, ["Campaign Final.genstudio"])
    }

    func testAFolderThatHoldsADifferentProjectIsNotOverwritten() throws {
        try Data(#"{"formatVersion":1,"project":{"id":"\#(UUID().uuidString)","name":"Other","nodes":[],"edges":[]}}"#.utf8).write(to: home.appending(path: "Campaign.genstudio"))
        XCTAssertThrowsError(try model.bindProjectFolder(home, to: project.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("different project"))
        }
        XCTAssertNil(live.homeFolder)
    }

    func testOpeningTheFolderFileShowsTheSameProjectInsteadOfACopy() async throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        await model.flushProjectWrites()
        model.openPackage(home.appending(path: "Campaign.genstudio"))
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.currentProjectID, project.id)
    }

    func testReopeningAfterRemovalRestoresTheWorkflowLockedAndStillWorkingInThatFolder() async throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        await model.flushProjectWrites()
        await model.removeFromLibrary(project.id)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appending(path: "Links/images/Shot 11A.png").path), "removing from the library never touches the folder")

        model.openPackage(home.appending(path: "Campaign.genstudio"))
        let reopened = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(reopened.homeFolder, home.standardizedFileURL.path, "it keeps working in its folder")
        let locked = try XCTUnwrap(reopened.nodes.first { $0.label == "Shot 11A" })
        XCTAssertTrue(locked.isLockedFinal)
        guard case .image(let url) = model.displayedValue(for: locked) else { return XCTFail("the locked image is there without any drafts") }
        XCTAssertEqual(url.standardizedFileURL.path, home.appending(path: "Links/images/Shot 11A.png").standardizedFileURL.path)
        XCTAssertNil(model.alertMessage)
    }

    func testPackagingIntoTheProjectsOwnFolderReusesFinalsInPlace() async throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        let report = try ProjectPackager().write(project: live, results: model.packageResultSources(for: live), to: home, fileName: "Campaign.genstudio")
        XCTAssertEqual(report.linkedFiles, 0, "the final is already in Links")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appending(path: "Links/images").path), ["Shot 11A.png"])
    }

    func testPackagingIntoAnotherFolderCopiesTheFinalUnderTheSameName() throws {
        try model.bindProjectFolder(home, to: project.id)
        model.lockFinal(generator.id)
        let elsewhere = scratch.appending(path: "Handover", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let report = try ProjectPackager().write(project: live, results: model.packageResultSources(for: live), to: elsewhere, fileName: "Campaign.genstudio")
        XCTAssertEqual(report.linkedFiles, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appending(path: "Links/images/Shot 11A.png").path))
        let opened = try ProjectPackageReader.read(report.packageFile)
        XCTAssertTrue(opened.missing.isEmpty, "the record and the copied file agree on the name")
    }

    func testUnlockedGenerationsAreCountedOnlyForFolderBoundProjects() throws {
        XCTAssertEqual(model.unlockedGenerationCount, 0, "no folder, nowhere to save")
        try model.bindProjectFolder(home, to: project.id)
        XCTAssertEqual(model.unlockedGenerationCount, 1)
        model.lockFinal(generator.id)
        XCTAssertEqual(model.unlockedGenerationCount, 0)
    }

    func testLockAllSavesEveryGenerationAndReportsWhatFailed() throws {
        try model.bindProjectFolder(home, to: project.id)
        XCTAssertEqual(model.lockAllGenerations(), [])
        XCTAssertTrue(node(generator.id).isLockedFinal)
    }
}
