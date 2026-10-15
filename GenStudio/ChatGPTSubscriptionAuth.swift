import Foundation
import CryptoKit
import Network
import AppKit

/// Experimental, unofficial integration: lets a signed-in ChatGPT Plus/Pro/Business
/// subscription generate images inside GenStudio, billed to that subscription instead
/// of a metered API key. This reuses the same OAuth client Codex CLI (OpenAI's own
/// open-source coding agent) uses to authenticate against `auth.openai.com`, then
/// calls the same internal `chatgpt.com/backend-api/codex` endpoint Codex CLI uses for
/// its image-generation tool. Neither endpoint is documented or supported for
/// third-party use; OpenAI could change or block it without notice, and using it risks
/// the signed-in account being rate-limited or flagged. See ChatGPTSubscriptionSettingsView.
enum ChatGPTSubscriptionOAuthConfig {
    /// OpenAI's public Codex CLI client id. Not a secret: it is a native-app PKCE
    /// client with no client_secret, published in Codex CLI's own open-source code
    /// (openai/codex, codex-rs/login), and reused as-is by community tools such as
    /// CLIProxyAPI and codex-imagen. GenStudio does not invent or spoof a client id.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let authorizeURL = URL(string: "\(issuer)/oauth/authorize")!
    static let tokenURL = URL(string: "\(issuer)/oauth/token")!
    static let authorizeScopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    static let refreshScope = "openid profile email"
    static let loopbackPorts: [UInt16] = [1455, 1457]
    static let callbackPath = "/auth/callback"
}

struct ChatGPTSubscriptionTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var accountID: String?
    var email: String?
    var expiresAt: Date
}

enum ChatGPTSubscriptionAuthError: Error, Sendable, CustomStringConvertible {
    case notSignedIn
    case browserOpenFailed
    case cancelled
    case timedOut
    case stateMismatch
    case tokenExchangeFailed(statusCode: Int)
    case refreshFailed(statusCode: Int)
    case malformedResponse
    case networkFailure
    case credentialStoreFailure

    var description: String {
        switch self {
        case .notSignedIn: "Not signed in to a ChatGPT subscription."
        case .browserOpenFailed: "Could not open the sign-in page in your browser."
        case .cancelled: "Sign-in was cancelled."
        case .timedOut: "Sign-in timed out waiting for the browser to complete."
        case .stateMismatch: "The sign-in response did not match this sign-in attempt. Try again."
        case let .tokenExchangeFailed(status): "OpenAI rejected the sign-in (HTTP \(status)). This unofficial integration may have broken."
        case let .refreshFailed(status): "OpenAI rejected the session refresh (HTTP \(status)). Sign in again."
        case .malformedResponse: "OpenAI's response could not be read. This unofficial integration may have broken."
        case .networkFailure: "The network request failed."
        case .credentialStoreFailure: "The stored ChatGPT sign-in could not be read or written."
        }
    }
}

// MARK: - Injectable collaborators (mirrors GenStudio's existing CloudTransport testability pattern)

protocol ChatGPTOAuthTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionChatGPTOAuthTransport: ChatGPTOAuthTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTSubscriptionAuthError.networkFailure }
        return (data, http)
    }
}

protocol ChatGPTSubscriptionCredentialStore: Sendable {
    func load() throws -> ChatGPTSubscriptionTokens?
    func save(_ tokens: ChatGPTSubscriptionTokens) throws
    func clear() throws
}

/// Stores the whole token set as one JSON blob under a single Keychain item,
/// matching KeychainCredentialStore's account/service pattern in spirit.
struct KeychainChatGPTSubscriptionStore: ChatGPTSubscriptionCredentialStore, Sendable {
    private static let service = "studio.gen.GenStudio.ChatGPTSubscription"
    private static let account = "chatgpt-subscription-tokens"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func load() throws -> ChatGPTSubscriptionTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ChatGPTSubscriptionAuthError.credentialStoreFailure
        }
        return try? JSONDecoder().decode(ChatGPTSubscriptionTokens.self, from: data)
    }

    func save(_ tokens: ChatGPTSubscriptionTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw ChatGPTSubscriptionAuthError.credentialStoreFailure }
        var newItem = baseQuery
        newItem[kSecValueData as String] = data
        guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else {
            throw ChatGPTSubscriptionAuthError.credentialStoreFailure
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChatGPTSubscriptionAuthError.credentialStoreFailure
        }
    }
}

protocol SystemBrowserOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

struct DefaultSystemBrowserOpener: SystemBrowserOpening {
    func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

struct OAuthCallbackResult: Sendable, Equatable {
    let code: String
    let state: String
}

protocol OAuthLoopbackListening: Sendable {
    /// Binds a local HTTP listener, waits for exactly one browser redirect to
    /// `http://localhost:{port}/auth/callback?...`, and returns the query it received.
    func awaitCallback(ports: [UInt16], path: String, timeout: Duration) async throws -> OAuthCallbackResult
}

// MARK: - PKCE

enum PKCE {
    struct Pair: Sendable, Equatable { let verifier: String; let challenge: String }

    static func generate() -> Pair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(digest))
        return Pair(verifier: verifier, challenge: challenge)
    }

    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Decodes an unverified JWT payload (no signature check: this is a client reading its
/// own freshly-issued token to pull a display claim, not validating a third party's).
enum JWTPayload {
    static func decode(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// Codex CLI reads the ChatGPT account id from a namespaced claim it adds to the
    /// id_token. The exact claim shape is undocumented outside OpenAI's own code, so
    /// this checks the known namespaced location first and falls back to a couple of
    /// plausible flat claim names.
    static func chatGPTAccountID(fromIDToken idToken: String) -> String? {
        guard let payload = decode(idToken) else { return nil }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let accountID = auth["chatgpt_account_id"] as? String { return accountID }
        return (payload["chatgpt_account_id"] as? String) ?? (payload["account_id"] as? String)
    }

    static func email(fromIDToken idToken: String) -> String? {
        decode(idToken)?["email"] as? String
    }
}

// MARK: - Authenticator

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token", expiresIn = "expires_in"
    }
}

actor ChatGPTSubscriptionAuthenticator {
    private let store: any ChatGPTSubscriptionCredentialStore
    private let transport: any ChatGPTOAuthTransport
    private let browser: any SystemBrowserOpening
    private let loopback: any OAuthLoopbackListening

    init(
        store: any ChatGPTSubscriptionCredentialStore = KeychainChatGPTSubscriptionStore(),
        transport: any ChatGPTOAuthTransport = URLSessionChatGPTOAuthTransport(),
        browser: any SystemBrowserOpening = DefaultSystemBrowserOpener(),
        loopback: any OAuthLoopbackListening = NWLoopbackOAuthListener()
    ) {
        self.store = store
        self.transport = transport
        self.browser = browser
        self.loopback = loopback
    }

    func hasStoredSession() throws -> Bool {
        try store.load() != nil
    }

    func storedAccountLabel() throws -> String? {
        guard let tokens = try store.load() else { return nil }
        return tokens.email ?? tokens.accountID
    }

    @discardableResult
    func signIn(timeout: Duration = .seconds(300)) async throws -> String? {
        let pkce = PKCE.generate()
        let state = PKCE.randomState()
        guard let authorizeURL = makeAuthorizeURL(pkce: pkce, state: state) else { throw ChatGPTSubscriptionAuthError.malformedResponse }
        guard await browser.open(authorizeURL) else { throw ChatGPTSubscriptionAuthError.browserOpenFailed }
        let callback = try await loopback.awaitCallback(
            ports: ChatGPTSubscriptionOAuthConfig.loopbackPorts,
            path: ChatGPTSubscriptionOAuthConfig.callbackPath,
            timeout: timeout
        )
        guard callback.state == state else { throw ChatGPTSubscriptionAuthError.stateMismatch }
        let redirectURI = "http://localhost:\(ChatGPTSubscriptionOAuthConfig.loopbackPorts[0])\(ChatGPTSubscriptionOAuthConfig.callbackPath)"
        let tokens = try await exchangeCode(callback.code, verifier: pkce.verifier, redirectURI: redirectURI)
        try store.save(tokens)
        return tokens.email ?? tokens.accountID
    }

    func signOut() throws {
        try store.clear()
    }

    /// Returns a currently-valid access token plus the account id used for the
    /// `chatgpt-account-id` header, refreshing first if the stored token is expiring.
    func validSession() async throws -> (accessToken: String, accountID: String?) {
        guard var tokens = try store.load() else { throw ChatGPTSubscriptionAuthError.notSignedIn }
        if tokens.expiresAt > Date().addingTimeInterval(60) {
            return (tokens.accessToken, tokens.accountID)
        }
        do {
            tokens = try await refresh(tokens)
            try store.save(tokens)
            return (tokens.accessToken, tokens.accountID)
        } catch {
            try? store.clear()
            throw error
        }
    }

    private func makeAuthorizeURL(pkce: PKCE.Pair, state: String) -> URL? {
        var components = URLComponents(url: ChatGPTSubscriptionOAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)
        let redirectURI = "http://localhost:\(ChatGPTSubscriptionOAuthConfig.loopbackPorts[0])\(ChatGPTSubscriptionOAuthConfig.callbackPath)"
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: ChatGPTSubscriptionOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: ChatGPTSubscriptionOAuthConfig.authorizeScopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> ChatGPTSubscriptionTokens {
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": ChatGPTSubscriptionOAuthConfig.clientID,
            "code_verifier": verifier
        ]
        let (data, response) = try await post(form: form)
        guard (200..<300).contains(response.statusCode) else { throw ChatGPTSubscriptionAuthError.tokenExchangeFailed(statusCode: response.statusCode) }
        return try makeTokens(from: data)
    }

    private func refresh(_ current: ChatGPTSubscriptionTokens) async throws -> ChatGPTSubscriptionTokens {
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": ChatGPTSubscriptionOAuthConfig.clientID,
            "scope": ChatGPTSubscriptionOAuthConfig.refreshScope
        ]
        let (data, response) = try await post(form: form)
        guard (200..<300).contains(response.statusCode) else { throw ChatGPTSubscriptionAuthError.refreshFailed(statusCode: response.statusCode) }
        var tokens = try makeTokens(from: data)
        // A refresh response sometimes omits refresh_token/id_token when unchanged.
        if tokens.refreshToken.isEmpty { tokens.refreshToken = current.refreshToken }
        if tokens.idToken.isEmpty { tokens.idToken = current.idToken; tokens.accountID = current.accountID; tokens.email = current.email }
        return tokens
    }

    private func post(form: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: ChatGPTSubscriptionOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
        do {
            return try await transport.send(request)
        } catch let error as ChatGPTSubscriptionAuthError {
            throw error
        } catch {
            throw ChatGPTSubscriptionAuthError.networkFailure
        }
    }

    private func makeTokens(from data: Data) throws -> ChatGPTSubscriptionTokens {
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ChatGPTSubscriptionAuthError.malformedResponse
        }
        let idToken = response.idToken ?? ""
        let expiresIn = response.expiresIn ?? 3600
        return ChatGPTSubscriptionTokens(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken ?? "",
            idToken: idToken,
            accountID: idToken.isEmpty ? nil : JWTPayload.chatGPTAccountID(fromIDToken: idToken),
            email: idToken.isEmpty ? nil : JWTPayload.email(fromIDToken: idToken),
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}

// MARK: - Real loopback listener (Network framework)

/// A single-shot local HTTP server: binds the first free port from `ports`, accepts one
/// connection, parses the redirected `GET /auth/callback?code=...&state=...` request
/// line, answers with a small HTML page telling the user to return to GenStudio, then
/// tears itself down. This exists because auth.openai.com only accepts the exact
/// `http://localhost:{1455,1457}/auth/callback` redirect URIs Codex CLI registered;
/// GenStudio cannot use a custom URL scheme instead.
final class NWLoopbackOAuthListener: OAuthLoopbackListening, @unchecked Sendable {
    func awaitCallback(ports: [UInt16], path: String, timeout: Duration) async throws -> OAuthCallbackResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.start(ports: ports, path: path, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            // Best-effort: the listener also self-tears-down on completion/timeout.
        }
    }

    private func start(ports: [UInt16], path: String, timeout: Duration, continuation: CheckedContinuation<OAuthCallbackResult, Error>) {
        guard let port = ports.first.flatMap({ NWEndpoint.Port(rawValue: $0) }),
              let listener = try? NWListener(using: .tcp, on: port) else {
            guard let fallbackPort = ports.dropFirst().first.flatMap({ NWEndpoint.Port(rawValue: $0) }),
                  let fallbackListener = try? NWListener(using: .tcp, on: fallbackPort) else {
                continuation.resume(throwing: ChatGPTSubscriptionAuthError.networkFailure)
                return
            }
            run(listener: fallbackListener, path: path, timeout: timeout, continuation: continuation)
            return
        }
        run(listener: listener, path: path, timeout: timeout, continuation: continuation)
    }

    private func run(listener: NWListener, path: String, timeout: Duration, continuation: CheckedContinuation<OAuthCallbackResult, Error>) {
        let queue = DispatchQueue(label: "genstudio.chatgpt-oauth-loopback")
        let finisher = CallbackFinisher(listener: listener, continuation: continuation)

        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.receiveRequestLine(connection: connection) { requestLine in
                Self.respond(connection: connection)
                guard let requestLine,
                      let callback = Self.parseCallback(requestLine: requestLine, expectedPath: path) else {
                    finisher.finish(.failure(ChatGPTSubscriptionAuthError.malformedResponse))
                    return
                }
                finisher.finish(.success(callback))
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state { finisher.finish(.failure(ChatGPTSubscriptionAuthError.networkFailure)) }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) {
            finisher.finish(.failure(ChatGPTSubscriptionAuthError.timedOut))
        }
    }

    /// A reference type so it can be captured once and shared across the listener's
    /// several independent @Sendable callback closures, guarding against more than
    /// one of them resuming `continuation`.
    private final class CallbackFinisher: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let listener: NWListener
        private let continuation: CheckedContinuation<OAuthCallbackResult, Error>

        init(listener: NWListener, continuation: CheckedContinuation<OAuthCallbackResult, Error>) {
            self.listener = listener
            self.continuation = continuation
        }

        func finish(_ result: Result<OAuthCallbackResult, Error>) {
            lock.lock()
            let alreadyFinished = finished
            finished = true
            lock.unlock()
            guard !alreadyFinished else { return }
            listener.cancel()
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
    }

    private static func receiveRequestLine(connection: NWConnection, buffer: Data = Data(), completion: @escaping @Sendable (String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let text = String(data: accumulated, encoding: .utf8),
               let headerEnd = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n") {
                completion(String(text[text.startIndex..<headerEnd.lowerBound]))
                return
            }
            if isComplete || error != nil || accumulated.count > 65536 {
                completion(String(data: accumulated, encoding: .utf8))
                return
            }
            receiveRequestLine(connection: connection, buffer: accumulated, completion: completion)
        }
    }

    private static func respond(connection: NWConnection) {
        let body = "<html><body style='font: -apple-system-body; padding:40px'>GenStudio is connected. You can close this tab.</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parseCallback(requestLine: String, expectedPath: String) -> OAuthCallbackResult? {
        guard let firstLine = requestLine.split(separator: "\r\n").first ?? requestLine.split(separator: "\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)"), components.path == expectedPath else { return nil }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value else { return nil }
        return OAuthCallbackResult(code: code, state: state)
    }
}
