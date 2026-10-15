import Foundation

/// Calls the same internal endpoint Codex CLI's `image_generation` tool uses
/// (`chatgpt.com/backend-api/codex/responses`), billed to the signed-in ChatGPT
/// subscription. Undocumented and reverse-engineered from Codex CLI's own open-source
/// client and from community re-implementations (codex-imagen, CLIProxyAPI,
/// image-use/chatgpt-imagegen); OpenAI could change the request shape at any time.
enum ChatGPTSubscriptionImageConfig {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    /// Ordered fallback list of Codex model names to try for the orchestration `model`
    /// field. OpenAI restricts which model a ChatGPT-login session may address here,
    /// and — confirmed against a live account — the allowed set varies by plan/account
    /// and drifts over time; several specific names have each been seen rejected with
    /// "the '<model>' model is not supported when using Codex with a ChatGPT account."
    /// ChatGPTSubscriptionImageClient tries these in order and remembers whichever one
    /// works via ChatGPTSubscriptionModelResolver, so a future rename costs one extra
    /// rejected request rather than breaking the feature outright.
    static let orchestrationModelCandidates = ["gpt-5-codex", "gpt-5.1-codex-mini", "gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5"]
    /// The image-generation tool's own model. OpenAI's newest public image model as of
    /// writing ("ChatGPT Images 2.0"); bump this constant, not call sites, if OpenAI
    /// ships a newer id (e.g. a 2.5 revision) once that's confirmed against a real account.
    static let imageModel = "gpt-image-2"
    /// gpt-image-2's documented fixed output sizes. GenStudio's Image Generator node
    /// snaps whatever canvas the user picked to the nearest of these before sending.
    static let supportedSizes: [(width: Int, height: Int, api: String)] = [
        (1024, 1024, "1024x1024"),
        (1024, 1536, "1024x1536"),
        (1536, 1024, "1536x1024")
    ]

    static func nearestSupportedSize(width: Int, height: Int) -> (width: Int, height: Int, api: String) {
        supportedSizes.min {
            let da = abs($0.width - width) + abs($0.height - height)
            let db = abs($1.width - width) + abs($1.height - height)
            return da < db
        } ?? supportedSizes[0]
    }
}

struct ChatGPTImageReference: Sendable {
    let data: Data
    let mimeType: String
}

struct ChatGPTImageGenerationRequest: Sendable {
    let prompt: String
    let references: [ChatGPTImageReference]
    let size: String
    let outputFormat: String
}

/// Remembers whichever orchestration model name last worked, across launches, so
/// ChatGPTSubscriptionImageClient doesn't re-discover it by trial and error every time.
/// Also doubles as a manual override: setting `override` (e.g. from a future Settings
/// field) pins one model instead of trying the built-in candidate list.
enum ChatGPTSubscriptionModelResolver {
    private static let defaultsKey = "studio.chatGPTSubscription.orchestrationModel"

    static var override: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func candidates() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for model in ([override].compactMap { $0 } + ChatGPTSubscriptionImageConfig.orchestrationModelCandidates) where seen.insert(model).inserted {
            ordered.append(model)
        }
        return ordered
    }

    static func remember(_ model: String) { override = model }
}

enum ChatGPTSubscriptionImageError: Error, Sendable, CustomStringConvertible {
    case requestRejected(statusCode: Int, body: String)
    case streamFailed(String)
    case noImageProduced
    case malformedStream

    var description: String {
        switch self {
        case let .requestRejected(status, body):
            "ChatGPT image generation was rejected (HTTP \(status)): \(body.prefix(300))"
        case let .streamFailed(reason): "ChatGPT image generation failed: \(reason)"
        case .noImageProduced: "ChatGPT's response completed without returning an image."
        case .malformedStream: "ChatGPT's response stream could not be read."
        }
    }
}

/// Injectable so the SSE parsing logic can be unit tested without a live account.
protocol ChatGPTImageSSETransport: Sendable {
    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>)
}

struct URLSessionChatGPTImageSSETransport: ChatGPTImageSSETransport {
    func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTSubscriptionImageError.malformedStream }
        let lineSequence = bytes.lines
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in lineSequence { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http.statusCode, stream)
    }
}

private struct ImageGenerationCallEvent: Decodable {
    let type: String
    let item: Item?
    struct Item: Decodable { let type: String?; let result: String? }
}

struct ChatGPTSubscriptionImageClient: Sendable {
    private let transport: any ChatGPTImageSSETransport
    private let sessionIDProvider: @Sendable () -> String

    init(transport: any ChatGPTImageSSETransport = URLSessionChatGPTImageSSETransport(), sessionIDProvider: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.transport = transport
        self.sessionIDProvider = sessionIDProvider
    }

    func generateImage(_ request: ChatGPTImageGenerationRequest, accessToken: String, accountID: String?) async throws -> Data {
        let candidates = ChatGPTSubscriptionModelResolver.candidates()
        var lastError: ChatGPTSubscriptionImageError = .noImageProduced
        for (index, model) in candidates.enumerated() {
            let urlRequest = try makeURLRequest(request, accessToken: accessToken, accountID: accountID, orchestrationModel: model)
            let (status, lines) = try await transport.lines(for: urlRequest)
            guard (200..<300).contains(status) else {
                var body = ""
                for try await line in lines { body += line }
                let error = ChatGPTSubscriptionImageError.requestRejected(statusCode: status, body: body)
                // Only an "unsupported model for this account" rejection is worth
                // retrying with the next candidate; any other failure (bad prompt,
                // rate limit, auth) is real and should surface immediately.
                guard status == 400, body.localizedCaseInsensitiveContains("not supported"), index < candidates.count - 1 else {
                    throw error
                }
                lastError = error
                continue
            }
            let image = try await Self.extractImage(from: lines)
            ChatGPTSubscriptionModelResolver.remember(model)
            return image
        }
        throw lastError
    }

    static func extractImage(from lines: AsyncThrowingStream<String, Error>) async throws -> Data {
        for try await raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ImageGenerationCallEvent.self, from: payloadData) else { continue }
            if event.type.localizedCaseInsensitiveContains("failed") || event.type.localizedCaseInsensitiveContains("error") {
                throw ChatGPTSubscriptionImageError.streamFailed(event.type)
            }
            guard event.type == "response.output_item.done",
                  event.item?.type == "image_generation_call",
                  let base64 = event.item?.result,
                  let data = Data(base64Encoded: base64) else { continue }
            return data
        }
        throw ChatGPTSubscriptionImageError.noImageProduced
    }

    private func makeURLRequest(_ request: ChatGPTImageGenerationRequest, accessToken: String, accountID: String?, orchestrationModel: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: ChatGPTSubscriptionImageConfig.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
        urlRequest.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        let sessionID = sessionIDProvider()
        urlRequest.setValue(sessionID, forHTTPHeaderField: "session_id")
        urlRequest.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        urlRequest.setValue("codex_cli_rs/0.1.0 (Mac OS; arm64) GenStudio", forHTTPHeaderField: "User-Agent")
        if let accountID { urlRequest.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id") }

        var content: [[String: Any]] = request.references.map { reference in
            ["type": "input_image", "image_url": "data:\(reference.mimeType);base64,\(reference.data.base64EncodedString())"]
        }
        content.append(["type": "input_text", "text": request.prompt])

        let body: [String: Any] = [
            "model": orchestrationModel,
            "stream": true,
            "instructions": "You are an image generation assistant.",
            "input": [["type": "message", "role": "user", "content": content]],
            "tools": [[
                "type": "image_generation",
                "model": ChatGPTSubscriptionImageConfig.imageModel,
                "output_format": request.outputFormat,
                "size": request.size
            ]],
            "tool_choice": request.references.isEmpty ? "auto" : "required",
            "parallel_tool_calls": false,
            "store": false,
            "reasoning": ["effort": "low", "summary": "auto"],
            "text": ["verbosity": "low"]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }
}
