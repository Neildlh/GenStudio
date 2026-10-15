import Foundation

public struct CloudTextClient: Sendable {
    private static let openAIEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let anthropicEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let maximumOutputTokens = 1_000_000

    private let credentials: any CloudCredentialStore
    private let transport: any CloudTransport

    public init(
        credentials: any CloudCredentialStore = KeychainCredentialStore(),
        transport: any CloudTransport = URLSessionCloudTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func send(_ request: CloudTextRequest) async throws -> CloudTextResult {
        let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw CloudProviderError.invalidModel }
        guard !prompt.isEmpty else { throw CloudProviderError.invalidPrompt }
        guard (1...Self.maximumOutputTokens).contains(request.maxOutputTokens) else {
            throw CloudProviderError.invalidMaxOutputTokens
        }

        let storedKey: String?
        do {
            storedKey = try credentials.apiKey(for: request.provider)
        } catch let error as CloudProviderError {
            throw error
        } catch {
            throw CloudProviderError.credentialStoreFailure
        }
        guard let storedKey else { throw CloudProviderError.missingCredential(request.provider) }
        let apiKey = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw CloudProviderError.invalidAPIKey }

        let urlRequest = try makeURLRequest(request, model: model, prompt: prompt, apiKey: apiKey)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CloudProviderError.networkFailure
        }
        try validateStatus(response.statusCode)

        switch request.provider {
        case .openAI:
            return try parseOpenAI(data)
        case .anthropic:
            return try parseAnthropic(data)
        }
    }

    private func makeURLRequest(
        _ request: CloudTextRequest,
        model: String,
        prompt: String,
        apiKey: String
    ) throws -> URLRequest {
        var urlRequest: URLRequest
        let body: [String: Any]
        switch request.provider {
        case .openAI:
            urlRequest = URLRequest(url: Self.openAIEndpoint)
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": model,
                "input": prompt,
                "max_output_tokens": request.maxOutputTokens,
                "store": false,
                "stream": false
            ]
        case .anthropic:
            urlRequest = URLRequest(url: Self.anthropicEndpoint)
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "messages": [["role": "user", "content": prompt]],
                "max_tokens": request.maxOutputTokens,
                "stream": false
            ]
        }
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func validateStatus(_ statusCode: Int) throws {
        switch statusCode {
        case 200..<300: return
        case 401, 403: throw CloudProviderError.authenticationFailed
        case 429: throw CloudProviderError.rateLimited
        case 500..<600: throw CloudProviderError.serverUnavailable
        default: throw CloudProviderError.requestRejected(statusCode: statusCode)
        }
    }

    private func parseOpenAI(_ data: Data) throws -> CloudTextResult {
        let response: OpenAIResponse
        do {
            response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            throw CloudProviderError.malformedResponse
        }
        if response.status == "failed" { throw CloudProviderError.providerFailed }
        if response.status == "incomplete" {
            let safeReason: String?
            switch response.incompleteDetails?.reason {
            case "max_output_tokens": safeReason = "max_output_tokens"
            case "content_filter": safeReason = "content_filter"
            case .some: safeReason = "unspecified"
            case .none: safeReason = nil
            }
            throw CloudProviderError.incomplete(reason: safeReason)
        }
        var textParts: [String] = []
        for output in response.output ?? [] where output.type == "message" {
            for content in output.content ?? [] {
                if content.type == "refusal" { throw CloudProviderError.refused }
                if content.type == "output_text", let text = content.text { textParts.append(text) }
            }
        }
        let text = textParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CloudProviderError.emptyResult }
        return CloudTextResult(provider: .openAI, text: text, stopReason: response.status)
    }

    private func parseAnthropic(_ data: Data) throws -> CloudTextResult {
        let response: AnthropicResponse
        do {
            response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            throw CloudProviderError.malformedResponse
        }
        let text = response.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CloudProviderError.emptyResult }
        return CloudTextResult(provider: .anthropic, text: text, stopReason: response.stopReason)
    }
}

private struct OpenAIResponse: Decodable {
    struct IncompleteDetails: Decodable { let reason: String? }
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String
            let text: String?
        }
        let type: String
        let content: [Content]?
    }
    let status: String?
    let incompleteDetails: IncompleteDetails?
    let output: [Output]?

    enum CodingKeys: String, CodingKey {
        case status, output
        case incompleteDetails = "incomplete_details"
    }
}

private struct AnthropicResponse: Decodable {
    struct Content: Decodable {
        let type: String
        let text: String?
    }
    let content: [Content]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}
