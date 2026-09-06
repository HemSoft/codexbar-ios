import Foundation

public final class AntigravityUsageProvider: UsageProvider {
    public let providerID = ProviderID.antigravity
    private let secretStore: SecretStore
    private let session: URLSession
    static let quotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private enum FetchError: Error {
        case credential, response, changedCredential
        case http(Int)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    public convenience init(secretStore: SecretStore = KeychainService()) {
        self.init(secretStore: secretStore, sessionConfiguration: .ephemeral)
    }

    init(secretStore: SecretStore, sessionConfiguration: URLSessionConfiguration) {
        self.secretStore = secretStore
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: sessionConfiguration, delegate: RedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        do {
            let account = ProviderConfigurationStore.keychainAccount(for: configuration)
            guard let stored = try secretStore.readSecret(account: account) else { throw FetchError.credential }
            let credentials = try AntigravityCredentials.parse(stored)
            let data = try await quotaData(credentials, account: account, original: stored)
            try Task.checkCancellation()
            return try AntigravityQuotaParser.result(from: data, configuration: configuration)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            return failure(error, configuration: configuration)
        }
    }

    private func quotaData(_ credentials: AntigravityCredentials, account: String, original: String) async throws -> Data {
        if credentials.expiry.map({ $0 <= Date().addingTimeInterval(60) }) == true {
            let renewed = try await refresh(credentials, account: account, original: original)
            return try await responseData(for: quotaRequest(token: renewed.accessToken))
        }
        do {
            return try await responseData(for: quotaRequest(token: credentials.accessToken))
        } catch FetchError.http(401) where credentials.canRefresh {
            let renewed = try await refresh(credentials, account: account, original: original)
            return try await responseData(for: quotaRequest(token: renewed.accessToken))
        }
    }

    func quotaRequest(token: String) -> URLRequest {
        var request = URLRequest(url: Self.quotaURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.response }
        guard http.statusCode == 200 else { throw FetchError.http(http.statusCode) }
        guard data.count <= 1_048_576 else { throw FetchError.response }
        return data
    }

    private func refresh(
        _ credentials: AntigravityCredentials,
        account: String,
        original: String
    ) async throws -> AntigravityCredentials {
        guard credentials.canRefresh else { throw FetchError.credential }
        let data = try await responseData(for: refreshRequest(credentials))
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard token.expiresIn.isFinite, token.expiresIn > 0, token.expiresIn <= 86_400 else { throw FetchError.response }
        var updated = credentials
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken ?? credentials.refreshToken
        updated.expiry = Date().addingTimeInterval(token.expiresIn)
        let encoded = try updated.encoded()
        _ = try AntigravityCredentials.parse(encoded)
        try Task.checkCancellation()
        try await saveRenewedCredential(encoded, account: account, original: original)
        return updated
    }

    func refreshRequest(_ credentials: AntigravityCredentials) -> URLRequest {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: credentials.refreshToken),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
        ]
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return request
    }

    // Account replacement and disconnect run on MainActor in ProviderSettingsViewModel.
    // Keep this synchronous compare-and-save on the same actor so logout cannot
    // interleave between the two Keychain operations. Network I/O stays off actor.
    @MainActor
    private func saveRenewedCredential(_ encoded: String, account: String, original: String) throws {
        guard try secretStore.readSecret(account: account) == original else { throw FetchError.changedCredential }
        try secretStore.saveSecret(encoded, account: account)
    }

    private func failure(_ error: Error, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        let message: String
        let recovery: ProviderUsageRecoveryAction
        switch error {
        case FetchError.credential, is AntigravityCredentials.CredentialError,
             FetchError.http(400), FetchError.http(401), FetchError.http(403):
            message = "Antigravity needs a current session. Import fresh credentials from your desktop."
            recovery = .reauthenticate
        case FetchError.changedCredential:
            message = "Antigravity credentials changed during refresh. Refresh this account again."
            recovery = .retryRefresh
        default:
            message = "Antigravity quotas are unavailable. Try refreshing again."
            recovery = .retryRefresh
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .antigravity,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            recoveryAction: recovery,
            fetchedAt: Date()
        )
    }
}
