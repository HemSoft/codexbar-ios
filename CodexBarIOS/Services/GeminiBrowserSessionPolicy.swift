import Foundation

enum GeminiBrowserSessionPolicy {
    static let usageURL = URL(string: "https://gemini.google.com/usage?pli=1")!

    static func allowsNavigation(to url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "google.com" || host.hasSuffix(".google.com")
    }

    static func isUsagePage(_ url: URL?) -> Bool {
        allowsNavigation(to: url) && url?.host?.lowercased() == "gemini.google.com"
            && url?.path == "/usage"
    }

    static func canReturnToUsage(from url: URL?) -> Bool {
        guard allowsNavigation(to: url), let host = url?.host?.lowercased() else { return false }
        return host == "myaccount.google.com" || host == "gemini.google.com"
    }

    static func storedCredential(from cookies: [HTTPCookie], now: Date = Date()) throws -> String? {
        // Only root-domain cookies reach both the usage page and its web RPC. Reject
        // ambiguous duplicates instead of pairing credentials from different scopes.
        let names = ["__Secure-1PSID", "__Secure-1PSIDTS"]
        let eligible = cookies.filter {
            names.contains($0.name) && $0.isSecure && $0.path == "/"
                && $0.domain.lowercased() == ".google.com"
                && ($0.expiresDate.map { $0 > now } ?? true)
        }
        var values: [String: String] = [:]
        for name in names {
            let candidates = Set(eligible.filter { $0.name == name }.map(\.value))
            guard candidates.count <= 1 else { throw GeminiSignInError.ambiguousSession }
            values[name] = candidates.first
        }
        guard values["__Secure-1PSID"] != nil else { return nil }
        let data = try JSONEncoder().encode(values)
        guard let text = String(data: data, encoding: .utf8) else { throw GeminiSignInError.ambiguousSession }
        return try GeminiSessionCredentialsParser.storedCredential(from: text)
    }
}

enum GeminiSignInError: LocalizedError {
    case canceled
    case browserFailed
    case ambiguousSession
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .canceled:
            "Google sign-in canceled. Your saved account was not changed."
        case .browserFailed:
            "Google sign-in could not load. Check your connection and try again. Your saved account was not changed."
        case .ambiguousSession:
            "Google returned an ambiguous session. Try signing in again. Your saved account was not changed."
        case .validationFailed:
            "Google sign-in could not verify Gemini usage. Try again. Your saved account was not changed."
        }
    }
}

protocol GeminiSessionValidating: Sendable {
    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult
}

struct GeminiSessionValidator: GeminiSessionValidating {
    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let store = GeminiValidationSecretStore(
            credential: credential,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        return try await GeminiUsageProvider(secretStore: store).fetchUsage(for: configuration)
    }
}

private struct GeminiValidationSecretStore: SecretStore {
    let credential: String
    let account: String

    func readSecret(account: String) throws -> String? {
        account == self.account ? credential : nil
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw GeminiSignInError.validationFailed
    }

    func deleteSecret(account: String) throws {
        throw GeminiSignInError.validationFailed
    }
}
