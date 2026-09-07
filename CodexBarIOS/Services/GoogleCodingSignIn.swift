#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
import Foundation
import UIKit

/// Browser authorization for the coding source. Client registration belongs to the app build.
@MainActor
final class GoogleCodingSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: Error, LocalizedError {
        case missingConfiguration
        case invalidCallback
        case denied
        case invalidToken

        var errorDescription: String? {
            switch self {
            case .missingConfiguration:
                "Coding sign-in is not configured in this build."
            case .invalidCallback:
                "Google sign-in could not be completed securely. Please try again."
            case .denied:
                "Google sign-in was canceled or access was not granted."
            case .invalidToken:
                "Google did not complete coding authorization. Please try again."
            }
        }
    }

    struct Configuration: Equatable {
        let clientID: String
        let callbackScheme: String

        init(clientID: String) throws {
            let suffix = ".apps.googleusercontent.com"
            guard clientID.hasSuffix(suffix),
                  !clientID.contains(where: { $0.isWhitespace }),
                  !clientID.dropLast(suffix.count).isEmpty,
                  clientID.dropLast(suffix.count).utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                  }) else { throw Failure.missingConfiguration }
            self.clientID = clientID
            callbackScheme = "com.googleusercontent.apps." + clientID.dropLast(suffix.count)
        }

        var redirectURI: String { "\(callbackScheme):/oauthredirect" }
    }

    private var browser: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<URL, Error>?
    private var attemptID: UUID?

    func signIn(configuration: Configuration) async throws -> AntigravityCredentials {
        let state = try OAuthRandomness.base64URL(byteCount: 32, using: OAuthRandomness.systemGenerator)
        let pkce = try OAuthRandomness.pkce(using: OAuthRandomness.systemGenerator)
        let url = Self.authorizationURL(configuration: configuration, state: state, challenge: pkce.challenge)
        let callback = try await withTaskCancellationHandler {
            try await open(url, scheme: configuration.callbackScheme)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        try Task.checkCancellation()
        let code = try Self.authorizationCode(callback, configuration: configuration, state: state)
        let network = URLSession(configuration: .ephemeral, delegate: RejectGoogleCodingRedirects(), delegateQueue: nil)
        defer { network.invalidateAndCancel() }
        let request = Self.tokenRequest(code: code, verifier: pkce.verifier, configuration: configuration)
        let (data, response) = try await network.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw Failure.invalidToken
        }
        return try Self.credentials(data, clientID: configuration.clientID)
    }

    func cancel() {
        attemptID = nil
        browser?.cancel()
        browser = nil
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func open(_ url: URL, scheme: String) async throws -> URL {
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        attemptID = id
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { [weak self] callback, _ in
                Task { @MainActor in
                    guard let self, self.attemptID == id else { return }
                    self.attemptID = nil
                    self.browser = nil
                    let pending = self.pending
                    self.pending = nil
                    if let callback {
                        pending?.resume(returning: callback)
                    } else {
                        pending?.resume(throwing: Failure.denied)
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            browser = session
            if !session.start() { cancel() }
        }
    }

    static func authorizationURL(configuration: Configuration, state: String, challenge: String) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        return url.url!
    }

    static func authorizationCode(_ url: URL, configuration: Configuration, state: String) throws -> String {
        guard url.scheme == configuration.callbackScheme, url.host == nil,
              url.path == "/oauthredirect", url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure.invalidCallback
        }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states.first?.value == state else { throw Failure.invalidCallback }
        guard !items.contains(where: { $0.name == "error" }) else { throw Failure.denied }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else { throw Failure.invalidCallback }
        return code
    }

    static func tokenRequest(code: String, verifier: String, configuration: Configuration) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }

    static func credentials(_ data: Data, clientID: String, now: Date = Date()) throws -> AntigravityCredentials {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
            let tokenType: String
            let expiresIn: Double
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let token = try? decoder.decode(Response.self, from: data),
              token.tokenType.lowercased() == "bearer", !token.accessToken.isEmpty,
              token.expiresIn.isFinite, token.expiresIn > 0, token.expiresIn <= 86_400 else { throw Failure.invalidToken }
        return AntigravityCredentials(
            accessToken: token.accessToken, refreshToken: token.refreshToken,
            clientID: clientID, expiry: now.addingTimeInterval(token.expiresIn), isPublicClient: true
        )
    }
}

private final class RejectGoogleCodingRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
