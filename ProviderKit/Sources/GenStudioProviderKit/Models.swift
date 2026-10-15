import Foundation

public enum CloudProvider: String, CaseIterable, Sendable {
    case openAI
    case anthropic
}

public struct CloudTextRequest: Sendable, Equatable {
    public let provider: CloudProvider
    public let model: String
    public let prompt: String
    public let maxOutputTokens: Int

    public init(provider: CloudProvider, model: String, prompt: String, maxOutputTokens: Int) {
        self.provider = provider
        self.model = model
        self.prompt = prompt
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct CloudTextResult: Sendable, Equatable {
    public let provider: CloudProvider
    public let text: String
    public let stopReason: String?

    public init(provider: CloudProvider, text: String, stopReason: String?) {
        self.provider = provider
        self.text = text
        self.stopReason = stopReason
    }
}

public enum CloudProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidAPIKey
    case invalidModel
    case invalidPrompt
    case invalidMaxOutputTokens
    case missingCredential(CloudProvider)
    case authenticationFailed
    case rateLimited
    case serverUnavailable
    case requestRejected(statusCode: Int)
    case malformedResponse
    case incomplete(reason: String?)
    case providerFailed
    case refused
    case emptyResult
    case networkFailure
    case credentialStoreFailure

    public var description: String {
        switch self {
        case .invalidAPIKey: "The API key is empty."
        case .invalidModel: "The model identifier is empty."
        case .invalidPrompt: "The prompt is empty."
        case .invalidMaxOutputTokens: "The output token limit must be between 1 and 1,000,000."
        case let .missingCredential(provider): "No credential is stored for \(provider.rawValue)."
        case .authenticationFailed: "The provider rejected the credential."
        case .rateLimited: "The provider rate limit was reached."
        case .serverUnavailable: "The provider service is unavailable."
        case let .requestRejected(statusCode): "The provider rejected the request (HTTP \(statusCode))."
        case .malformedResponse: "The provider returned an unreadable response."
        case let .incomplete(reason): reason.map { "The provider response was incomplete (\($0))." } ?? "The provider response was incomplete."
        case .providerFailed: "The provider could not complete the request."
        case .refused: "The provider refused the request."
        case .emptyResult: "The provider returned no text."
        case .networkFailure: "The network request failed."
        case .credentialStoreFailure: "The credential could not be accessed."
        }
    }
}
