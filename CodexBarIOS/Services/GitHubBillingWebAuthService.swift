import Foundation

public struct GitHubBillingWebAuthResult: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Int64?
    public let refreshTokenExpiresAt: Int64?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Int64? = nil,
        refreshTokenExpiresAt: Int64? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    public func credentials(username: String) -> GitHubBillingCredentials {
        GitHubBillingCredentials(
            accessToken: accessToken,
            username: username,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt
        )
    }
}

public struct GitHubBillingOAuthConfiguration: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static var bundled: GitHubBillingOAuthConfiguration {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let environmentClientID = environment["CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_ID"]
        let environmentClientSecret = environment["CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_SECRET"]
        #else
        let environmentClientID: String? = nil
        let environmentClientSecret: String? = nil
        #endif

        // GitHub issues separate tokens per user, OAuth application, and scope combination. Billing
        // intentionally uses a different scope combination and Keychain entry from Copilot; sharing
        // the public app registration fallback does not broaden or replace the saved Copilot token.
        return GitHubBillingOAuthConfiguration(
            clientID: environmentClientID
                ?? Bundle.main.object(forInfoDictionaryKey: "CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_ID") as? String
                ?? CopilotOAuthConfiguration.bundled.clientID,
            clientSecret: environmentClientSecret
                ?? Bundle.main.object(forInfoDictionaryKey: "CODEXBAR_GITHUB_BILLING_OAUTH_CLIENT_SECRET") as? String
                ?? CopilotOAuthConfiguration.bundled.clientSecret
        )
    }
}

@MainActor
protocol GitHubBillingWebAuthenticating {
    func signIn(
        configuration: GitHubBillingOAuthConfiguration,
        presentAuthorizationURL: @escaping @MainActor (URL) -> Void
    ) async throws -> GitHubBillingWebAuthResult
}

public final class GitHubBillingWebAuthService: Sendable {
    public enum AuthError: LocalizedError, Equatable, Sendable {
        case couldNotStartCallbackServer
        case missingOAuthConfiguration
        case missingAuthorizationCode
        case stateMismatch
        case callbackTimedOut
        case secureRandomUnavailable
        case tokenExchangeFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .couldNotStartCallbackServer:
                "Could not start the local GitHub Billing login callback server."
            case .missingOAuthConfiguration:
                "GitHub Billing sign-in is not configured in this build."
            case .missingAuthorizationCode:
                "GitHub Billing sign-in did not return an authorization code."
            case .stateMismatch:
                "GitHub Billing sign-in returned an unexpected state value."
            case .callbackTimedOut:
                "GitHub Billing sign-in did not return to the app. Try again and finish authorization in the browser."
            case .secureRandomUnavailable:
                "GitHub Billing sign-in could not start securely. Try again."
            case .tokenExchangeFailed(let message):
                "GitHub Billing token exchange failed: \(message)"
            case .invalidTokenResponse:
                "GitHub Billing token exchange returned an invalid response."
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

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case error
        }
    }

    private static let githubBaseURL = URL(string: "https://github.com")!
    public static let tokenEndpoint = githubBaseURL.appending(path: "/login/oauth/access_token")
    public static let requestedScope = "repo read:org read:user"
    private static let callbackPath = "/callback"

    private let session: URLSession
    private let callbackTimeoutNanoseconds: UInt64
    private let preferredCallbackPorts: [UInt16]
    private let randomBytes: OAuthRandomness.Generator

    public init(
        session: URLSession = .shared,
        callbackTimeoutNanoseconds: UInt64 = 180_000_000_000,
        preferredCallbackPorts: [UInt16] = [1472, 1474, 1476],
        randomBytes: OAuthRandomByteGenerator? = nil
    ) {
        self.session = session
        self.callbackTimeoutNanoseconds = callbackTimeoutNanoseconds
        self.preferredCallbackPorts = preferredCallbackPorts
        self.randomBytes = randomBytes ?? OAuthRandomness.systemGenerator
    }

    @MainActor
    public func signIn(
        configuration: GitHubBillingOAuthConfiguration,
        presentAuthorizationURL: @escaping @MainActor (URL) -> Void
    ) async throws -> GitHubBillingWebAuthResult {
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = configuration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw AuthError.missingOAuthConfiguration
        }

        let state: String
        let pkce: PKCEPair
        do {
            state = try OAuthRandomness.base64URL(byteCount: 32, using: randomBytes)
            pkce = try Self.makePKCEPair(randomBytes: randomBytes)
        } catch {
            throw AuthError.secureRandomUnavailable
        }

        let callbackServer = try await LoopbackOAuthCallbackServer<AuthError>.start(
            preferredPorts: preferredCallbackPorts,
            expectedState: state,
            callbackPath: Self.callbackPath,
            bindHost: .ipv4,
            queueLabel: "com.hemsoft.CodexBarIOS.githubBillingOAuthCallback",
            couldNotStartError: .couldNotStartCallbackServer,
            missingCodeError: .missingAuthorizationCode,
            stateMismatchError: .stateMismatch,
            timeoutError: .callbackTimedOut,
            successHeading: "GitHub Billing sign-in complete",
            failureHeading: "GitHub Billing sign-in failed"
        )
        defer { callbackServer.cancel() }

        let redirectURI = "http://127.0.0.1:\(callbackServer.port)\(Self.callbackPath)"
        presentAuthorizationURL(Self.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.codeChallenge
        ))
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
        var components = URLComponents(
            url: githubBaseURL.appending(path: "/login/oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requestedScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
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
        OAuthFormEncoder.encode([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
        ])
    }

    public static func makeRefreshTokenRequestBody(
        clientID: String,
        clientSecret: String,
        refreshToken: String
    ) -> Data {
        OAuthFormEncoder.encode([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    public static func makePKCEPair() throws -> PKCEPair {
        try makePKCEPair(randomBytes: OAuthRandomness.systemGenerator)
    }

    static func makePKCEPair(randomBytes: OAuthRandomness.Generator) throws -> PKCEPair {
        let pkce = try OAuthRandomness.pkce(using: randomBytes)
        return PKCEPair(codeVerifier: pkce.verifier, codeChallenge: pkce.challenge)
    }

    private func exchangeCodeForToken(
        clientID: String,
        clientSecret: String,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> GitHubBillingWebAuthResult {
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
            throw AuthError.tokenExchangeFailed(TokenEndpointErrorFormatter.message(errorCode: error))
        }
        guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
            throw AuthError.invalidTokenResponse
        }

        let now = Date()
        return GitHubBillingWebAuthResult(
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
}

extension GitHubBillingWebAuthService: GitHubBillingWebAuthenticating {}

private extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}
