import XCTest
@testable import GenStudio

private actor PurposeDiscoveryFixture: DiscoveryTransport {
    var requested: [URL] = []
    let failCard: Bool
    init(failCard: Bool = false) { self.failCard = failCard }
    func requests() -> [URL] { requested }
    func fetch(_ url: URL) async throws -> DiscoveryResponse {
        requested.append(url)
        if url.path.hasSuffix("README.md") {
            if failCard { throw URLError(.notConnectedToInternet) }
            return .init(data: Data("# Model\n\nThis model describes photographs and answers questions about the images that you provide.".utf8), nextLink: nil)
        }
        let row: [String: Any] = [
            "id": "publisher/model", "sha": String(repeating: "d", count: 40),
            "pipeline_tag": "image-text-to-text", "tags": ["image-text-to-text", "text-generation"],
            "cardData": ["description": "A vision model that describes images and answers questions about their contents."],
            "siblings": [["rfilename": "README.md", "size": 1024]]
        ]
        let body: Any = url.path == "/api/models" ? [row] : row
        return .init(data: try JSONSerialization.data(withJSONObject: body), nextLink: nil)
    }
}

final class ModelPurposeTests: XCTestCase {
    func testPurposeUsesExactTaskMetadataAndKeepsVisionDistinctFromImageGeneration() {
        XCTAssertEqual(ModelPurpose.declared(pipelineTag: "image-text-to-text", tags: ["text-generation", "image-text-to-text"]), [.imageUnderstanding, .textWriting])
        XCTAssertEqual(ModelPurpose.declared(pipelineTag: "text-to-video", tags: ["image-to-video"]), [.videoGeneration])
        XCTAssertEqual(ModelPurpose.declared(pipelineTag: "text-to-audio", tags: ["music-generation"]), [.audioGeneration, .musicGeneration])
        XCTAssertEqual(ModelPurpose.declared(pipelineTag: nil, tags: ["GGUF", "best-image-generator", "vision", "music", "license:apache-2.0"]), [.unknown])
        XCTAssertEqual(ModelPurpose.declared(pipelineTag: "text-to-speech", tags: ["automatic-speech-recognition"]), [.speechGeneration, .transcription])
        XCTAssertEqual(ModelPurpose.declared(pipelineTag: "image-to-image", tags: ["text-to-image"]), [.imageEditing, .imageGeneration])
    }

    func testPublisherExcerptSkipsMetadataCodeBadgesAndKeepsPlainProse() {
        let card = """
        ---
        description: This metadata should not become the introductory model description.
        license: apache-2.0
        ---
        # Image reader

        [![License](https://example.org/badge.svg)](https://example.org/license)

        <div align="center"><img src="logo.png" /></div>

        ```python
        print("Never execute or include example code as the description of this model")
        ```

        | Benchmark | Score |
        | ---- | ---- |

        **Image reader** describes photographs and answers questions about [the supplied image](https://example.org/docs).
        It can help you write accessible image captions.

        This later paragraph should not be included in the short excerpt.
        """
        XCTAssertEqual(PublisherModelDescription.excerpt(from: card), "Image reader describes photographs and answers questions about the supplied image. It can help you write accessible image captions.")
        XCTAssertNil(PublisherModelDescription.excerpt(from: "# A model\n\n![badge](https://example.org/icon.svg)"))
        XCTAssertNil(PublisherModelDescription.excerpt(from: String(repeating: "x", count: PublisherModelDescription.maximumCardBytes + 1)))
        let long = PublisherModelDescription.excerpt(from: String(repeating: "This model creates useful text from a written instruction. ", count: 20))
        XCTAssertLessThanOrEqual(long?.count ?? 0, PublisherModelDescription.maximumExcerptCharacters)
        XCTAssertTrue(long?.hasSuffix("…") == true)
    }

    func testDescriptionsAreCachedAcrossRestartAndCardsFetchedOnlyOnInspect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PurposeDiscoveryFixture()
        let discovery = ModelDiscovery(cacheRoot: root, transport: transport)
        let page = try await discovery.search(query: "vision")
        XCTAssertEqual(page.models[0].purposes, [.imageUnderstanding, .textWriting])
        XCTAssertNotNil(page.models[0].publisherDescription)
        let searchRequests = await transport.requests()
        XCTAssertEqual(searchRequests.count, 1)
        let detail = try await discovery.detail(repository: "publisher/model")
        XCTAssertTrue(detail.publisherExcerpt?.hasPrefix("This model describes photographs") == true)
        let requests = await transport.requests()
        XCTAssertEqual(requests.last?.path, "/publisher/model/resolve/\(String(repeating: "d", count: 40))/README.md")
        let restarted = ModelDiscovery(cacheRoot: root, transport: transport)
        let cached = try await restarted.detail(repository: "publisher/model", offline: true)
        let cachedPage = try await restarted.search(query: "vision", offline: true)
        XCTAssertEqual(cached.publisherExcerpt, detail.publisherExcerpt)
        XCTAssertEqual(cachedPage.models[0].publisherDescription, page.models[0].publisherDescription)
        XCTAssertTrue(cached.isCached)
        let finalRequests = await transport.requests()
        XCTAssertEqual(finalRequests.count, requests.count)
        let hardware = HardwareProfile(chip: "Apple M1 Max", memoryBytes: 64 << 30, osVersion: "26", freeDiskBytes: 100 << 30)
        XCTAssertFalse(ModelDiscovery.assess(detail: cached, hardware: hardware).runtimeSupported)
    }

    func testPublisherExcerptPrefersCapabilitiesOverLaunchMarketing() {
        let card = """
        # Qwen2.5-VL

        In the past five months since the last release, numerous developers have built new models and we are excited to introduce our latest release.

        **Key Enhancements:**

        - **Visual understanding:** Proficient in recognizing common objects such as flowers, birds, fish and insects, and analyzing text, charts, icons, graphics and layouts within images.
        - **Understanding videos:** This model comprehends videos and identifies relevant segments to help you answer questions about their content.
        - **Other feature:** A third feature should not be included in this short description even if it contains more interesting claims from the publisher.

        ## Installation

        Follow these instructions to install dependencies and download all the model files.
        """
        let excerpt = PublisherModelDescription.excerpt(from: card)
        XCTAssertTrue(excerpt?.hasPrefix("Visual understanding: Proficient") == true)
        XCTAssertTrue(excerpt?.contains("Understanding videos:") == true)
        XCTAssertFalse(excerpt?.contains("excited") == true)
        XCTAssertFalse(excerpt?.contains("third feature") == true)
        XCTAssertLessThanOrEqual(excerpt?.count ?? 0, 420)

        let prose = "Capabilities: This model creates realistic product photographs from a written description and can edit existing images."
        XCTAssertEqual(PublisherModelDescription.excerpt(from: prose), "This model creates realistic product photographs from a written description and can edit existing images.")
        let longFeature = "# Intended Use\n\n- " + String(repeating: "This model analyzes images and their contents. ", count: 20)
        let bounded = PublisherModelDescription.excerpt(from: longFeature)
        XCTAssertLessThanOrEqual(bounded?.count ?? 0, 420)
        XCTAssertTrue(bounded?.hasSuffix("…") == true)
    }

    func testUnavailableModelCardKeepsTaskDescriptionAndLegacyCacheDecodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try await ModelDiscovery(cacheRoot: root, transport: PurposeDiscoveryFixture(failCard: true)).detail(repository: "publisher/model")
        XCTAssertNil(detail.publisherExcerpt)
        XCTAssertTrue(detail.model.taskSummary.contains("Reads images"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as? [String: Any])
        object.removeValue(forKey: "publisherExcerpt")
        var model = try XCTUnwrap(object["model"] as? [String: Any]); model.removeValue(forKey: "publisherDescription"); object["model"] = model
        let legacy = try JSONDecoder().decode(DiscoveryDetail.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.publisherExcerpt)
        XCTAssertNil(legacy.model.publisherDescription)
        XCTAssertEqual(legacy.model.purposes, [.imageUnderstanding, .textWriting])
    }
}
