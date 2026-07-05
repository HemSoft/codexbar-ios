import CryptoKit
import Foundation
import Security

public struct CursorWebAuthResult: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let authID: String?
    public let userID: String?

    public var storedCredential: String {
        let tokenPairs = [
            jsonPair("accessToken", accessToken),
            refreshToken.map { jsonPair("refreshToken", $0) },
            authID.map { jsonPair("authId", $0) },
            userID.map { jsonPair("userId", $0) }
        ].compactMap { $0 }

        return """
        {
          \(tokenPairs.joined(separator: ",\n  "))
        }
        """
    }

    private func jsonPair(_ key: String, _ value: String) -> String {
        let encodedValue = (try? JSONEncoder().encode(value))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\""
        return "\"\(key)\": \(encodedValue)"
    }
}

public final class CursorWebAuthService: Sendable {
    public enum AuthError: LocalizedError, Equatable {
        case missingToken
        case tokenPollingTimedOut
        case tokenPollFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .missingToken:
                "Cursor sign-in completed, but no session token was returned."
            case .tokenPollingTimedOut:
                "Cursor sign-in timed out. Try again and click Yes, Log In in the browser."
            case .tokenPollFailed(let message):
                "Cursor sign-in failed: \(message)"
            case .invalidTokenResponse:
                "Cursor sign-in returned an invalid response."
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
        let authID: String?
        let userID: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken
            case refreshToken
            case authID = "authId"
            case userID = "userId"
            case error
            case errorDescription = "error_description"
        }
    }

    private static let loginURL = URL(string: "https://cursor.com/loginDeepControl")!
    private static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!

    private let session: URLSession
    private let pollIntervalNanoseconds: UInt64
    private let maxPollAttempts: Int

    public init(
        session: URLSession = .shared,
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        maxPollAttempts: Int = 90
    ) {
        self.session = session
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPollAttempts = maxPollAttempts
    }

    @MainActor
    public func signIn(presentAuthorizationURL: @escaping @MainActor (URL) -> Void) async throws -> CursorWebAuthResult {
        let requestID = UUID().uuidString.lowercased()
        let pkce = Self.makePKCEPair()
        presentAuthorizationURL(Self.authorizationURL(uuid: requestID, codeChallenge: pkce.codeChallenge))
        return try await pollForToken(uuid: requestID, codeVerifier: pkce.codeVerifier)
    }

    public static func authorizationURL(uuid: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: codeChallenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli")
        ]
        return components.url!
    }

    public static func pollRequest(uuid: String, codeVerifier: String) -> URLRequest {
        var components = URLComponents(url: pollURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "verifier", value: codeVerifier)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func makePKCEPair() -> PKCEPair {
        let verifier = randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCEPair(
            codeVerifier: verifier,
            codeChallenge: Data(digest).base64URLEncodedString()
        )
    }

    private func pollForToken(uuid: String, codeVerifier: String) async throws -> CursorWebAuthResult {
        guard maxPollAttempts > 0 else {
            throw AuthError.tokenPollingTimedOut
        }

        for attempt in 0..<maxPollAttempts {
            let request = Self.pollRequest(uuid: uuid, codeVerifier: codeVerifier)
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AuthError.invalidTokenResponse
            }

            switch httpResponse.statusCode {
            case 200:
                return try Self.decodeTokenResponse(data)
            case 404:
                break
            default:
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw AuthError.tokenPollFailed(message)
            }

            if attempt + 1 < maxPollAttempts {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }

        throw AuthError.tokenPollingTimedOut
    }

    private static func decodeTokenResponse(_ data: Data) throws -> CursorWebAuthResult {
        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidTokenResponse
        }

        if let error = tokenResponse.error {
            throw AuthError.tokenPollFailed(tokenResponse.errorDescription ?? error)
        }

        guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
            throw AuthError.missingToken
        }

        return CursorWebAuthResult(
            accessToken: accessToken,
            refreshToken: tokenResponse.refreshToken,
            authID: tokenResponse.authID,
            userID: tokenResponse.userID
        )
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
