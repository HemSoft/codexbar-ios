import Foundation

public final class ClaudeUsageProvider: UsageProvider {
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenRefreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let messagesEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let probeBody = """
    {"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}
    """

    private let secretStore: SecretStore
    private let session: URLSession

    public let providerID = ProviderID.claude

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared
    ) {
        self.secretStore = secretStore
        self.session = session
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            let parsedCredentials = ClaudeCredentialsParser.parse(storedSecret),
            let accessToken = parsedCredentials.accessToken,
            !accessToken.isEmpty
        else {
            return failureResult("Not configured - sign in with Claude.", configuration: configuration)
        }

        let credentials = try await refreshedCredentialsIfNeeded(parsedCredentials, configuration: configuration)
        guard let token = credentials.accessToken, !token.isEmpty else {
            return failureResult("Claude credential is missing an access token.", configuration: configuration)
        }

        if let usageResult = try await fetchOAuthUsage(configuration: configuration, credentials: credentials, accessToken: token) {
            return usageResult
        }

        if let rateLimitResult = try await fetchRateLimitUsage(configuration: configuration, credentials: credentials, accessToken: token) {
            return rateLimitResult
        }

        return failureResult("Claude usage did not include rate-limit windows.", configuration: configuration)
    }

    private func fetchOAuthUsage(
        configuration: ProviderAccountConfiguration,
        credentials: ClaudeCredentials,
        accessToken: String
    ) async throws -> ProviderUsageResult? {
        let fetchedAt = Date()
        let (data, response) = try await session.data(for: makeOAuthUsageRequest(accessToken: accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("Claude usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            guard let parsed = ClaudeUsageParser.parse(
                data,
                subscriptionType: credentials.subscriptionType,
                fetchedAt: fetchedAt
            ) else {
                return nil
            }
            return applyAccountMetadata(to: parsed, configuration: configuration)
        case 401, 403:
            return failureResult("Claude credential expired or lacks Claude Code access.", configuration: configuration)
        default:
            return nil
        }
    }

    private func fetchRateLimitUsage(
        configuration: ProviderAccountConfiguration,
        credentials: ClaudeCredentials,
        accessToken: String
    ) async throws -> ProviderUsageResult? {
        let fetchedAt = Date()
        let (_, response) = try await session.data(for: makeRateLimitProbeRequest(accessToken: accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        guard httpResponse.statusCode != 401 && httpResponse.statusCode != 403 else {
            return failureResult("Claude credential expired or lacks Claude Code access.", configuration: configuration)
        }

        guard let parsed = ClaudeUsageParser.parseRateLimitHeaders(
            httpResponse.allHeaderFields,
            subscriptionType: credentials.subscriptionType,
            fetchedAt: fetchedAt
        ) else {
            return nil
        }

        return applyAccountMetadata(to: parsed, configuration: configuration)
    }

    private func refreshedCredentialsIfNeeded(
        _ credentials: ClaudeCredentials,
        configuration: ProviderAccountConfiguration
    ) async throws -> ClaudeCredentials {
        guard credentials.expiresAt > 0 else {
            return credentials
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(normalizeEpochToSeconds(credentials.expiresAt)))
        guard expiresAt <= Date() else {
            return credentials
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return credentials
        }

        var request = URLRequest(url: Self.tokenRefreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ])

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let refreshed = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data),
            let accessToken = refreshed.accessToken,
            !accessToken.isEmpty
        else {
            return credentials
        }

        let updated = ClaudeCredentials(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            expiresAt: refreshed.expiresAt ?? refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)).claudeUsageUnixTimeMilliseconds } ?? 0,
            accessToken: accessToken,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken
        )
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: updated),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        return updated
    }

    private func makeOAuthUsageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func makeRateLimitProbeRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: Self.messagesEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.probeBody.utf8)
        return request
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }

    private func applyAccountMetadata(
        to result: ProviderUsageResult,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: result.providerID,
            title: configuration.displayName,
            subtitle: result.subtitle,
            bars: result.bars,
            fetchedAt: result.fetchedAt
        )
    }

    private func normalizeEpochToSeconds(_ value: Int64) -> Int64 {
        value >= 1_000_000_000_000 ? value / 1000 : value
    }
}

private struct TokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }
}

private extension Date {
    var claudeUsageUnixTimeMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
