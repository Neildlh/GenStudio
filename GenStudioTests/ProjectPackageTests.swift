import XCTest
@testable import GenStudio

final class ProjectPackageTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "GenStudioPackageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func file(_ name: String, in folder: String = "source", contents: String? = nil) throws -> URL {
        let directory = scratch.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data((contents ?? name).utf8).write(to: url)
        return url
    }

    private struct Fixture {
        var project: WorkflowProject
        var generator: StudioNode
        var input: StudioNode
        var source: ProjectPackager.ResultSource
    }

    private func fixture(output: URL, input inputURL: URL, name: String? = nil) -> Fixture {
        var input = StudioNode(kind: .imageInput, label: "Reference", position: .init(x: 0, y: 0))
        input.imagePath = inputURL.path
        var generator = StudioNode(kind: .imageGenerator, label: "Hero", position: .init(x: 300, y: 0))
        generator.imageSeed = 99
        let project = WorkflowProject(name: "Client Campaign", nodes: [input, generator], edges: [])
        let address = PortAddress(nodeID: generator.id, portID: generator.outputPorts[0].id)
        let key = "\(generator.id.uuidString)/\(address.portID)"
        let source = ProjectPackager.ResultSource(
            nodeID: generator.id, createdAt: Date(timeIntervalSince1970: 1_000), node: generator,
            values: [address: .image(output)], mediaProvenance: nil,
            mediaNames: name.map { [key: $0] }, isSelectedTake: true,
            displayNames: [address: name ?? "Hero · today"])
        return Fixture(project: project, generator: generator, input: input, source: source)
    }

    func testPackageCopiesLastResultAndInputsIntoLinksUnderYourNames() throws {
        let output = try file("a1b2.png", contents: "generated pixels")
        let reference = try file("IMG_0042.jpg", contents: "reference")
        let f = fixture(output: output, input: reference, name: "Hero final")
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let report = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "Client Campaign.genstudio")

        XCTAssertEqual(report.linkedFiles, 2)
        XCTAssertEqual(report.resultCount, 1)
        XCTAssertTrue(report.missing.isEmpty)
        let links = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Links/images").path).sorted()
        XCTAssertEqual(links, ["Hero final.png", "IMG_0042.jpg"], "a renamed result keeps the name shown in the sidebar")
        XCTAssertEqual(try String(contentsOf: folder.appending(path: "Links/images/Hero final.png"), encoding: .utf8), "generated pixels")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "Client Campaign.genstudio").path))
    }

    func testPackagedFileHoldsOnlyRelativeLinksAndNoAbsolutePaths() throws {
        let output = try file("out.png")
        let reference = try file("ref.png")
        let f = fixture(output: output, input: reference)
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "p.genstudio")

        let text = try String(contentsOf: report.packageFile, encoding: .utf8)
        XCTAssertFalse(text.contains(scratch.path), "nothing in the file may point back at the machine it was made on")
        XCTAssertTrue(text.contains("Links/images/ref.png"))
    }

    func testOpeningResolvesLinksNextToTheFileAndKeepsNamesAndSelectedTake() throws {
        let output = try file("a1b2.png", contents: "generated")
        let reference = try file("ref.png", contents: "reference")
        let f = fixture(output: output, input: reference, name: "Hero final")
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "p.genstudio")
        // The originals go away, as they would once the project is removed from the library.
        try FileManager.default.removeItem(at: scratch.appending(path: "source"))

        let opened = try ProjectPackageReader.read(report.packageFile)

        XCTAssertTrue(opened.missing.isEmpty)
        XCTAssertEqual(opened.project.nodes.count, 2)
        let input = try XCTUnwrap(opened.project.nodes.first { $0.kind == .imageInput })
        XCTAssertEqual(input.imagePath, folder.appending(path: "Links/images/ref.png").path)
        let generator = try XCTUnwrap(opened.project.nodes.first { $0.kind == .imageGenerator })
        XCTAssertEqual(generator.imageSeed, 99)
        let artifact = try XCTUnwrap(opened.artifacts.first)
        XCTAssertEqual(generator.selectedTakeID, artifact.id)
        let address = PortAddress(nodeID: generator.id, portID: generator.outputPorts[0].id)
        guard case .image(let url) = try XCTUnwrap(artifact.values[address]) else { return XCTFail("expected an image") }
        XCTAssertEqual(url.standardizedFileURL.path, folder.appending(path: "Links/images/Hero final.png").standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "generated")
        XCTAssertEqual(artifact.mediaNames?["\(address.nodeID.uuidString)/\(address.portID)"], "Hero final", "renames survive, keyed to the new node id")
        XCTAssertEqual(artifact.generatedNodeIDs, [generator.id])
    }

    func testOpeningGivesEveryIdentityAFreshValueSoItNeverCollidesWithTheOriginal() throws {
        let f = fixture(output: try file("o.png"), input: try file("r.png"))
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "p.genstudio")

        let first = try ProjectPackageReader.read(report.packageFile)
        let second = try ProjectPackageReader.read(report.packageFile)

        XCTAssertNotEqual(first.project.id, f.project.id)
        XCTAssertNotEqual(first.project.id, second.project.id)
        let original = Set(f.project.nodes.map(\.id))
        XCTAssertTrue(original.isDisjoint(with: first.project.nodes.map(\.id)))
        XCTAssertTrue(Set(first.project.nodes.map(\.id)).isDisjoint(with: second.project.nodes.map(\.id)))
        XCTAssertEqual(first.artifacts.first?.projectID, first.project.id)
    }

    func testMissingSourceFilesAreReportedAndLeftAloneNotInvented() throws {
        let reference = try file("ref.png")
        let gone = scratch.appending(path: "source/gone.png")
        let f = fixture(output: gone, input: reference)
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let report = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "p.genstudio")

        XCTAssertEqual(report.missing.count, 1)
        XCTAssertEqual(report.resultCount, 0, "a result whose media is gone is left out rather than saved pointing nowhere")
        XCTAssertEqual(report.linkedFiles, 1)
    }

    func testDifferentFilesWithTheSameNameAreKeptApartAndIdenticalOnesShareOneCopy() throws {
        let one = try file("x.png", in: "a", contents: "first")
        let two = try file("x.png", in: "b", contents: "second")
        let same = try file("x.png", in: "c", contents: "first")
        var nodeA = StudioNode(kind: .imageInput, label: "A", position: .init(x: 0, y: 0)); nodeA.imagePath = one.path
        var nodeB = StudioNode(kind: .imageInput, label: "B", position: .init(x: 0, y: 0)); nodeB.imagePath = two.path
        var nodeC = StudioNode(kind: .imageInput, label: "C", position: .init(x: 0, y: 0)); nodeC.imagePath = same.path
        let project = WorkflowProject(name: "Clash", nodes: [nodeA, nodeB, nodeC], edges: [])
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let report = try ProjectPackager().write(project: project, results: [], to: folder, fileName: "p.genstudio")

        XCTAssertEqual(report.linkedFiles, 2)
        let links = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Links/images").path).sorted()
        XCTAssertEqual(links, ["x-2.png", "x.png"])
    }

    func testPackagingAgainIntoTheSameFolderReusesLinksInsteadOfDuplicatingThem() throws {
        let f = fixture(output: try file("o.png"), input: try file("r.png"), name: "Hero")
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "p.genstudio")
        let second = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "p.genstudio")

        XCTAssertEqual(second.linkedFiles, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Links/images").path).count, 2)
    }

    func testAPackageFromANewerFormatIsRefusedUntouched() throws {
        let file = scratch.appending(path: "future.genstudio")
        try Data(#"{"formatVersion": 99}"#.utf8).write(to: file)
        XCTAssertThrowsError(try ProjectPackageReader.read(file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer GenStudio"))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"formatVersion": 99}"#)
    }

    func testNonProjectFilesAreRejectedWithAnActionableMessage() throws {
        let file = scratch.appending(path: "notes.genstudio")
        try Data("hello".utf8).write(to: file)
        XCTAssertThrowsError(try ProjectPackageReader.read(file))
    }

    func testShotSequenceAnchorsAreLinkedAndRelinkedOnOpen() throws {
        let anchor = try file("frame.png", contents: "frame")
        let identity = try MediaIdentity.of(anchor)
        let sequence = ResolvedShotSequence(
            anchors: [.init(anchorID: "a", label: "Opening", image: anchor, identity: identity, transitionNote: "", boundaryToNext: .cut)],
            timing: SequenceTiming(fps: 24, anchors: [], frameCount: 48), width: 640, height: 360)
        let mapped = try XCTUnwrap(RuntimeValue.shotSequence(sequence).mappingMedia { url, label in
            XCTAssertEqual(label, "Opening")
            return PackageLinks.packaged("Links/x.png")
        })
        guard case .shotSequence(let out) = mapped else { return XCTFail("expected a sequence") }
        XCTAssertEqual(PackageLinks.resolved(out.anchors[0].image, in: scratch)?.path, scratch.appending(path: "Links/x.png").path)
    }

    func testSplitKeepsOneExtensionAndStripsUnsafeCharacters() {
        XCTAssertEqual(ProjectPackager.split("Hero · 3:45 PM", fallbackExtension: "png").stem, "Hero · 3-45 PM")
        XCTAssertEqual(ProjectPackager.split("hero.PNG", fallbackExtension: "png").stem, "hero")
        XCTAssertEqual(ProjectPackager.split("hero.PNG", fallbackExtension: "png").ext, ".png")
        XCTAssertEqual(ProjectPackager.split("a/b", fallbackExtension: "mp4").stem, "a-b")
        XCTAssertEqual(ProjectPackager.split("  ", fallbackExtension: "png").stem, "Untitled")
        XCTAssertEqual(ProjectPackager.split("..hidden", fallbackExtension: "png").stem, "hidden")
    }

    func testModelsUsedListNamesModelsAndSourcesWithoutPackagingWeights() throws {
        let f = fixture(output: try file("o.png"), input: try file("r.png"))
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let models = [
            ModelUsage(id: "flux2-klein", name: "FLUX.2 Klein 4B", kind: "Image", engine: "native", provider: "Black Forest Labs",
                       sourceURL: "https://huggingface.co/example/flux2", components: [
                        .init(role: "transformer", repository: "example/flux2", revision: "0123456789abcdef", filename: "flux.safetensors", license: "apache-2.0", byteSize: 8_000_000_000)],
                       usedBy: ["Hero (Image Generator)", "Alt"]),
            ModelUsage(id: "gone-model", name: "gone-model", kind: "Unknown", engine: nil, provider: nil, sourceURL: nil, components: [], usedBy: ["Other"]),
        ]

        let report = try ProjectPackager().write(project: f.project, results: [f.source], models: models, to: folder, fileName: "p.genstudio")

        XCTAssertEqual(report.modelCount, 2)
        let text = try String(contentsOf: folder.appending(path: "Models Used.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Models used by “Client Campaign”"))
        XCTAssertTrue(text.contains("1. FLUX.2 Klein 4B"))
        XCTAssertTrue(text.contains("Used by: Hero (Image Generator), Alt"))
        XCTAssertTrue(text.contains("https://huggingface.co/example/flux2"))
        XCTAssertTrue(text.contains("example/flux2 @ 0123456789ab"), "revision is shortened but present")
        XCTAssertTrue(text.contains("Not installed on the Mac that made this package"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "Links/flux.safetensors").path))
    }

    func testNoModelsListIsWrittenWhenTheWorkflowUsesNone() throws {
        let f = fixture(output: try file("o.png"), input: try file("r.png"))
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try ProjectPackager().write(project: f.project, results: [f.source], to: folder, fileName: "p.genstudio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "Models Used.txt").path))
    }

    /// The whole promise, through the real model: package a finished project, take it out of the library,
    /// then open the file and find the workflow and its last generation exactly as they were.
    @MainActor
    func testPackageRemoveFromLibraryThenOpenBringsTheWorkflowAndLastGenerationBack() async throws {
        let root = scratch.appending(path: "AppSupport", directoryHint: .isDirectory)
        let persistence = StudioPersistence(root: root)
        let model = StudioModel(persistence: persistence, engine: StubEngine())

        // A generated image the app owns (in its Artifacts store) and an older take that must be left behind.
        let artifacts = root.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let older = artifacts.appending(path: "older.png"), latest = artifacts.appending(path: "latest.png")
        try Data("older".utf8).write(to: older); try Data("latest".utf8).write(to: latest)
        var node = StudioNode(kind: .imageGenerator, label: "Poster", position: .init(x: 0, y: 0))
        node.model = "some-model"
        var project = WorkflowProject(name: "Spring Launch", nodes: [node], edges: [])
        let address = PortAddress(nodeID: node.id, portID: node.outputPorts[0].id)
        let key = "\(node.id.uuidString)/\(address.portID)"
        let first = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(older)], createdAt: Date(timeIntervalSince1970: 1), generatedNodeIDs: [node.id])
        let second = ExecutionArtifact(id: UUID(), projectID: project.id, targetID: node.id, graphSnapshot: project, values: [address: .image(latest)], createdAt: Date(timeIntervalSince1970: 2), generatedNodeIDs: [node.id], mediaNames: [key: "Poster v3"])
        project.nodes[0].selectedTakeID = second.id
        try await persistence.saveProject(project)
        try await persistence.saveExecutionArtifact(first); try await persistence.saveExecutionArtifact(second)
        model.projects = [project]; model.currentProjectID = project.id; model.executionArtifacts = [second, first]

        // Package.
        let folder = scratch.appending(path: "Client", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources = model.packageResultSources(for: project)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.createdAt, second.createdAt, "the take the node was showing, not the newest by accident")
        let usages = model.packageModelUsages(for: project)
        XCTAssertEqual(usages.map(\.id), ["some-model"])
        let report = try ProjectPackager().write(project: project, results: sources, models: usages, to: folder, fileName: "Spring Launch.genstudio")
        XCTAssertEqual(report.linkedFiles, 1, "only the last generation travels")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "Links/images").path), ["Poster v3.png"])

        // Remove from the library: the app's copies go, the package stays whole.
        await model.removeFromLibrary(project.id)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(model.executionArtifacts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: latest.path), "the app's own copy is freed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "Links/images/Poster v3.png").path))

        // Open it again.
        model.openPackage(report.packageFile)
        let reopened = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(reopened.name, "Spring Launch")
        XCTAssertNotEqual(reopened.id, project.id)
        let poster = try XCTUnwrap(reopened.nodes.first)
        XCTAssertEqual(model.takes(for: poster).count, 1, "history starts fresh; the last generation is the only take")
        let item = try XCTUnwrap(model.galleryMediaItems.first)
        XCTAssertEqual(item.name, "Poster v3", "the name you gave it shows in the Images sidebar")
        guard case .image(let url) = item.value else { return XCTFail("expected an image") }
        XCTAssertEqual(url.standardizedFileURL.path, folder.appending(path: "Links/images/Poster v3.png").standardizedFileURL.path)
        XCTAssertNil(model.alertMessage)

        // Deleting the reopened project's take never deletes the package's file.
        await model.removeFromLibrary(reopened.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "Links/images/Poster v3.png").path))
    }

    func testUsedByCollapsesRepeatsAndCapsLongLists() {
        XCTAssertEqual(ModelsUsedFile.usedByText(["Hero", "Alt"]), "Hero, Alt")
        let many = Array(repeating: "Image Generator", count: 40) + ["Image Generator Copy (Image Generator)", "Upscale"]
        let text = ModelsUsedFile.usedByText(many)
        XCTAssertEqual(text, "Image Generator ×40, Image Generator Copy (Image Generator), Upscale  (42 nodes)")
        let names = (1...10).map { "Node \($0)" }
        XCTAssertEqual(ModelsUsedFile.usedByText(names), "Node 1, Node 2, Node 3, Node 4, Node 5, Node 6, and 4 more  (10 nodes)")
    }
}
