import Foundation

enum OpenCodeBrowserSessionPolicy {
    static let signInURL = URL(string: "https://opencode.ai/auth")!

    static func allowsNavigation(to url: URL?) -> Bool {
        guard isSecureURL(url), let host = url?.host?.lowercased() else { return false }
        return ["opencode.ai", "auth.opencode.ai", "github.com", "accounts.google.com"].contains(host)
    }

    private static func isSecureURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        return url.port == nil || url.port == 443
    }

    static func workspaceID(from url: URL?) -> String? {
        guard isSecureURL(url), url?.host?.lowercased() == "opencode.ai" else { return nil }
        let parts = url?.pathComponents ?? []
        guard parts.count >= 3, parts[1] == "workspace" else { return nil }
        let workspace = parts[2]
        guard workspace.range(of: "^wrk_[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return workspace
    }

    static func credential(from cookies: [HTTPCookie], now: Date = Date()) throws -> String? {
        let candidates = cookies.filter { isSessionCookie($0, now: now) }
        let values = Set(candidates.map(\.value))
        guard values.count <= 1 else { throw OpenCodeSignInError.ambiguousSession }
        guard let value = values.first else { return nil }
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0 == ";" }) else {
            throw OpenCodeSignInError.ambiguousSession
        }
        return value
    }

    private static func isSessionCookie(_ cookie: HTTPCookie, now: Date) -> Bool {
        guard cookie.name == "auth", cookie.path == "/" else { return false }
        guard ["opencode.ai", ".opencode.ai"].contains(cookie.domain.lowercased()) else { return false }
        // OpenCode's current server sets HttpOnly auth without Secure. Only accept
        // it after navigation to the exact HTTPS workspace origin, never from JS.
        return cookie.expiresDate.map { $0 > now } ?? true
    }
}

enum OpenCodeSignInError: LocalizedError {
    case canceled
    case browserFailed
    case ambiguousSession
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .canceled:
            "OpenCode sign-in canceled. Your saved account was not changed."
        case .browserFailed:
            "OpenCode sign-in could not load. Check your connection and try again."
        case .ambiguousSession:
            "OpenCode did not return one usable session. Cancel and sign in again."
        case .validationFailed:
            "OpenCode usage could not be verified. Check your workspace and try again. Your saved account was not changed."
        }
    }
}

struct OpenCodeBrowserCredential {
    let workspaceID: String
    let session: String
}

protocol OpenCodeSessionValidating: Sendable {
    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult
}

struct OpenCodeSessionValidator: OpenCodeSessionValidating {
    static func canReconnect(workspaceID: String, configuredWorkspace: String) -> Bool {
        OpenCodeZenUsageProvider.normalizedWorkspaceId(from: configuredWorkspace)
            .map { $0 == workspaceID } ?? true
    }

    static func hasVerifiedUsage(_ result: ProviderUsageResult) -> Bool {
        (!result.bars.isEmpty && result.hasCurrentBars)
            || (result.creditsRemaining != nil && result.hasCurrentCredits)
    }

    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let store = OpenCodeValidationSecretStore(
            credential: credential,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: OpenCodeValidationRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await OpenCodeZenUsageProvider(secretStore: store, session: session).fetchUsage(for: configuration)
    }
}

private final class OpenCodeValidationRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A login redirect is not verification. Never forward the candidate cookie.
        completionHandler(nil)
    }
}

private struct OpenCodeValidationSecretStore: SecretStore {
    let credential: String
    let account: String

    func readSecret(account: String) throws -> String? {
        account == self.account ? credential : nil
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw OpenCodeSignInError.validationFailed
    }

    func deleteSecret(account: String) throws {
        throw OpenCodeSignInError.validationFailed
    }
}
