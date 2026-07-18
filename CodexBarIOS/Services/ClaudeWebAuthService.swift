import CryptoKit
import Foundation
import Network
import Security

public struct ClaudeWebAuthResult: Equatable, Sendable {
    public let credentials: ClaudeCredentials

    public var storedCredential: String {
        ClaudeCredentialsParser.storedCredential(from: credentials)
    }
}

public final class ClaudeWebAuthService: Sendable {
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
                "Could not start the local Claude login callback server."
            case .missingAuthorizationCode:
                "Claude sign-in did not return an authorization code."
            case .stateMismatch:
                "Claude sign-in returned an unexpected state value."
            case .callbackTimedOut:
                "Claude sign-in did not return to the app. Try again, and make sure you continue all the way through Claude in the browser."
            case .tokenExchangeFailed(let message):
                "Claude token exchange failed: \(message)"
            case .invalidTokenResponse:
                "Claude token exchange returned an invalid response."
            }
        }
    }

    public struct PKCEPair: Equatable, Sendable {
        public let codeVerifier: String
        public let codeChallenge: String
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int64?
        let expiresAt: Int64?
        let subscriptionType: String?
        let rateLimitTier: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case subscriptionType = "subscription_type"
            case rateLimitTier = "rate_limit_tier"
            case error
        }
    }

    private static let authorizationBaseURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let callbackPath = "/callback"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let requestedScope = "org:create_api_key user:profile user:inference user:sessions:claude_code"
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
    public func signIn(
        presentAuthorizationURL: @escaping @MainActor (URL) -> Void,
        reportStage: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> ClaudeWebAuthResult {
        reportStage("Starting Claude sign-in...")
        let state = Self.randomBase64URL(byteCount: 32)
        let pkce = Self.makePKCEPair()
        reportStage("Starting local callback server...")
        let callbackServer = try await ClaudeOAuthCallbackServer.start(
            preferredPorts: [1461, 1462, 1463],
            expectedState: state,
            callbackPath: Self.callbackPath
        )
        defer {
            callbackServer.cancel()
        }

        let redirectURI = "http://localhost:\(callbackServer.port)\(Self.callbackPath)"
        reportStage("Opening Claude in the browser. Callback: localhost:\(callbackServer.port).")
        let authorizationURL = Self.authorizationURL(
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.codeChallenge
        )

        presentAuthorizationURL(authorizationURL)
        reportStage("Waiting for Claude to return to the app...")
        let callbackURL = try await callbackServer.waitForCallback(
            timeoutNanoseconds: callbackTimeoutNanoseconds
        )
        reportStage("Claude returned to the app. Exchanging authorization code...")

        let result = try await exchangeCallbackForTokens(
            callbackURL: callbackURL,
            redirectURI: redirectURI,
            state: state,
            pkce: pkce
        )
        reportStage("Claude token exchange succeeded.")
        return result
    }

    public static func authorizationURL(
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: authorizationBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requestedScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    public static func makeTokenRequestBody(
        code: String,
        redirectURI: String,
        state: String,
        codeVerifier: String
    ) -> Data {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
            "state": state
        ]
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    public static func makePKCEPair() -> PKCEPair {
        let verifier = randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncodedString(Data(digest))
        return PKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    private func exchangeCallbackForTokens(
        callbackURL: URL,
        redirectURI: String,
        state: String,
        pkce: PKCEPair
    ) async throws -> ClaudeWebAuthResult {
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.claudeQueryItemValue(named: "state") == state
        else {
            throw AuthError.stateMismatch
        }

        guard let code = components.claudeQueryItemValue(named: "code"), !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        let result = try await exchangeCodeForTokens(
            code: code,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: pkce.codeVerifier
        )
        return result
    }

    private func exchangeCodeForTokens(
        code: String,
        redirectURI: String,
        state: String,
        codeVerifier: String
    ) async throws -> ClaudeWebAuthResult {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = Self.makeTokenRequestBody(
            code: code,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: codeVerifier
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidTokenResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthError.tokenExchangeFailed(
                TokenEndpointErrorFormatter.message(statusCode: httpResponse.statusCode, body: data)
            )
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidTokenResponse
        }

        if let error = tokenResponse.error {
            throw AuthError.tokenExchangeFailed(TokenEndpointErrorFormatter.message(errorCode: error))
        }

        guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
            throw AuthError.invalidTokenResponse
        }

        let expiresAt = tokenResponse.expiresAt
            ?? tokenResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)).claudeUnixTimeMilliseconds }
            ?? 0
        let credentials = ClaudeCredentials(
            subscriptionType: tokenResponse.subscriptionType ?? "subscription",
            rateLimitTier: tokenResponse.rateLimitTier,
            expiresAt: expiresAt,
            accessToken: accessToken,
            refreshToken: tokenResponse.refreshToken
        )

        return ClaudeWebAuthResult(credentials: credentials)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncodedString(Data(bytes))
    }

    private static func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class ClaudeOAuthCallbackServer: @unchecked Sendable {
    let port: UInt16

    private let expectedState: String
    private let callbackPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hemsoft.CodexBarIOS.claudeOAuthCallback")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?

    private init(port: UInt16, expectedState: String, callbackPath: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ClaudeWebAuthService.AuthError.couldNotStartCallbackServer
        }

        self.port = port
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: Self.preferredLocalhostLoopbackHost(),
            port: nwPort
        )
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
    ) async throws -> ClaudeOAuthCallbackServer {
        var lastError: Error = ClaudeWebAuthService.AuthError.couldNotStartCallbackServer
        for port in preferredPorts {
            do {
                let server = try ClaudeOAuthCallbackServer(
                    port: port,
                    expectedState: expectedState,
                    callbackPath: callbackPath
                )
                try await server.start()
                return server
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeoutNanoseconds: UInt64) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.resumeCallback(with: .failure(ClaudeWebAuthService.AuthError.callbackTimedOut))
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

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            resumeReady(with: .success(()))
        case .failed(let error):
            resumeReady(with: .failure(error))
            resumeCallback(with: .failure(error))
        case .cancelled:
            resumeReady(with: .failure(ClaudeWebAuthService.AuthError.couldNotStartCallbackServer))
            resumeCallback(with: .failure(ClaudeWebAuthService.AuthError.missingAuthorizationCode))
        default:
            break
        }
    }

    private static func preferredLocalhostLoopbackHost() -> NWEndpoint.Host {
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("localhost", nil, nil, &addresses) == 0, let addresses else {
            return .ipv4(.loopback)
        }
        defer { freeaddrinfo(addresses) }

        var address: UnsafeMutablePointer<addrinfo>? = addresses
        while let candidate = address {
            switch candidate.pointee.ai_family {
            case AF_INET6:
                return .ipv6(.loopback)
            case AF_INET:
                return .ipv4(.loopback)
            default:
                address = candidate.pointee.ai_next
            }
        }
        return .ipv4(.loopback)
    }

    private func resumeReady(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func resumeCallback(with result: Result<URL, Error>) {
        lock.lock()
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }

        pendingCallbackResult = result
        lock.unlock()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
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

            self.resumeCallback(with: result)
        }
    }

    private func parseCallbackURL(from request: String) -> Result<URL, Error> {
        guard
            let requestLine = request.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET "),
            let pathStart = requestLine.firstIndex(of: " "),
            let pathEnd = requestLine[requestLine.index(after: pathStart)...].firstIndex(of: " ")
        else {
            return .failure(ClaudeWebAuthService.AuthError.missingAuthorizationCode)
        }

        let path = String(requestLine[requestLine.index(after: pathStart)..<pathEnd])
        guard path.hasPrefix(callbackPath) else {
            return .failure(ClaudeWebAuthService.AuthError.missingAuthorizationCode)
        }

        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            return .failure(ClaudeWebAuthService.AuthError.missingAuthorizationCode)
        }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.claudeQueryItemValue(named: "state") == expectedState
        else {
            return .failure(ClaudeWebAuthService.AuthError.stateMismatch)
        }

        guard components.claudeQueryItemValue(named: "code")?.isEmpty == false else {
            return .failure(ClaudeWebAuthService.AuthError.missingAuthorizationCode)
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
            <body><h1>Claude sign-in complete</h1><p>You can return to CodexBar.</p></body></html>
            """
        case .failure(let error):
            statusLine = "HTTP/1.1 400 Bad Request"
            body = """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body><h1>Claude sign-in failed</h1><p>\(error.localizedDescription)</p></body></html>
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
    func claudeQueryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension Date {
    var claudeUnixTimeMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
