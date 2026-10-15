import XCTest
@testable import GenStudio

/// Opt-in acceptance proof for the native LTX backend. This deliberately uses
/// ModelLibrary and ExecutionQueue so a direct Python success cannot masquerade
/// as a working GenStudio graph route.
///
/// Run with TEST_RUNNER_RUN_LTX23_MLX_INTEGRATION=1 plus the three paths below.
/// Set TEST_RUNNER_DOWNLOAD_LTX23_MLX=1 to exercise the app's complete one-action
/// install before rendering; interrupted component downloads remain resumable.
final class LTXMLXVideoIntegrationTests: XCTestCase {
    func testRealLTX23I2VThenT2VThroughGraph() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LTX23_MLX_INTEGRATION"] == "1",
              let libraryPath = environment["GENSTUDIO_MODEL_LIBRARY"],
              let sourcePath = environment["LTX23_SOURCE_IMAGE"],
              let evidencePath = environment["LTX23_EVIDENCE_DIR"] else {
            throw XCTSkip("Opt in with TEST_RUNNER_RUN_LTX23_MLX_INTEGRATION=1 and ModelLibrary, source-image, and evidence paths.")
        }

        let library = ModelLibrary(root: URL(fileURLWithPath: libraryPath))
        let recipe = MLXVideoModelCatalog.ltx23Q4
        if !(try await library.installedModels()).contains(where: { $0.id == recipe.id && $0.available }) {
            guard environment["DOWNLOAD_LTX23_MLX"] == "1" else {
                throw XCTSkip("The exact LTX-2.3 MLX Q4 recipe is not installed. Add TEST_RUNNER_DOWNLOAD_LTX23_MLX=1 to download it through ModelLibrary.")
            }
            _ = try await library.install(recipe: recipe)
        }
        let installed = try await library.installedModels()
        XCTAssertTrue(installed.contains { $0.id == recipe.id && $0.available })

        let root = try VideoFixtures.root("ltx23-mlx-graph-proof")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw StudioError.validation("The LTX integration source image is unreadable: \(sourceURL.path)")
        }
        let evidence = URL(fileURLWithPath: evidencePath)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        // Keep the graph proof on the exact production acceptance canvas. The
        // normal runtime preserves a connected image's aspect ratio, so prepare
        // this arbitrary evidence still before connecting it to the node.
        let preparedSource = try await MediaProcessor(root: root).aspectFill(sourceURL, width: 768, height: 448)

        let capabilities = [VideoCapabilityRegistry.ltx23TextToVideo, VideoCapabilityRegistry.ltx23ImageToVideo]
        let engine = MLXLTXVideoEngine(
            library: library,
            scratchRoot: root.appending(path: "GenerationScratch"),
            resourceRoot: Bundle.main.resourceURL,
            timeout: .seconds(7_200),
            capabilities: capabilities
        )
        let persistence = StudioPersistence(root: root)
        let queue = ExecutionQueue(engine: StubEngine(), persistence: persistence, videoEngine: engine, videoCapabilities: capabilities)

        let i2v: (output: URL, probe: VideoProbe, elapsed: Double, log: String?)
        do {
            i2v = try await runGraph(
                task: .imageToVideo,
                promptText: "A cinematic product shot. Preserve the subject, composition, colours, lighting and camera angle from the approved still. Add a slow controlled push-in, gentle natural secondary motion and subtle moving highlights; stable identity, no cuts.",
                sourceImage: preparedSource,
                queue: queue,
                installed: installed
            )
        } catch {
            if case let DecodingError.typeMismatch(_, context) = error {
                print("LTX I2V decoding failure at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)")
            }
            throw error
        }
        let t2v = try await runGraph(
            task: .textToVideo,
            promptText: "A cinematic amber paper sculpture slowly unfolds on a dark studio table as a soft highlight travels across its surface, gentle controlled camera push-in, coherent motion, no cuts.",
            sourceImage: nil,
            queue: queue,
            installed: installed
        )

        let i2vMovie = evidence.appending(path: "ltx23-mlx-i2v-768x448-121f.mp4")
        let t2vMovie = evidence.appending(path: "ltx23-mlx-t2v-768x448-121f.mp4")
        for (source, target) in [(i2v.output, i2vMovie), (t2v.output, t2vMovie)] {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }

        struct Result: Encodable {
            let task: VideoTask
            let modelLoadSeconds: Double?
            let generationSeconds: Double?
            let decodeSeconds: Double?
            let pipelineSeconds: Double?
            let graphTotalSeconds: Double
            let phaseSeconds: [String: Double]
            let output: VideoProbeSummary
            let outputSHA256: String
            let engineLogTail: String?
        }
        struct Report: Encodable {
            let recordedAt: Date
            let machine: String
            let model: String
            let backend: String
            let engineBuild: String
            let quantisation: String
            let mode: String
            let resolution: String
            let frames: Int
            let clipDurationSeconds: Double
            let fps: Int
            let stage1Steps: Int
            let stage2Steps: Int
            let peakMemory: String
            let imagePreservation: String
            let motionUsability: String
            let results: [Result]
        }
        let hardware = HardwareProfile.current()
        let report = Report(
            recordedAt: Date(), machine: "\(hardware.chip), \(hardware.memoryBytes / 1_073_741_824) GB, \(hardware.osVersion)",
            model: "dgrauet/ltx-2.3-mlx-q4@56a5866d638ecfe37c54d348e88938235185c2d4",
            backend: "dgrauet/ltx-2-mlx", engineBuild: MLXVideoModelCatalog.ltxBuild,
            quantisation: "Q4", mode: "distilled two-stage, no audio", resolution: "768x448",
            frames: 121, clipDurationSeconds: 121.0 / 24.0, fps: 24, stage1Steps: 8, stage2Steps: 3,
            peakMemory: "not instrumented by the graph runner",
            imagePreservation: "requires human review of retained I2V artifact",
            motionUsability: "requires human review of retained artifacts",
            results: [
                measuredResult(.imageToVideo, i2v, sha256: try MediaIdentity.of(i2vMovie).sha256),
                measuredResult(.textToVideo, t2v, sha256: try MediaIdentity.of(t2vMovie).sha256)
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: evidence.appending(path: "ltx23-mlx-m1-max-benchmark.json"), options: .atomic)

        let refreshed = try await library.installedModels()
        let verified = try XCTUnwrap(refreshed.first { $0.id == recipe.id })
        XCTAssertTrue(verified.hasVerifiedVideoTask(.imageToVideo))
        XCTAssertTrue(verified.hasVerifiedVideoTask(.textToVideo))

        func measuredResult(
            _ task: VideoTask,
            _ run: (output: URL, probe: VideoProbe, elapsed: Double, log: String?),
            sha256: String
        ) -> Result {
            let phases = phaseTimings(run.log ?? "")
            let load = phases.filter { $0.key.hasPrefix("Loading ") }.map(\.value).reduce(0, +)
            let decode = phases.filter { $0.key.hasPrefix("Decoding ") }.map(\.value).reduce(0, +)
            let pipeline = firstCapture(#"Time: ([0-9.]+)s"#, in: run.log ?? "")
            let generation = pipeline.map { max(0, $0 - load - decode) }
            return Result(task: task, modelLoadSeconds: phases.isEmpty ? nil : load,
                          generationSeconds: generation, decodeSeconds: phases.isEmpty ? nil : decode,
                          pipelineSeconds: pipeline, graphTotalSeconds: run.elapsed, phaseSeconds: phases,
                          output: .init(run.probe), outputSHA256: sha256, engineLogTail: run.log)
        }
    }

    private func phaseTimings(_ log: String) -> [String: Double] {
        let expression = try! NSRegularExpression(pattern: #"\[([^\]]+)\] done in ([0-9.]+)s"#)
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        return expression.matches(in: log, range: range).reduce(into: [:]) { result, match in
            guard let labelRange = Range(match.range(at: 1), in: log),
                  let valueRange = Range(match.range(at: 2), in: log),
                  let value = Double(log[valueRange]) else { return }
            result[String(log[labelRange]), default: 0] += value
        }
    }

    private func firstCapture(_ pattern: String, in text: String) -> Double? {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[capture])
    }

    private func runGraph(
        task: VideoTask,
        promptText: String,
        sourceImage: URL?,
        queue: ExecutionQueue,
        installed: [InstalledGenerationModel]
    ) async throws -> (output: URL, probe: VideoProbe, elapsed: Double, log: String?) {
        let prompt = StudioNode(kind: .prompt, label: "Motion Prompt", position: .init(x: 0, y: 1), prompt: promptText)
        var video = StudioNode(kind: task.nodeKind, label: "LTX-2.3 \(task.title)", position: .init(x: 1, y: 0), model: MLXVideoModelCatalog.ltx23Q4RecipeID)
        video.video = VideoCapabilityRegistry.ltx23TextToVideo.recommended
        var nodes = [prompt, video]
        var edges = [VideoFixtures.edge(prompt, "text", video, "prompt", .text)]
        if let sourceImage {
            let source = StudioNode(kind: .imageInput, label: "Approved still", position: .init(x: 0, y: 0), imagePath: sourceImage.path)
            nodes.insert(source, at: 0)
            edges.append(VideoFixtures.edge(source, "image", video, "startImage", .image))
        }
        let project = WorkflowProject(name: "LTX-2.3 native MLX \(task.title) proof", nodes: nodes, edges: edges)
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await queue.execute(project: project, targetID: video.id, installedGenerationModels: installed)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard case .video(let output)? = result.values[.init(nodeID: video.id, portID: "video")] else {
            throw StudioError.validation("LTX \(task.title) graph completed without a video output.")
        }
        let probe = try await VideoProbe.inspect(output)
        XCTAssertEqual(probe.width, 768)
        XCTAssertEqual(probe.height, 448)
        XCTAssertEqual(probe.frameCount, 121)
        XCTAssertEqual(probe.nominalFPS, 24, accuracy: 0.1)
        XCTAssertGreaterThan(probe.distinctFrameCount, 1)
        return (output, probe, elapsed, result.run?.snapshot.engineLogTail)
    }
}
