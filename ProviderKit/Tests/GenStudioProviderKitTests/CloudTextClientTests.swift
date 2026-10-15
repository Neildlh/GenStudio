import Foundation
import XCTest
@testable import GenStudioProviderKit

final class CloudTextClientTests: XCTestCase, @unchecked Sendable {
    func testOpenAISuccessAndRequestFields() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "user-model")
            XCTAssertEqual(json["input"] as? String, "Hello")
            XCTAssertEqual(json["max_output_tokens"] as? Int, 42)
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertEqual(json["stream"] as? Bool, false)
            return Self.response(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Hello back"}]}]}"#)
        }
        let result = try await makeClient(transport: transport).send(request(.openAI))
        XCTAssertEqual(result, .init(provider: .openAI, text: "Hello back", stopReason: "completed"))
    }

    func testAnthropicSuccessAndRequestFields() async throws {
        let transport = MockTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "user-model")
            XCTAssertEqual(json["max_tokens"] as? Int, 42)
            XCTAssertEqual(json["stream"] as? Bool, false)
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [["role": "user", "content": "Hello"]])
            return Self.response(#"{"content":[{"type":"text","text":"Part one"},{"type":"text","text":" + two"}],"stop_reason":"end_turn"}"#)
        }
        let result = try await makeClient(transport: transport).send(request(.anthropic))
        XCTAssertEqual(result, .init(provider: .anthropic, text: "Part one + two", stopReason: "end_turn"))
    }

    func testHTTPStatusMappingAndRedaction() async throws {
        let cases: [(Int, CloudProviderError)] = [
            (401, .authenticationFailed), (403, .authenticationFailed),
            (429, .rateLimited), (500, .serverUnavailable), (503, .serverUnavailable),
            (418, .requestRejected(statusCode: 418))
        ]
        for (status, expected) in cases {
            let transport = MockTransport { _ in Self.response("raw-secret-provider-error", status: status) }
            do {
                _ = try await makeClient(transport: transport).send(request(.openAI))
                XCTFail("Expected status \(status) to fail")
            } catch let error as CloudProviderError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.description.contains("test-secret"))
                XCTAssertFalse(error.description.contains("raw-secret-provider-error"))
            }
        }
    }

    func testOpenAIIncompleteRefusalMalformedAndEmpty() async throws {
        let cases: [(String, CloudProviderError)] = [
            (#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#, .incomplete(reason: "max_output_tokens")),
            (#"{"status":"failed","output":[]}"#, .providerFailed),
            (#"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal"}]}]}"#, .refused),
            ("not-json", .malformedResponse),
            (#"{"status":"completed","output":[]}"#, .emptyResult)
        ]
        for (body, expected) in cases {
            let transport = MockTransport { _ in Self.response(body) }
            await assertProviderError(expected) {
                try await self.makeClient(transport: transport).send(self.request(.openAI))
            }
        }
    }

    func testAnthropicMalformedAndEmpty() async throws {
        for (body, expected) in [("not-json", CloudProviderError.malformedResponse), (#"{"content":[],"stop_reason":"end_turn"}"#, .emptyResult)] {
            let transport = MockTransport { _ in Self.response(body) }
            await assertProviderError(expected) {
                try await self.makeClient(transport: transport).send(self.request(.anthropic))
            }
        }
    }

    func testValidationOccursBeforeTransport() async throws {
        let transport = MockTransport { _ in XCTFail("Transport must not run"); return Self.response("") }
        await assertProviderError(.invalidModel) {
            try await self.makeClient(transport: transport).send(.init(provider: .openAI, model: "  ", prompt: "p", maxOutputTokens: 1))
        }
        await assertProviderError(.invalidPrompt) {
            try await self.makeClient(transport: transport).send(.init(provider: .openAI, model: "m", prompt: "\n", maxOutputTokens: 1))
        }
        await assertProviderError(.invalidMaxOutputTokens) {
            try await self.makeClient(transport: transport).send(.init(provider: .openAI, model: "m", prompt: "p", maxOutputTokens: 0))
        }
        await assertProviderError(.invalidMaxOutputTokens) {
            try await self.makeClient(transport: transport).send(.init(provider: .openAI, model: "m", prompt: "p", maxOutputTokens: 1_000_001))
        }
    }

    func testMissingAndBlankCredentials() async throws {
        let transport = MockTransport { _ in XCTFail("Transport must not run"); return Self.response("") }
        await assertProviderError(.missingCredential(.openAI)) {
            try await CloudTextClient(credentials: MockCredentials(key: nil), transport: transport).send(self.request(.openAI))
        }
        await assertProviderError(.invalidAPIKey) {
            try await CloudTextClient(credentials: MockCredentials(key: "  "), transport: transport).send(self.request(.openAI))
        }
    }

    func testCancellationPropagates() async throws {
        let transport = MockTransport { _ in
            try await Task.sleep(for: .seconds(10))
            return Self.response("")
        }
        let task = Task { try await self.makeClient(transport: transport).send(self.request(.openAI)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCredentialStoreProtocolCanSetGetAndDeleteExactProvider() throws {
        let store = MemoryCredentialStore()
        try store.setAPIKey("openai-key", for: .openAI)
        try store.setAPIKey("anthropic-key", for: .anthropic)
        XCTAssertEqual(try store.apiKey(for: .openAI), "openai-key")
        try store.deleteAPIKey(for: .openAI)
        XCTAssertNil(try store.apiKey(for: .openAI))
        XCTAssertEqual(try store.apiKey(for: .anthropic), "anthropic-key")
    }

    private func request(_ provider: CloudProvider) -> CloudTextRequest {
        .init(provider: provider, model: "user-model", prompt: "Hello", maxOutputTokens: 42)
    }

    private func makeClient(transport: any CloudTransport) -> CloudTextClient {
        CloudTextClient(credentials: MockCredentials(key: "test-secret"), transport: transport)
    }

    private func assertProviderError<T: Sendable>(
        _ expected: CloudProviderError,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as CloudProviderError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func response(_ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        let url = URL(string: "https://example.invalid")!
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct MockCredentials: CloudCredentialStore {
    let key: String?
    func apiKey(for provider: CloudProvider) throws -> String? { key }
    func setAPIKey(_ apiKey: String, for provider: CloudProvider) throws {}
    func deleteAPIKey(for provider: CloudProvider) throws {}
}

private actor MockTransport: CloudTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let handler: Handler
    init(handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await handler(request) }
}

private final class MemoryCredentialStore: CloudCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [CloudProvider: String] = [:]
    func apiKey(for provider: CloudProvider) throws -> String? { lock.withLock { keys[provider] } }
    func setAPIKey(_ apiKey: String, for provider: CloudProvider) throws { lock.withLock { keys[provider] = apiKey } }
    func deleteAPIKey(for provider: CloudProvider) throws { lock.withLock { _ = keys.removeValue(forKey: provider) } }
}
