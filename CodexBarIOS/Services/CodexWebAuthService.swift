import CryptoKit
import Foundation
import Network
import Security

public struct CodexWebAuthResult: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountID: String?
    public let expiresAt: Int64?

    public var storedCredential: String {
        CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            expiresAt: expiresAt
        ))
    }
}

public struct CodexPKCEPair: Equatable, Sendable {
    public let codeVerifier: String
    public let codeChallenge: String
}

public final class CodexWebAuthService: Sendable {
    public enum AuthError: LocalizedError, Equatable {
        case couldNotStartCallbackServer
        case missingAuthorizationCode
        case stateMismatch
        case callbackTimedOut
        case tokenExchangeFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .couldNotStartCallbackServer:
                "Could not start the local login callback server."
            case .missingAuthorizationCode:
                "ChatGPT sign-in did not return an authorization code."
            case .stateMismatch:
                "ChatGPT sign-in returned an unexpected state value."
            case .callbackTimedOut:
                "ChatGPT sign-in did not return to the app. Try again and complete sign-in in the browser."
            case .tokenExchangeFailed(let message):
                "ChatGPT token exchange failed: \(message)"
            case .invalidTokenResponse:
                "ChatGPT token exchange returned an invalid response."
            }
        }
    }

    private struct TokenResponse: Decodable {
        let idToken: String?
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int64?
        let expiresAt: Int64?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
        }
    }

    private static let callbackPath = "/auth/callback"
    private static let issuer = URL(string: "https://auth.openai.com")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let tokenEndpoint = issuer.appending(path: "/oauth/token")
    private static let originator = "codex_cli_rs"
    private let session: URLSession
    private let callbackTimeoutNanoseconds: UInt64

    public init(
        session: URLSession = .shared,
        callbackTimeoutNanoseconds: UInt64 = 180_000_000_000
    ) {
        self.session = session
        self.callbackTimeoutNanoseconds = callbackTimeoutNanoseconds
    }

    @MainActor
    public func signIn(presentAuthorizationURL: @escaping @MainActor (URL) -> Void) async throws -> CodexWebAuthResult {
        let state = Self.randomBase64URL(byteCount: 32)
        let pkce = Self.makePKCEPair()
        let callbackServer = try await CodexOAuthCallbackServer.start(
            preferredPorts: [1455, 1457],
            expectedState: state,
            callbackPath: Self.callbackPath
        )
        defer {
            callbackServer.cancel()
        }

        let redirectURI = "http://localhost:\(callbackServer.port)\(Self.callbackPath)"
        let authorizationURL = Self.authorizationURL(
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.codeChallenge
        )

        presentAuthorizationURL(authorizationURL)

        let callbackURL = try await callbackServer.waitForCallback(
            timeoutNanoseconds: callbackTimeoutNanoseconds
        )
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.queryItemValue(named: "state") == state
        else {
            throw AuthError.stateMismatch
        }

        guard let code = components.queryItemValue(named: "code"), !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        return try await exchangeCodeForTokens(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: pkce.codeVerifier
        )
    }

    public static func authorizationURL(
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: issuer.appending(path: "/oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: originator)
        ]
        return components.url!
    }

    public static func makeTokenRequestBody(
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) -> Data {
        formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier)
        ])
    }

    public static func makeRefreshTokenRequestBody(refreshToken: String) -> Data {
        formEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
    }

    public static func makePKCEPair() -> CodexPKCEPair {
        let verifier = randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return CodexPKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    public static func accountID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        guard
            let payloadData = Data(base64URLString: String(parts[1])),
            let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        return root["chatgpt_account_id"] as? String
    }

    private func exchangeCodeForTokens(
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CodexWebAuthResult {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.makeTokenRequestBody(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidTokenResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode)")
        }

        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidTokenResponse
        }

        let now = Date()
        let parsedAccessToken = CodexCredentialsParser.parse(tokens.accessToken)
        let parsedIDToken = tokens.idToken.flatMap(CodexCredentialsParser.parse)
        return CodexWebAuthResult(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            accountID: tokens.idToken.flatMap(Self.accountID) ?? Self.accountID(from: tokens.accessToken),
            expiresAt: tokens.expiresAt.map(CodexCredentials.normalizedEpochSeconds)
                ?? tokens.expiresIn.map { Int64(now.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970) }
                ?? parsedAccessToken?.expiresAt
                ?? parsedIDToken?.expiresAt
        )
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let encoded = pairs
            .map { "\($0.0.urlFormEncoded)=\($0.1.urlFormEncoded)" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}

private final class CodexOAuthCallbackServer: @unchecked Sendable {
    let port: UInt16

    private let expectedState: String
    private let callbackPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hemsoft.CodexBarIOS.codexOAuthCallback")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?

    private init(port: UInt16, expectedState: String, callbackPath: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CodexWebAuthService.AuthError.couldNotStartCallbackServer
        }

        self.port = port
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        self.listener = try NWListener(using: parameters)
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
    }

    static func start(
        preferredPorts: [UInt16],
        expectedState: String,
        callbackPath: String
    ) async throws -> CodexOAuthCallbackServer {
        var lastError: Error = CodexWebAuthService.AuthError.couldNotStartCallbackServer
        for port in preferredPorts {
            do {
                let server = try CodexOAuthCallbackServer(
                    port: port,
                    expectedState: expectedState,
                    callbackPath: callbackPath
                )
                try await server.startListening()
                return server
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    func waitForCallback(timeoutNanoseconds: UInt64) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.finishCallback(.failure(CodexWebAuthService.AuthError.callbackTimedOut))
        }
        defer {
            timeoutTask.cancel()
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingCallbackResult {
                self.pendingCallbackResult = nil
                lock.unlock()
                continuation.resume(with: pendingCallbackResult)
                return
            }

            callbackContinuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        listener.cancel()
    }

    private func startListening() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.start(queue: queue)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            finishReady(.success(()))
        case .failed(let error):
            finishReady(.failure(error))
            finishCallback(.failure(error))
        case .cancelled:
            finishReady(.failure(CodexWebAuthService.AuthError.couldNotStartCallbackServer))
            finishCallback(.failure(CodexWebAuthService.AuthError.missingAuthorizationCode))
        default:
            break
        }
    }

    private func finishReady(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        lock.lock()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingCallbackResult = result
            lock.unlock()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let result = self.parseCallbackURL(from: request)
            let response = self.httpResponse(for: result)

            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if case .success(let url) = result {
                self.finishCallback(.success(url))
            } else if case .failure(let error) = result {
                self.finishCallback(.failure(error))
            }
        }
    }

    private func parseCallbackURL(from request: String) -> Result<URL, Error> {
        guard
            let requestLine = request.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET "),
            let pathStart = requestLine.firstIndex(of: " "),
            let pathEnd = requestLine[requestLine.index(after: pathStart)...].firstIndex(of: " ")
        else {
            return .failure(CodexWebAuthService.AuthError.missingAuthorizationCode)
        }

        let path = String(requestLine[requestLine.index(after: pathStart)..<pathEnd])
        guard path.hasPrefix(callbackPath) else {
            return .failure(CodexWebAuthService.AuthError.missingAuthorizationCode)
        }

        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            return .failure(CodexWebAuthService.AuthError.missingAuthorizationCode)
        }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItemValue(named: "state") == expectedState
        else {
            return .failure(CodexWebAuthService.AuthError.stateMismatch)
        }

        guard components.queryItemValue(named: "code")?.isEmpty == false else {
            return .failure(CodexWebAuthService.AuthError.missingAuthorizationCode)
        }

        return .success(url)
    }

    private func httpResponse(for result: Result<URL, Error>) -> String {
        let statusLine: String
        let body: String

        switch result {
        case .success:
            statusLine = "HTTP/1.1 200 OK"
            body = """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body><h1>Sign-in complete</h1><p>You can return to CodexBar.</p></body></html>
            """
        case .failure(let error):
            statusLine = "HTTP/1.1 400 Bad Request"
            body = """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body><h1>Sign-in failed</h1><p>\(error.localizedDescription)</p></body></html>
            """
        }

        return """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}

private extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlFormAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlFormAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}

private extension Data {
    init?(base64URLString: String) {
        var base64 = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }

        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
