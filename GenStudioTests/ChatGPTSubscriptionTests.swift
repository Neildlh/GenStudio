import XCTest
import CryptoKit
@testable import GenStudio

final class ChatGPTSubscriptionAuthTests: XCTestCase {
    func testPKCEChallengeMatchesSHA256OfVerifier() {
        let pair = PKCE.generate()
        XCTAssertFalse(pair.verifier.isEmpty)
        XCTAssertFalse(pair.challenge.isEmpty)
        XCTAssertFalse(pair.verifier.contains("="))
        XCTAssertFalse(pair.challenge.contains("="))
        // Regression guard against a hashing bug: re-deriving the challenge from the
        // same verifier via the same algorithm (SHA-256 -> base64url) yields the same value.
        let recomputed = PKCE.base64URL(Data(SHA256.hash(data: Data(pair.verifier.utf8))))
        XCTAssertEqual(recomputed, pair.challenge)
    }

    func testRandomStateIsNotEmptyAndVariesAcrossCalls() {
        let a = PKCE.randomState()
        let b = PKCE.randomState()
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, b)
    }

    func testJWTPayloadDecodesNamespacedAccountID() {
        let payload: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": "acct_123"], "email": "user@example.com"]
        let jwt = makeUnsignedJWT(payload: payload)
        XCTAssertEqual(JWTPayload.chatGPTAccountID(fromIDToken: jwt), "acct_123")
        XCTAssertEqual(JWTPayload.email(fromIDToken: jwt), "user@example.com")
    }

    func testJWTPayloadFallsBackToFlatAccountIDClaim() {
        let jwt = makeUnsignedJWT(payload: ["account_id": "acct_flat"])
        XCTAssertEqual(JWTPayload.chatGPTAccountID(fromIDToken: jwt), "acct_flat")
    }

    func testJWTPayloadReturnsNilForGarbage() {
        XCTAssertNil(JWTPayload.decode("not-a-jwt"))
        XCTAssertNil(JWTPayload.chatGPTAccountID(fromIDToken: "a.b"))
    }

    private func makeUnsignedJWT(payload: [String: Any]) -> String {
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "none"])
        let body = try! JSONSerialization.data(withJSONObject: payload)
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "\(encode(header)).\(encode(body)).sig"
    }
}

final class ChatGPTSubscriptionImageClientTests: XCTestCase {
    func testExtractImageParsesImageGenerationCallEvent() async throws {
        let imageBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let base64 = imageBytes.base64EncodedString()
        let lines = [
            "data: {\"type\":\"response.created\"}",
            "",
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"image_generation_call\",\"result\":\"\(base64)\"}}",
            "data: [DONE]"
        ]
        let stream = Self.stream(lines)
        let result = try await ChatGPTSubscriptionImageClient.extractImage(from: stream)
        XCTAssertEqual(result, imageBytes)
    }

    func testExtractImageThrowsOnFailedEvent() async {
        let lines = ["data: {\"type\":\"response.failed\"}", "data: [DONE]"]
        do {
            _ = try await ChatGPTSubscriptionImageClient.extractImage(from: Self.stream(lines))
            XCTFail("expected streamFailed")
        } catch let error as ChatGPTSubscriptionImageError {
            guard case .streamFailed = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testExtractImageThrowsWhenStreamEndsWithoutImage() async {
        let lines = ["data: {\"type\":\"response.created\"}", "data: [DONE]"]
        do {
            _ = try await ChatGPTSubscriptionImageClient.extractImage(from: Self.stream(lines))
            XCTFail("expected noImageProduced")
        } catch let error as ChatGPTSubscriptionImageError {
            guard case .noImageProduced = error else { return XCTFail("wrong error: \(error)") }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testExtractImageIgnoresUnrelatedOutputItems() async throws {
        let imageBytes = Data([1, 2, 3])
        let base64 = imageBytes.base64EncodedString()
        let lines = [
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"result\":\"ignore-me\"}}",
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"image_generation_call\",\"result\":\"\(base64)\"}}",
            "data: [DONE]"
        ]
        let result = try await ChatGPTSubscriptionImageClient.extractImage(from: Self.stream(lines))
        XCTAssertEqual(result, imageBytes)
    }

    private static func stream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

/// Regression coverage for a real bug hit on first live use: OpenAI rejected
/// GenStudio's guessed orchestration model with HTTP 400 "the '<model>' model is
/// not supported when using Codex with a ChatGPT account." Community reports show
/// the allowed model name varies by account/plan and drifts over time, so the fix
/// is to try an ordered candidate list and remember whichever one works, rather
/// than hardcode one guess.
final class ChatGPTSubscriptionModelFallbackTests: XCTestCase {
    override func setUp() { ChatGPTSubscriptionModelResolver.override = nil }
    override func tearDown() { ChatGPTSubscriptionModelResolver.override = nil }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
    }

    private struct FakeTransport: ChatGPTImageSSETransport {
        let responses: [(status: Int, lines: [String])]
        let onRequest: (@Sendable (URLRequest) -> Void)?
        private let counter = CallCounter()

        init(responses: [(status: Int, lines: [String])], onRequest: (@Sendable (URLRequest) -> Void)? = nil) {
            self.responses = responses
            self.onRequest = onRequest
        }

        func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
            onRequest?(request)
            let index = counter.next()
            let response = responses[min(index, responses.count - 1)]
            let stream = AsyncThrowingStream<String, Error> { continuation in
                for line in response.lines { continuation.yield(line) }
                continuation.finish()
            }
            return (response.status, stream)
        }
    }

    private func imageEventLines(_ bytes: Data) -> [String] {
        ["data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"image_generation_call\",\"result\":\"\(bytes.base64EncodedString())\"}}", "data: [DONE]"]
    }

    private final class SeenModelsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var models: [String] = []
        func append(_ model: String) { lock.withLock { models.append(model) } }
        var all: [String] { lock.withLock { models } }
    }

    func testRetriesNextCandidateOnUnsupportedModelRejectionAndRemembersTheWinner() async throws {
        let imageBytes = Data([9, 9, 9])
        let seenModels = SeenModelsBox()
        let transport = FakeTransport(
            responses: [
                (400, ["data: {\"detail\":\"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account.\"}"]),
                (200, imageEventLines(imageBytes))
            ],
            onRequest: { request in
                if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let model = json["model"] as? String {
                    seenModels.append(model)
                }
            }
        )
        let client = ChatGPTSubscriptionImageClient(transport: transport)
        let request = ChatGPTImageGenerationRequest(prompt: "a cat", references: [], size: "1024x1024", outputFormat: "png")
        let result = try await client.generateImage(request, accessToken: "token", accountID: nil)
        XCTAssertEqual(result, imageBytes)
        XCTAssertEqual(seenModels.all, Array(ChatGPTSubscriptionImageConfig.orchestrationModelCandidates.prefix(2)))
        XCTAssertEqual(ChatGPTSubscriptionModelResolver.override, ChatGPTSubscriptionImageConfig.orchestrationModelCandidates[1])
    }

    func testDoesNotRetryOnAnUnrelatedRejection() async {
        let transport = FakeTransport(responses: [(400, ["data: {\"detail\":\"invalid prompt\"}"])])
        let client = ChatGPTSubscriptionImageClient(transport: transport)
        let request = ChatGPTImageGenerationRequest(prompt: "a cat", references: [], size: "1024x1024", outputFormat: "png")
        do {
            _ = try await client.generateImage(request, accessToken: "token", accountID: nil)
            XCTFail("expected requestRejected")
        } catch let error as ChatGPTSubscriptionImageError {
            guard case .requestRejected(let status, _) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
        XCTAssertNil(ChatGPTSubscriptionModelResolver.override)
    }

    func testResolverPrefersOverrideBeforeBuiltInCandidates() {
        ChatGPTSubscriptionModelResolver.override = "gpt-custom"
        XCTAssertEqual(ChatGPTSubscriptionModelResolver.candidates().first, "gpt-custom")
    }
}

final class ImageCapabilityRegistryCloudTests: XCTestCase {
    func testSelectableCapabilitiesExcludesCloudByDefault() {
        let choices = ImageCapabilityRegistry.selectableCapabilities(task: .textToImage, referenceCount: 0, installed: [])
        XCTAssertFalse(choices.contains { $0.engineID == ChatGPTSubscriptionImageEngine.engineID })
    }

    func testSelectableCapabilitiesIncludesCloudWhenSignedIn() {
        let choices = ImageCapabilityRegistry.selectableCapabilities(task: .textToImage, referenceCount: 0, installed: [], cloudSignedIn: true)
        XCTAssertTrue(choices.contains { $0.recipeID == ChatGPTSubscriptionImageEngine.recipeID && $0.task == .textToImage })
    }

    func testSelectableCapabilitiesRespectsReferenceCountForCloud() {
        let tooMany = ImageCapabilityRegistry.selectableCapabilities(task: .imageToImage, referenceCount: 99, installed: [], cloudSignedIn: true)
        XCTAssertFalse(tooMany.contains { $0.recipeID == ChatGPTSubscriptionImageEngine.recipeID })
        let withinBounds = ImageCapabilityRegistry.selectableCapabilities(task: .imageToImage, referenceCount: 1, installed: [], cloudSignedIn: true)
        XCTAssertTrue(withinBounds.contains { $0.recipeID == ChatGPTSubscriptionImageEngine.recipeID })
    }

    func testCloudCapabilityLookupByRecipeAndTask() {
        let capability = ImageCapabilityRegistry.capability(recipeID: ChatGPTSubscriptionImageEngine.recipeID, task: .textToImage)
        XCTAssertNotNil(capability)
        XCTAssertEqual(capability?.command, .chatGPTSubscriptionCloud)
    }
}

/// Regression coverage for a real bug hit on first live use: signing in and
/// selecting the ChatGPT recipe still failed graph validation with "Model
/// chatgpt-images-subscription is not installed or its files are unavailable,"
/// because NodeModelCompatibility.issue and GraphValidator.validate both gated
/// on InstalledGenerationModel/installed-name membership, which the cloud
/// route intentionally never has.
final class ChatGPTSubscriptionGraphValidationTests: XCTestCase {
    private func makeImageGeneratorNode() -> StudioNode {
        var node = StudioNode(kind: .imageGenerator, label: "Image", position: .init(x: 0, y: 0))
        node.model = ChatGPTSubscriptionImageEngine.recipeID
        node.width = 1024
        node.height = 1024
        return node
    }

    func testNodeModelCompatibilityAllowsCloudRecipeOnlyWhenSignedIn() {
        let node = makeImageGeneratorNode()
        XCTAssertNotNil(NodeModelCompatibility.issue(for: node, installed: [], cloudSignedIn: false))
        XCTAssertNil(NodeModelCompatibility.issue(for: node, installed: [], cloudSignedIn: true))
    }

    func testGraphValidatorAcceptsCloudRecipeWhenSignedIn() throws {
        let prompt = StudioNode(kind: .prompt, label: "P", position: .init(x: 0, y: 0), prompt: "a fruit bowl")
        let node = makeImageGeneratorNode()
        let project = WorkflowProject(name: "P", nodes: [prompt, node], edges: [VideoFixtures.edge(prompt, "text", node, "prompt", .text)])
        XCTAssertThrowsError(try GraphValidator().validate(project, installedModels: [], installedGenerationModels: [], cloudSignedIn: false))
        XCTAssertNoThrow(try GraphValidator().validate(project, installedModels: [], installedGenerationModels: [], cloudSignedIn: true))
    }
}

final class ImageEngineRouterTests: XCTestCase {
    private actor RecordingEngine: ImageGenerationEngine {
        private(set) var callCount = 0
        func generate(_ request: ImageGenerationRequest) async throws -> URL {
            callCount += 1
            return URL(fileURLWithPath: "/tmp/recorded.png")
        }
        func calls() async -> Int { callCount }
    }

    func testRouterDispatchesCloudRecipeToCloudEngine() async throws {
        let local = RecordingEngine()
        let cloud = RecordingEngine()
        let router = ImageEngineRouter(local: local, chatGPTSubscription: cloud)
        let request = ImageGenerationRequest(task: .textToImage, recipeID: ChatGPTSubscriptionImageEngine.recipeID, engineBuild: "cloud", prompt: "a cat", width: 1024, height: 1024, seed: 0, steps: 1, cfgScale: 1.0, sampler: nil, strength: nil)
        _ = try await router.generate(request)
        let cloudCalls = await cloud.calls()
        let localCalls = await local.calls()
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(localCalls, 0)
    }

    func testRouterDispatchesLocalRecipeToLocalEngine() async throws {
        let local = RecordingEngine()
        let cloud = RecordingEngine()
        let router = ImageEngineRouter(local: local, chatGPTSubscription: cloud)
        let request = ImageGenerationRequest(task: .textToImage, recipeID: ImageCapabilityRegistry.sd15RecipeID, engineBuild: VideoCapabilityRegistry.sdCppBuild, prompt: "a cat", width: 512, height: 512, seed: 0, steps: 20, cfgScale: 7.0, sampler: "euler_a", strength: nil)
        _ = try await router.generate(request)
        let cloudCalls = await cloud.calls()
        let localCalls = await local.calls()
        XCTAssertEqual(localCalls, 1)
        XCTAssertEqual(cloudCalls, 0)
    }
}
