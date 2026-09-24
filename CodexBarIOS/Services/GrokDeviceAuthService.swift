import Foundation

/// Serializes Grok Keychain compare-and-save with account removal and replacement.
/// The network request is deliberately outside this short critical section.
enum GrokCredentialLock {
    private static let lock = NSLock()

    static func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try lock.withLock(operation)
    }
}

struct GrokCredential: Codable, Equatable, Sendable {
    let kind: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let subject: String
    let email: String?

    static func parse(_ value: String?) -> Self? {
        guard let value, let data = value.data(using: .utf8),
              let credential = try? JSONDecoder().decode(Self.self, from: data),
              credential.kind == "grok-oauth-v1", !credential.accessToken.isEmpty,
              !credential.refreshToken.isEmpty, !credential.subject.isEmpty else { return nil }
        return credential
    }

    func encoded() throws -> String {
        guard let value = String(data: try JSONEncoder().encode(self), encoding: .utf8) else {
            throw GrokAuthError.invalidResponse
        }
        return value
    }
}

struct GrokDeviceChallenge: Sendable {
    let code: String
    let approvalURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

enum GrokAuthError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case denied
    case expired
    case unauthorized
    case temporarilyUnavailable
    case unsupportedAccount

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Grok sign-in returned an unreadable response. Try again."
        case .denied: "Grok sign-in was declined. No account was changed."
        case .expired: "Grok sign-in expired. Start another attempt."
        case .unauthorized: "Grok authorization failed. Sign in again."
        case .temporarilyUnavailable: "Grok usage is temporarily unavailable. Try again."
        case .unsupportedAccount: "Grok consumer usage is not available for this account."
        }
    }
}

/// Device authorization uses the public client bundled with xAI's Grok Build CLI.
/// No browser cookies, API keys, or desktop credentials are imported.
struct GrokDeviceAuthService: Sendable {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let issuer = URL(string: "https://auth.x.ai/")!
    static let scope = "openid profile email offline_access grok-cli:access api:access"
    let session: URLSession

    init(session: URLSession = GrokDeviceAuthService.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: GrokRedirectPolicy(), delegateQueue: nil)
    }

    func begin(now: Date = Date()) async throws -> GrokDeviceChallenge {
        let (data, status) = try await post("oauth2/device/code", values: [
            ("client_id", Self.clientID), ("scope", Self.scope),
        ])
        guard status == 200,
              let object = try? JSONDecoder().decode(DeviceReply.self, from: data),
              !object.deviceCode.isEmpty,
              let url = Self.approvalURL(object.verificationURIComplete),
              object.expiresIn > 0, object.expiresIn <= 1800,
              object.interval > 0, object.interval <= 60 else { throw GrokAuthError.invalidResponse }
        return GrokDeviceChallenge(
            code: object.deviceCode, approvalURL: url,
            expiresAt: now.addingTimeInterval(object.expiresIn), interval: max(5, object.interval)
        )
    }

    static func approvalURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              let host = url.host, ["auth.x.ai", "accounts.x.ai"].contains(host),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }

    func authorize(
        _ challenge: GrokDeviceChallenge,
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> GrokCredential {
        var interval = challenge.interval
        while Date() < challenge.expiresAt {
            try await sleep(min(interval, max(0, challenge.expiresAt.timeIntervalSinceNow)))
            try Task.checkCancellation()
            guard Date() < challenge.expiresAt else { break }
            let (data, status) = try await post("oauth2/token", values: [
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("device_code", challenge.code), ("client_id", Self.clientID),
            ])
            if status == 200 {
                guard let token = try? Self.token(data),
                      let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
                    interval = min(60, interval + 5)
                    continue
                }
                let identity = try await userInfo(accessToken: token.accessToken)
                return GrokCredential(
                    kind: "grok-oauth-v1", accessToken: token.accessToken,
                    refreshToken: refreshToken, expiresAt: Date().addingTimeInterval(token.expiresIn),
                    subject: identity.sub, email: identity.email
                )
            }
            interval = try Self.nextPollingInterval(data, status: status, current: interval)
        }
        throw GrokAuthError.expired
    }

    private static func nextPollingInterval(_ data: Data, status: Int, current: TimeInterval) throws -> TimeInterval {
        if status == 429 || (500...599).contains(status) { return min(60, current + 5) }
        guard status == 400 else { throw GrokAuthError.unauthorized }
        guard let reply = try? JSONDecoder().decode(TokenError.self, from: data) else {
            return min(60, current + 5)
        }
        if reply.error == "authorization_pending" { return current }
        if reply.error == "slow_down" { return min(60, current + 5) }
        throw pollingFailure(reply.error)
    }

    private static func pollingFailure(_ error: String) -> GrokAuthError {
        switch error {
        case "access_denied": .denied
        case "expired_token": .expired
        default: .unauthorized
        }
    }

    func userInfo(accessToken: String) async throws -> GrokIdentity {
        var request = URLRequest(url: Self.issuer.appending(path: "oauth2/userinfo"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(request)
        if status == 401 || status == 403 { throw GrokAuthError.unauthorized }
        guard status == 200 else { throw GrokAuthError.temporarilyUnavailable }
        guard let identity = try? JSONDecoder().decode(GrokIdentity.self, from: data),
              !identity.sub.isEmpty else { throw GrokAuthError.invalidResponse }
        return identity
    }

    static func token(_ data: Data) throws -> GrokTokenReply {
        guard let token = try? JSONDecoder().decode(GrokTokenReply.self, from: data),
              !token.accessToken.isEmpty,
              token.tokenType.lowercased() == "bearer", token.expiresIn > 0,
              token.expiresIn <= 2_592_000,
              !token.accessToken.contains(where: \.isWhitespace),
              token.refreshToken?.contains(where: \.isWhitespace) != true else { throw GrokAuthError.invalidResponse }
        return token
    }

    func post(_ path: String, values: [(String, String)]) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.issuer.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuthFormEncoder.encode(values)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        var request = request
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            throw GrokAuthError.invalidResponse
        }
        return (data, response.statusCode)
    }
}

struct GrokIdentity: Decodable, Sendable {
    let sub: String
    let email: String?
}

struct GrokTokenReply: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresIn: TimeInterval
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

private struct DeviceReply: Decodable {
    let deviceCode: String
    let verificationURIComplete: String
    let expiresIn: TimeInterval
    let interval: TimeInterval
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenError: Decodable {
    let error: String
}

private final class GrokRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
