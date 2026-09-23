import Foundation

struct OpenCodeConsoleCredential: Codable, Equatable, Sendable {
    let kind: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let workspaceID: String
    let userID: String

    static func parse(_ value: String?) -> Self? {
        guard let value, let data = value.data(using: .utf8),
              let credential = try? JSONDecoder().decode(Self.self, from: data),
              credential.kind == "opencode-console-v1",
              !credential.accessToken.isEmpty, !credential.refreshToken.isEmpty,
              validWorkspace(credential.workspaceID), !credential.userID.isEmpty else { return nil }
        return credential
    }

    static func validWorkspace(_ value: String) -> Bool {
        value.range(of: "^(org_|wrk_)[A-Za-z0-9]+$", options: .regularExpression) != nil
    }

    func encoded() throws -> String {
        guard let value = String(data: try JSONEncoder().encode(self), encoding: .utf8) else {
            throw OpenCodeSignInError.validationFailed
        }
        return value
    }
}

struct OpenCodeDeviceAuthorization: Sendable {
    let deviceCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

/// Implements the device grant advertised by the deployed OpenCode Console.
/// All requests remain on the Console origin. Neither browser cookies nor user
/// passwords are read by CodexBar.
struct OpenCodeDeviceAuthService: Sendable {
    static let clientID = "codexbar-ios"
    static let baseURL = URL(string: "https://opencode.ai/console/")!
    let session: URLSession

    init(session: URLSession = OpenCodeDeviceAuthService.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: OpenCodeConsoleRedirectPolicy(), delegateQueue: nil)
    }

    func begin(now: Date = Date()) async throws -> OpenCodeDeviceAuthorization {
        let (data, status) = try await send(path: "auth/device/code", payload: [
            "client_id": Self.clientID, "supports_org_scope": true,
        ])
        guard status == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["device_code"] as? String, !code.isEmpty,
              let address = object["verification_uri_complete"] as? String,
              let url = Self.verificationURL(address),
              let expires = object["expires_in"] as? Double, expires > 0, expires <= 900,
              let interval = object["interval"] as? Double, interval > 0, interval <= 60 else {
            throw OpenCodeSignInError.browserFailed
        }
        return OpenCodeDeviceAuthorization(
            deviceCode: code, verificationURL: url,
            expiresAt: now.addingTimeInterval(expires), interval: max(5, interval)
        )
    }

    static func verificationURL(_ address: String) -> URL? {
        guard let url = URL(string: address, relativeTo: baseURL)?.absoluteURL,
              url.scheme == "https", url.host == "opencode.ai",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil,
              url.path == "/console/device", url.fragment == nil else { return nil }
        return url
    }

    func authorize(
        _ authorization: OpenCodeDeviceAuthorization,
        shouldContinuePolling: @Sendable () async -> Bool = { true },
        onTokenReceived: @Sendable () async -> Void = {},
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> OpenCodeConsoleCredential {
        var interval = authorization.interval
        while Date() < authorization.expiresAt {
            try await sleep(interval)
            try Task.checkCancellation()
            guard Date() < authorization.expiresAt else { break }
            // Snapshot before the request: a pending reply from before browser
            // dismissal cannot substitute for the final post-dismissal check.
            let continueAfterPending = await shouldContinuePolling()
            switch try await poll(authorization, onTokenReceived: onTokenReceived) {
            case .pending(let increase):
                interval = try nextPollInterval(interval, increase: increase, shouldContinuePolling: continueAfterPending)
            case .authorized(let credential): return credential
            }
        }
        throw OpenCodeSignInError.expired
    }

    private func nextPollInterval(
        _ interval: TimeInterval, increase: TimeInterval,
        shouldContinuePolling: Bool
    ) throws -> TimeInterval {
        guard shouldContinuePolling else { throw OpenCodeSignInError.approvalNotReady }
        return interval + increase
    }

    private enum PollResponse {
        case pending(TimeInterval)
        case authorized(OpenCodeConsoleCredential)
    }

    private func poll(
        _ authorization: OpenCodeDeviceAuthorization,
        onTokenReceived: @Sendable () async -> Void
    ) async throws -> PollResponse {
        let (data, status) = try await send(path: "auth/device/token", payload: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": authorization.deviceCode, "client_id": Self.clientID,
        ])
        if status == 200 { return .authorized(try await verifiedCredential(data, onTokenReceived: onTokenReceived)) }
        guard status == 400 else { throw OpenCodeSignInError.browserFailed }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return try Self.pendingResponse(error: object?["error"] as? String)
    }

    private static func pendingResponse(error: String?) throws -> PollResponse {
        switch error {
        case "authorization_pending": return .pending(0)
        case "slow_down": return .pending(5)
        case "access_denied": throw OpenCodeSignInError.canceled
        case "expired_token": throw OpenCodeSignInError.expired
        default: throw OpenCodeSignInError.browserFailed
        }
    }

    private func verifiedCredential(
        _ data: Data, onTokenReceived: @Sendable () async -> Void
    ) async throws -> OpenCodeConsoleCredential {
        let token = try JSONDecoder().decode(OpenCodeDeviceToken.self, from: data)
        guard let workspace = token.orgID, OpenCodeConsoleCredential.validWorkspace(workspace) else {
            throw OpenCodeSignInError.validationFailed
        }
        try token.validate(workspaceID: workspace)
        let issuedAt = Date()
        await onTokenReceived()
        try Task.checkCancellation()
        let identityData = try await get(path: "auth/session", accessToken: token.accessToken)
        let identity = try JSONDecoder().decode(OpenCodeConsoleIdentity.self, from: identityData)
        guard !identity.user.id.isEmpty, identity.orgID == nil || identity.orgID == workspace else {
            throw OpenCodeSignInError.validationFailed
        }
        return try token.credential(workspaceID: workspace, userID: identity.user.id, now: issuedAt)
    }

    func get(path: String, accessToken: String, workspaceID: String? = nil) async throws -> Data {
        let (data, status) = try await send(path: path, accessToken: accessToken, workspaceID: workspaceID)
        guard status == 200 else { throw OpenCodeSignInError.validationFailed }
        return data
    }

    func send(
        path: String,
        payload: [String: Any]? = nil,
        accessToken: String? = nil,
        workspaceID: String? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let workspaceID { request.setValue(workspaceID, forHTTPHeaderField: "x-org-id") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            throw OpenCodeSignInError.validationFailed
        }
        return (data, response.statusCode)
    }
}

struct OpenCodeDeviceToken: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: TimeInterval
    let orgID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case orgID = "org_id"
    }

    func validate(workspaceID: String) throws {
        guard tokenType == "Bearer", !accessToken.isEmpty, !refreshToken.isEmpty,
              !accessToken.contains(where: \.isWhitespace), !refreshToken.contains(where: \.isWhitespace),
              expiresIn > 0, expiresIn.isFinite,
              orgID == nil || orgID == workspaceID else { throw OpenCodeSignInError.validationFailed }
    }

    func credential(workspaceID: String, userID: String, now: Date = Date()) throws -> OpenCodeConsoleCredential {
        try validate(workspaceID: workspaceID)
        return OpenCodeConsoleCredential(
            kind: "opencode-console-v1", accessToken: accessToken, refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn), workspaceID: workspaceID, userID: userID
        )
    }
}

private struct OpenCodeConsoleIdentity: Decodable {
    struct User: Decodable { let id: String }
    let user: User
    let orgID: String?
    enum CodingKeys: String, CodingKey { case user; case orgID = "org_id" }
}

private final class OpenCodeConsoleRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
