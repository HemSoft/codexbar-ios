import CryptoKit
import Foundation
#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
import UIKit
#endif

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
            userID.map { jsonPair("userId", $0) },
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

struct CursorSessionCredential: Sendable {
    let accessToken: String
    let refreshToken: String?
    let authID: String?
    let userID: String?
    let storedSecret: String
    private let savedUsageIdentity: String?

    init?(storedSecret: String) {
        guard let accessToken = Self.validToken(CursorUsageProvider.normalizedAccessToken(from: storedSecret)) else { return nil }
        let saved = try? JSONDecoder().decode(SavedSession.self, from: Data(storedSecret.utf8))
        self.accessToken = accessToken
        self.refreshToken = saved?.refreshToken
        self.authID = saved?.authID?.isEmpty == false ? saved?.authID : nil
        self.userID = saved?.userID?.isEmpty == false ? saved?.userID : nil
        self.savedUsageIdentity = saved?.usageIdentity
        self.storedSecret = storedSecret
    }

    static func validToken(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        guard !token.contains(where: \.isWhitespace), !token.hasPrefix("{") else { return nil }
        return token
    }

    // JWT lifetime is a renewal hint only. No unsigned identity claim authorizes an account.
    func needsRenewal(at date: Date) -> Bool {
        guard let expiry = Self.expiration(of: accessToken) else { return false }
        return expiry <= date.timeIntervalSince1970
    }

    func shouldAttemptEarlyRenewal(at date: Date) -> Bool {
        guard let refreshToken, !refreshToken.isEmpty, let expiry = Self.expiration(of: accessToken) else { return false }
        // Cursor 3.22.7's first-party ypr lifetime window, in seconds.
        return expiry <= date.timeIntervalSince1970 + 1272 * 60 * 60
    }

    var savedAccountIdentity: String? { authID ?? userID }

    var cacheIdentity: String {
        if authID == nil && userID == nil, let savedUsageIdentity { return savedUsageIdentity }
        return Self.digest(authID ?? userID ?? storedSecret)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func expiration(of token: String) -> Double? {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[1].count < 16_384 else { return nil }
        let payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)
        return expiration(in: Data(base64Encoded: padded))
    }

    private static func expiration(in payload: Data?) -> Double? {
        guard let payload, let claims = try? JSONDecoder().decode(LifetimeClaim.self, from: payload) else { return nil }
        guard let expiry = claims.exp, expiry.isFinite, expiry > 0 else { return nil }
        return expiry
    }

    private struct LifetimeClaim: Decodable { let exp: Double? }
    private struct SavedSession: Decodable {
        let refreshToken: String?
        let authID: String?
        let userID: String?
        let usageIdentity: String?
        enum CodingKeys: String, CodingKey {
            case refreshToken, usageIdentity
            case authID = "authId"
            case userID = "userId"
        }
    }
}

enum CursorSessionFailure: Error, Equatable {
    case needsRenewal, rejected, invalidated, renewalUnavailable, persistenceFailed, changed

    var message: String {
        switch self {
        case .needsRenewal: "Cursor sign-in needs renewal. Reconnect to refresh usage."
        case .rejected, .invalidated: "Cursor rejected this sign-in. Reconnect to refresh usage."
        default: renewalFailureMessage
        }
    }

    private var renewalFailureMessage: String {
        switch self {
        case .persistenceFailed: "Could not securely save renewed Cursor sign-in. Reconnect to try again."
        case .changed: "Cursor account changed during refresh. Refresh the current account."
        default: "Could not renew Cursor sign-in. Reconnect to refresh usage."
        }
    }

    var recoveryAction: ProviderUsageRecoveryAction { self == .changed ? .retryRefresh : .reauthenticate }
}

struct CursorSessionRenewal: Sendable {
    let secretStore: SecretStore
    let session: URLSession

    func renew(_ credential: CursorSessionCredential, account: String) async throws -> CursorSessionCredential {
        try Task.checkCancellation()
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw CursorSessionFailure.needsRenewal
        }
        let (data, response) = try await session.data(for: Self.request(refreshToken: refreshToken))
        try Task.checkCancellation()
        try Self.validate(response)
        let updated = try Self.updatedCredential(data, replacing: credential)
        try await persist(updated, replacing: credential, account: account)
        return updated
    }

    private static func request(refreshToken: String) -> URLRequest {
        // Public first-party desktop renewal contract. The client ID is not a secret.
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try? JSONEncoder().encode([
            "grant_type": "refresh_token", "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB", "refresh_token": refreshToken,
        ])
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw CursorSessionFailure.renewalUnavailable }
        if [400, 401, 403].contains(response.statusCode) { throw CursorSessionFailure.rejected }
        guard (200..<300).contains(response.statusCode) else { throw CursorSessionFailure.renewalUnavailable }
    }

    private static func updatedCredential(
        _ data: Data, replacing credential: CursorSessionCredential
    ) throws -> CursorSessionCredential {
        // Honor the verified invalidation directive even if another optional field is malformed.
        if (try? JSONDecoder().decode(LogoutDirective.self, from: data))?.shouldLogout == true {
            throw CursorSessionFailure.invalidated
        }
        guard let reply = try? JSONDecoder().decode(RenewalResponse.self, from: data) else {
            throw CursorSessionFailure.renewalUnavailable
        }
        if reply.error != nil { throw CursorSessionFailure.rejected }
        return try Self.credential(from: reply, replacing: credential)
    }

    private static func credential(
        from reply: RenewalResponse, replacing original: CursorSessionCredential
    ) throws -> CursorSessionCredential {
        guard let token = CursorSessionCredential.validToken(reply.accessToken) else {
            throw CursorSessionFailure.renewalUnavailable
        }
        // The refresh grant binds the account. Preserve saved metadata, never infer identity from JWT claims.
        let result = CursorWebAuthResult(
            accessToken: token, refreshToken: reply.refreshToken ?? token, authID: original.authID, userID: original.userID
        )
        let stored = try storedCredential(result, usageIdentity: original.cacheIdentity)
        guard let credential = CursorSessionCredential(storedSecret: stored),
              !credential.needsRenewal(at: Date()) else { throw CursorSessionFailure.rejected }
        return credential
    }

    private static func storedCredential(_ result: CursorWebAuthResult, usageIdentity: String) throws -> String {
        guard var payload = try JSONSerialization.jsonObject(with: Data(result.storedCredential.utf8)) as? [String: Any] else {
            throw CursorSessionFailure.renewalUnavailable
        }
        payload["usageIdentity"] = usageIdentity
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let stored = String(data: data, encoding: .utf8) else { throw CursorSessionFailure.renewalUnavailable }
        return stored
    }

    @MainActor
    private func persist(
        _ updated: CursorSessionCredential, replacing original: CursorSessionCredential, account: String
    ) throws {
        try Task.checkCancellation()
        guard try secretStore.readSecret(account: account) == original.storedSecret else { throw CursorSessionFailure.changed }
        do { try secretStore.saveSecret(updated.storedSecret, account: account) } catch {
            throw CursorSessionFailure.persistenceFailed
        }
    }

    private struct LogoutDirective: Decodable { let shouldLogout: Bool? }

    private struct RenewalResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let error: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case error
        }
    }
}

actor CursorEarlyRenewalBackoff {
    private var nextAttempts: [String: Date] = [:]

    func permits(key: String, at date: Date) -> Bool {
        nextAttempts = nextAttempts.filter { $0.value > date }
        return nextAttempts[key] == nil
    }

    func deferAttempt(key: String, at date: Date) {
        if nextAttempts.count >= 128 { nextAttempts.removeAll() }
        nextAttempts[key] = date.addingTimeInterval(15 * 60)
    }
}

final class CursorRejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

public protocol CursorWebAuthenticating: Sendable {
    @MainActor
    func signIn(presentAuthorizationURL: @escaping @MainActor (URL) -> Bool) async throws -> CursorWebAuthResult
}

public final class CursorWebAuthService: CursorWebAuthenticating {
    public enum AuthError: LocalizedError, Equatable {
        case missingToken
        case couldNotStartBrowserSession
        case tokenPollingTimedOut
        case secureRandomUnavailable
        case tokenPollFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .missingToken:
                "Cursor sign-in completed, but no session token was returned."
            case .couldNotStartBrowserSession:
                "Could not open a private Cursor sign-in session."
            case .tokenPollingTimedOut:
                "Cursor sign-in timed out. Try again and click Yes, Log In in the browser."
            case .secureRandomUnavailable:
                "Cursor sign-in could not start securely. Try again."
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

        enum CodingKeys: String, CodingKey {
            case accessToken
            case refreshToken
            case authID = "authId"
            case userID = "userId"
            case error
        }
    }

    private static let loginURL = URL(string: "https://cursor.com/loginDeepControl")!
    private static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!

    private let session: URLSession
    private let pollIntervalNanoseconds: UInt64
    private let maxPollAttempts: Int
    private let randomBytes: OAuthRandomness.Generator

    public init(
        session: URLSession = .shared,
        pollIntervalNanoseconds: UInt64 = 2_000_000_000,
        maxPollAttempts: Int = 90,
        randomBytes: OAuthRandomByteGenerator? = nil
    ) {
        self.session = session
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxPollAttempts = maxPollAttempts
        self.randomBytes = randomBytes ?? OAuthRandomness.systemGenerator
    }

    @MainActor
    public func signIn(presentAuthorizationURL: @escaping @MainActor (URL) -> Bool) async throws -> CursorWebAuthResult {
        let requestID = UUID().uuidString.lowercased()
        let pkce: PKCEPair
        do {
            pkce = try Self.makePKCEPair(randomBytes: randomBytes)
        } catch {
            throw AuthError.secureRandomUnavailable
        }
        guard presentAuthorizationURL(Self.authorizationURL(uuid: requestID, codeChallenge: pkce.codeChallenge)) else {
            throw AuthError.couldNotStartBrowserSession
        }
        return try await pollForToken(uuid: requestID, codeVerifier: pkce.codeVerifier)
    }

    public static func authorizationURL(uuid: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: codeChallenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "cli"),
        ]
        return components.url!
    }

    public static func pollRequest(uuid: String, codeVerifier: String) -> URLRequest {
        var components = URLComponents(url: pollURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "verifier", value: codeVerifier),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func makePKCEPair() throws -> PKCEPair {
        try makePKCEPair(randomBytes: OAuthRandomness.systemGenerator)
    }

    static func makePKCEPair(randomBytes: OAuthRandomness.Generator) throws -> PKCEPair {
        let pkce = try OAuthRandomness.pkce(using: randomBytes)
        return PKCEPair(
            codeVerifier: pkce.verifier,
            codeChallenge: pkce.challenge
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
                let message = TokenEndpointErrorFormatter.message(
                    statusCode: httpResponse.statusCode,
                    body: data
                )
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
            throw AuthError.tokenPollFailed(TokenEndpointErrorFormatter.message(errorCode: error))
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

}

#if canImport(AuthenticationServices) && canImport(UIKit)
@MainActor
final class PrivateWebAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding, CodexBrowserPresenting {
    private var session: ASWebAuthenticationSession?
    private var sessionGeneration = WebAuthenticationSessionGeneration()
    private var cancellationHandler: (() -> Void)?

    func present(
        url: URL,
        prefersEphemeralSession: Bool = true,
        onCancel: @escaping () -> Void
    ) -> Bool {
        finish()
        let sessionID = sessionGeneration.start()
        cancellationHandler = onCancel

        let session = Self.makeSession(url: url, prefersEphemeralSession: prefersEphemeralSession) { [weak self] _ in
            Task { @MainActor in
                self?.handleCompletion(sessionID: sessionID)
            }
        }
        session.presentationContextProvider = self
        self.session = session
        guard session.start() else {
            self.session = nil
            sessionGeneration.invalidate()
            cancellationHandler = nil
            return false
        }
        return true
    }

    func finish() {
        sessionGeneration.invalidate()
        cancellationHandler = nil
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }

    static func makeSession(
        url: URL,
        prefersEphemeralSession: Bool = true,
        completion: @escaping (Error?) -> Void
    ) -> ASWebAuthenticationSession {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: nil
        ) { _, error in
            completion(error)
        }
        session.prefersEphemeralWebBrowserSession = prefersEphemeralSession
        return session
    }

    private func handleCompletion(sessionID: UUID) {
        guard sessionGeneration.complete(sessionID) else {
            return
        }
        session = nil
        cancellationHandler?()
        cancellationHandler = nil
    }
}
#endif

struct WebAuthenticationSessionGeneration {
    private var activeSessionID: UUID?

    mutating func start() -> UUID {
        let sessionID = UUID()
        activeSessionID = sessionID
        return sessionID
    }

    mutating func invalidate() {
        activeSessionID = nil
    }

    mutating func complete(_ sessionID: UUID) -> Bool {
        guard activeSessionID == sessionID else {
            return false
        }
        activeSessionID = nil
        return true
    }
}
