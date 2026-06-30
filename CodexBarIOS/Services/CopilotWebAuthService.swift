import Foundation

public struct CopilotWebAuthResult: Equatable, Sendable {
    public let accessToken: String

    public func storedCredential(username: String? = nil) -> String {
        let credentials = CopilotCredentials(accessToken: accessToken, username: username)
        guard
            let data = try? JSONEncoder().encode(credentials),
            let json = String(data: data, encoding: .utf8)
        else {
            return accessToken
        }

        return json
    }
}

public struct CopilotDeviceCode: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: TimeInterval
    public let interval: TimeInterval
}

public final class CopilotWebAuthService: Sendable {
    public enum AuthError: LocalizedError, Equatable {
        case missingClientID
        case invalidDeviceCodeResponse
        case deviceCodeRequestFailed(String)
        case authorizationExpired
        case authorizationDeclined
        case tokenExchangeFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .missingClientID:
                "Enter a GitHub OAuth app Client ID before signing in."
            case .invalidDeviceCodeResponse:
                "GitHub returned an invalid device login response."
            case .deviceCodeRequestFailed(let message):
                "GitHub device login failed: \(message)"
            case .authorizationExpired:
                "GitHub sign-in expired. Start sign-in again."
            case .authorizationDeclined:
                "GitHub sign-in was declined."
            case .tokenExchangeFailed(let message):
                "GitHub token exchange failed: \(message)"
            case .invalidTokenResponse:
                "GitHub token exchange returned an invalid response."
            }
        }
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: URL
        let expiresIn: TimeInterval
        let interval: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
        }
    }

    private static let githubBaseURL = URL(string: "https://github.com")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    @MainActor
    public func signIn(
        clientID: String,
        presentAuthorizationURL: @escaping @MainActor (URL) -> Void,
        presentUserCode: @escaping @MainActor (String) -> Void
    ) async throws -> CopilotWebAuthResult {
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientID.isEmpty else {
            throw AuthError.missingClientID
        }

        let deviceCode = try await requestDeviceCode(clientID: normalizedClientID)
        presentUserCode(deviceCode.userCode)
        presentAuthorizationURL(deviceCode.verificationURI)

        return try await pollForToken(clientID: normalizedClientID, deviceCode: deviceCode)
    }

    public func requestDeviceCode(clientID: String) async throws -> CopilotDeviceCode {
        var request = URLRequest(url: Self.githubBaseURL.appending(path: "/login/device/code"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.makeDeviceCodeRequestBody(clientID: clientID)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidDeviceCodeResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthError.deviceCodeRequestFailed(String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)")
        }

        guard let decoded = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data) else {
            throw AuthError.invalidDeviceCodeResponse
        }

        return CopilotDeviceCode(
            deviceCode: decoded.deviceCode,
            userCode: decoded.userCode,
            verificationURI: decoded.verificationURI,
            expiresIn: decoded.expiresIn,
            interval: decoded.interval ?? 5
        )
    }

    public static func makeDeviceCodeRequestBody(clientID: String) -> Data {
        formEncoded([
            ("client_id", clientID),
            ("scope", "read:user")
        ])
    }

    public static func makeAccessTokenRequestBody(clientID: String, deviceCode: String) -> Data {
        formEncoded([
            ("client_id", clientID),
            ("device_code", deviceCode),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
        ])
    }

    private func pollForToken(clientID: String, deviceCode: CopilotDeviceCode) async throws -> CopilotWebAuthResult {
        let expiresAt = Date().addingTimeInterval(deviceCode.expiresIn)
        var interval = max(deviceCode.interval, 1)

        while Date() < expiresAt {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            var request = URLRequest(url: Self.githubBaseURL.appending(path: "/login/oauth/access_token"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.makeAccessTokenRequestBody(
                clientID: clientID,
                deviceCode: deviceCode.deviceCode
            )

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.invalidTokenResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw AuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)")
            }

            guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                throw AuthError.invalidTokenResponse
            }

            if let accessToken = tokenResponse.accessToken, !accessToken.isEmpty {
                return CopilotWebAuthResult(accessToken: accessToken)
            }

            switch tokenResponse.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "expired_token":
                throw AuthError.authorizationExpired
            case "access_denied":
                throw AuthError.authorizationDeclined
            case .some:
                throw AuthError.tokenExchangeFailed(tokenResponse.errorDescription ?? tokenResponse.error ?? "Unknown error")
            case .none:
                throw AuthError.invalidTokenResponse
            }
        }

        throw AuthError.authorizationExpired
    }

    private static func formEncoded(_ pairs: [(String, String)]) -> Data {
        let encoded = pairs
            .map { "\($0.0.urlFormEncoded)=\($0.1.urlFormEncoded)" }
            .joined(separator: "&")
        return Data(encoded.utf8)
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
