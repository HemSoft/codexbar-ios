import CryptoKit
import Foundation
import Network
import Security

public struct CopilotWebAuthResult: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Int64?
    public let refreshTokenExpiresAt: Int64?

    public func storedCredential(username: String? = nil) -> String {
        CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: accessToken,
            username: username,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt
        ))
    }
}

public struct CopilotOAuthConfiguration: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public static var bundled: CopilotOAuthConfiguration {
        let environment = ProcessInfo.processInfo.environment
        return CopilotOAuthConfiguration(
            clientID: environment["CODEXBAR_COPILOT_OAUTH_CLIENT_ID"]
                ?? Bundle.main.object(forInfoDictionaryKey: "CODEXBAR_COPILOT_OAUTH_CLIENT_ID") as? String
                ?? "178c6fc778ccc68e1d6a",
            clientSecret: environment["CODEXBAR_COPILOT_OAUTH_CLIENT_SECRET"]
                ?? Bundle.main.object(forInfoDictionaryKey: "CODEXBAR_COPILOT_OAUTH_CLIENT_SECRET") as? String
                ?? "34ddeff2b558a23d38fba8a6de74f086ede1cc0b"
        )
    }

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public final class CopilotWebAuthService: Sendable {
    public enum AuthError: LocalizedError, Equatable {
        case couldNotStartCallbackServer
        case missingOAuthConfiguration
        case missingAuthorizationCode
        case stateMismatch
        case tokenExchangeFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .couldNotStartCallbackServer:
                "Could not start the local GitHub login callback server."
            case .missingOAuthConfiguration:
                "GitHub sign-in is not configured in this build."
            case .missingAuthorizationCode:
                "GitHub sign-in did not return an authorization code."
            case .stateMismatch:
                "GitHub sign-in returned an unexpected state value."
            case .tokenExchangeFailed(let message):
                "GitHub token exchange failed: \(message)"
            case .invalidTokenResponse:
                "GitHub token exchange returned an invalid response."
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
        let refreshTokenExpiresIn: Int64?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case error
            case errorDescription = "error_description"
        }
    }

    private static let githubBaseURL = URL(string: "https://github.com")!
    static let tokenEndpoint = githubBaseURL.appending(path: "/login/oauth/access_token")
    private static let callbackPath = "/callback"
    private static let requestedScope = "repo read:org gist"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    @MainActor
    public func signIn(
        configuration: CopilotOAuthConfiguration,
        presentAuthorizationURL: @escaping @MainActor (URL) -> Void
    ) async throws -> CopilotWebAuthResult {
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = configuration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !clientID.isEmpty,
            !clientSecret.isEmpty
        else {
            throw AuthError.missingOAuthConfiguration
        }

        let state = Self.randomBase64URL(byteCount: 32)
        let pkce = Self.makePKCEPair()
        let callbackServer = try await CopilotOAuthCallbackServer.start(
            preferredPorts: [1456, 1458, 1460],
            expectedState: state,
            callbackPath: Self.callbackPath
        )
        defer {
            callbackServer.cancel()
        }

        let redirectURI = "http://127.0.0.1:\(callbackServer.port)\(Self.callbackPath)"
        let authorizationURL = Self.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.codeChallenge
        )

        presentAuthorizationURL(authorizationURL)
        let callbackURL = try await callbackServer.waitForCallback()

        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.queryItemValue(named: "state") == state
        else {
            throw AuthError.stateMismatch
        }

        guard let code = components.queryItemValue(named: "code"), !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        return try await exchangeCodeForToken(
            clientID: clientID,
            clientSecret: clientSecret,
            code: code,
            redirectURI: redirectURI,
            codeVerifier: pkce.codeVerifier
        )
    }

    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: githubBaseURL.appending(path: "/login/oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requestedScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        return components.url!
    }

    public static func makeTokenRequestBody(
        clientID: String,
        clientSecret: String,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) -> Data {
        formEncoded([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier)
        ])
    }

    public static func makeRefreshTokenRequestBody(
        clientID: String,
        clientSecret: String,
        refreshToken: String
    ) -> Data {
        formEncoded([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    public static func makePKCEPair() -> PKCEPair {
        let verifier = randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return PKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    private func exchangeCodeForToken(
        clientID: String,
        clientSecret: String,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CopilotWebAuthResult {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.makeTokenRequestBody(
            clientID: clientID,
            clientSecret: clientSecret,
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

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidTokenResponse
        }

        if let error = tokenResponse.error {
            throw AuthError.tokenExchangeFailed(tokenResponse.errorDescription ?? error)
        }

        guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
            throw AuthError.invalidTokenResponse
        }

        let now = Date()
        return CopilotWebAuthResult(
            accessToken: accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: tokenResponse.expiresIn.map {
                Int64(now.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
            },
            refreshTokenExpiresAt: tokenResponse.refreshTokenExpiresIn.map {
                Int64(now.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
            }
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
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class CopilotOAuthCallbackServer: @unchecked Sendable {
    let port: UInt16

    private let expectedState: String
    private let callbackPath: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hemsoft.CodexBarIOS.copilotOAuthCallback")
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?

    private init(port: UInt16, expectedState: String, callbackPath: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CopilotWebAuthService.AuthError.couldNotStartCallbackServer
        }

        self.port = port
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        self.listener = try NWListener(using: .tcp, on: nwPort)
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
    ) async throws -> CopilotOAuthCallbackServer {
        var lastError: Error = CopilotWebAuthService.AuthError.couldNotStartCallbackServer
        for port in preferredPorts {
            do {
                let server = try CopilotOAuthCallbackServer(
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

    func waitForCallback() async throws -> URL {
        if let pendingCallbackResult = takePendingCallbackResult() {
            return try pendingCallbackResult.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
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
        case .cancelled:
            finishReady(.failure(CopilotWebAuthService.AuthError.couldNotStartCallbackServer))
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

    private func takePendingCallbackResult() -> Result<URL, Error>? {
        lock.lock()
        let result = pendingCallbackResult
        pendingCallbackResult = nil
        lock.unlock()
        return result
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

            switch result {
            case .success(let url):
                self.finishCallback(.success(url))
            case .failure(let error):
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
            return .failure(CopilotWebAuthService.AuthError.missingAuthorizationCode)
        }

        let path = String(requestLine[requestLine.index(after: pathStart)..<pathEnd])
        guard path.hasPrefix(callbackPath) else {
            return .failure(CopilotWebAuthService.AuthError.missingAuthorizationCode)
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            return .failure(CopilotWebAuthService.AuthError.missingAuthorizationCode)
        }

        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItemValue(named: "state") == expectedState
        else {
            return .failure(CopilotWebAuthService.AuthError.stateMismatch)
        }

        guard components.queryItemValue(named: "code")?.isEmpty == false else {
            return .failure(CopilotWebAuthService.AuthError.missingAuthorizationCode)
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
            <body><h1>GitHub sign-in complete</h1><p>You can return to CodexBar.</p></body></html>
            """
        case .failure(let error):
            statusLine = "HTTP/1.1 400 Bad Request"
            body = """
            <!doctype html>
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
            <body><h1>GitHub sign-in failed</h1><p>\(error.localizedDescription)</p></body></html>
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
