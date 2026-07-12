import Foundation

public final class CopilotUsageProvider: UsageProvider {
    private static let refreshCoordinator = CredentialRefreshCoordinator<CopilotCredentialRefreshResult>()

    private static let editorVersion = "vscode/1.96.2"
    private static let editorPluginVersion = "copilot-chat/0.26.7"
    private static let userAgentProduct = "GitHubCopilotChat/0.26.7"
    private static let githubApiVersion = "2025-04-01"
    private static let githubRestApiVersion = "2026-03-10"
    private static let githubRestUserAgent = "CodexBarIOS/1.0"
    private static let promotionalCreditsPerSeat = 7_000
    private static let standardCreditsPerSeat = 3_900

    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let githubAPIBaseURL: URL
    private let tokenEndpoint: URL
    private let oauthConfiguration: CopilotOAuthConfiguration
    private let now: @Sendable () -> Date

    public let providerID = ProviderID.copilot

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api.github.com/copilot_internal/user")!,
        githubAPIBaseURL: URL = URL(string: "https://api.github.com")!,
        tokenEndpoint: URL = URL(string: "https://github.com/login/oauth/access_token")!,
        oauthConfiguration: CopilotOAuthConfiguration = .bundled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.githubAPIBaseURL = githubAPIBaseURL
        self.tokenEndpoint = tokenEndpoint
        self.oauthConfiguration = oauthConfiguration
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            var credentials = CopilotCredentialsParser.parse(storedSecret)
        else {
            return failureResult("Not configured - sign in with GitHub.", configuration: configuration)
        }

        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        var didRefresh = false
        if credentials.shouldRefresh(at: now()) {
            guard credentials.refreshToken?.isEmpty == false else {
                if credentials.isExpired(at: now()) {
                    return failureResult(
                        "GitHub credential expired and cannot be renewed. Sign in again.",
                        configuration: configuration
                    )
                }
                return try await fetchUsage(
                    configuration: configuration,
                    credentials: credentials,
                    keychainAccount: keychainAccount,
                    canRefresh: false
                )
            }

            switch await refreshCredentials(credentials, keychainAccount: keychainAccount) {
            case .success(let refreshed):
                credentials = refreshed
                didRefresh = true
            case .expired:
                return failureResult(
                    "GitHub credential expired and cannot be renewed. Sign in again.",
                    configuration: configuration
                )
            case .rejected:
                return failureResult("GitHub credential renewal was rejected. Sign in again.", configuration: configuration)
            case .temporarilyUnavailable:
                if credentials.isExpired(at: now()) {
                    return failureResult("Could not renew the GitHub credential. Try again.", configuration: configuration)
                }
            case .persistenceFailed:
                return failureResult("Could not securely save the renewed GitHub credential. Sign in again.", configuration: configuration)
            }
        }

        return try await fetchUsage(
            configuration: configuration,
            credentials: credentials,
            keychainAccount: keychainAccount,
            canRefresh: !didRefresh
        )
    }

    private func fetchUsage(
        configuration: ProviderAccountConfiguration,
        credentials: CopilotCredentials,
        keychainAccount: String,
        canRefresh: Bool
    ) async throws -> ProviderUsageResult {
        if configuration.copilotAccountScope == .organization {
            return try await fetchOrganizationUsage(
                configuration: configuration,
                credentials: credentials,
                keychainAccount: keychainAccount,
                canRefresh: canRefresh
            )
        }

        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: credentials.accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("GitHub Copilot usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return applyAccountMetadata(
                to: CopilotUsageParser.parse(data, fetchedAt: now())
                    ?? failureResult("Could not parse GitHub Copilot usage.", configuration: configuration),
                configuration: configuration
            )
        case 401 where canRefresh && credentials.refreshToken?.isEmpty == false:
            return try await retryAfterRefresh(
                configuration: configuration,
                credentials: credentials,
                keychainAccount: keychainAccount
            )
        case 401:
            return failureResult(authenticationFailureMessage(for: credentials), configuration: configuration)
        case 403 where Self.isRateLimited(httpResponse):
            return failureResult("GitHub rate limit reached. Try again later.", configuration: configuration)
        case 403:
            return failureResult("This GitHub account does not have access to Copilot usage.", configuration: configuration)
        default:
            return failureResult("GitHub Copilot usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
        }
    }

    public func fetchUsername(accessToken: String) async throws -> String? {
        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: accessToken))
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }

        return CopilotUsageParser.username(from: data)
    }

    func makeUsageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgentProduct, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(Self.editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue(Self.githubApiVersion, forHTTPHeaderField: "X-Github-Api-Version")
        return request
    }

    func makeOrganizationBillingRequest(
        accessToken: String,
        configuration: ProviderAccountConfiguration,
        date: Date = Date()
    ) -> URLRequest? {
        let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty else {
            return nil
        }

        let enterprise = configuration.githubEnterprise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedOrganization = organization.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let calendar = Calendar(identifier: .gregorian)
        let dateComponents = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        guard let year = dateComponents.year, let month = dateComponents.month else {
            return nil
        }

        let path: String
        var queryItems = [
            URLQueryItem(name: "year", value: "\(year)"),
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "product", value: "Copilot"),
        ]

        if enterprise.isEmpty {
            path = "/organizations/\(encodedOrganization)/settings/billing/ai_credit/usage"
        } else {
            guard let encodedEnterprise = enterprise.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return nil
            }
            path = "/enterprises/\(encodedEnterprise)/settings/billing/ai_credit/usage"
            queryItems.append(URLQueryItem(name: "organization", value: organization))
        }

        var urlComponents = URLComponents(url: githubAPIBaseURL, resolvingAgainstBaseURL: false)
        urlComponents?.percentEncodedPath = path
        urlComponents?.queryItems = queryItems
        guard let url = urlComponents?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.githubRestApiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.githubRestUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func makeOrganizationSeatCountRequest(
        accessToken: String,
        configuration: ProviderAccountConfiguration
    ) -> URLRequest? {
        let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !organization.isEmpty,
            let encodedOrganization = organization.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            return nil
        }

        var urlComponents = URLComponents(url: githubAPIBaseURL, resolvingAgainstBaseURL: false)
        urlComponents?.percentEncodedPath = "/orgs/\(encodedOrganization)/copilot/billing"
        guard let url = urlComponents?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.githubRestApiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.githubRestUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func creditsPerSeat(year: Int, month: Int) -> Int {
        year == 2026 && (6...8).contains(month)
            ? promotionalCreditsPerSeat
            : standardCreditsPerSeat
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .copilot,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }

    private func fetchOrganizationUsage(
        configuration: ProviderAccountConfiguration,
        credentials: CopilotCredentials,
        keychainAccount: String,
        canRefresh: Bool
    ) async throws -> ProviderUsageResult {
        guard let request = makeOrganizationBillingRequest(
            accessToken: credentials.accessToken,
            configuration: configuration,
            date: now()
        ) else {
            return failureResult("Not configured - enter organization.", configuration: configuration)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("GitHub Copilot organization usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let effectiveAllotment = try await resolveOrganizationAllotment(
                configuration: configuration,
                accessToken: credentials.accessToken,
                date: now()
            )
            return CopilotBillingUsageParser.parse(
                data,
                configuration: configuration,
                fetchedAt: now(),
                totalAllotment: effectiveAllotment
            ) ?? failureResult("Could not parse GitHub Copilot organization usage.", configuration: configuration)
        case 401 where canRefresh && credentials.refreshToken?.isEmpty == false:
            return try await retryAfterRefresh(
                configuration: configuration,
                credentials: credentials,
                keychainAccount: keychainAccount
            )
        case 401:
            return failureResult(authenticationFailureMessage(for: credentials), configuration: configuration)
        case 403 where Self.isRateLimited(httpResponse):
            return failureResult("GitHub rate limit reached. Try again later.", configuration: configuration)
        case 403:
            return failureResult(
                "This GitHub account lacks permission to read the configured Copilot organization billing data.",
                configuration: configuration
            )
        case 404:
            return failureResult(
                "GitHub Copilot organization not found. Check the configured organization name.",
                configuration: configuration
            )
        default:
            return failureResult("GitHub Copilot organization usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
        }
    }

    private func retryAfterRefresh(
        configuration: ProviderAccountConfiguration,
        credentials: CopilotCredentials,
        keychainAccount: String
    ) async throws -> ProviderUsageResult {
        switch await refreshCredentials(credentials, keychainAccount: keychainAccount) {
        case .success(let refreshed):
            return try await fetchUsage(
                configuration: configuration,
                credentials: refreshed,
                keychainAccount: keychainAccount,
                canRefresh: false
            )
        case .expired:
            return failureResult(
                "GitHub credential expired and cannot be renewed. Sign in again.",
                configuration: configuration
            )
        case .rejected:
            return failureResult("GitHub credential renewal was rejected. Sign in again.", configuration: configuration)
        case .temporarilyUnavailable:
            return failureResult("Could not renew the GitHub credential. Try again.", configuration: configuration)
        case .persistenceFailed:
            return failureResult("Could not securely save the renewed GitHub credential. Sign in again.", configuration: configuration)
        }
    }

    private func refreshCredentials(
        _ credentials: CopilotCredentials,
        keychainAccount: String
    ) async -> CopilotCredentialRefreshResult {
        await Self.refreshCoordinator.run(for: keychainAccount) { [self] in
            await performCredentialRefresh(credentials, keychainAccount: keychainAccount)
        }
    }

    private func performCredentialRefresh(
        _ credentials: CopilotCredentials,
        keychainAccount: String
    ) async -> CopilotCredentialRefreshResult {
        do {
            guard
                let storedSecret = try secretStore.readSecret(account: keychainAccount),
                let latestCredentials = CopilotCredentialsParser.parse(storedSecret)
            else {
                return .rejected
            }
            if latestCredentials != credentials {
                return .success(latestCredentials)
            }
        } catch {
            return .temporarilyUnavailable
        }

        let refreshedAt = now()
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .rejected
        }
        if let refreshTokenExpiresAt = credentials.refreshTokenExpiresAt,
           Date(timeIntervalSince1970: TimeInterval(refreshTokenExpiresAt)) <= refreshedAt {
            return .expired
        }

        let clientID = oauthConfiguration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = oauthConfiguration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return .temporarilyUnavailable
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CopilotWebAuthService.makeRefreshTokenRequestBody(
            clientID: clientID,
            clientSecret: clientSecret,
            refreshToken: refreshToken
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .temporarilyUnavailable
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                return [400, 401, 403].contains(httpResponse.statusCode) ? .rejected : .temporarilyUnavailable
            }
            guard let tokenResponse = try? JSONDecoder().decode(CopilotTokenRefreshResponse.self, from: data) else {
                return .temporarilyUnavailable
            }
            if tokenResponse.error != nil {
                return .rejected
            }
            guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
                return .temporarilyUnavailable
            }

            let rotatedRefreshToken = tokenResponse.refreshToken ?? credentials.refreshToken
            let updated = CopilotCredentials(
                accessToken: accessToken,
                username: credentials.username,
                refreshToken: rotatedRefreshToken,
                expiresAt: tokenResponse.expiresIn.map {
                    Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
                },
                refreshTokenExpiresAt: tokenResponse.refreshTokenExpiresIn.map {
                    Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
                } ?? credentials.refreshTokenExpiresAt
            )

            do {
                guard
                    let storedSecret = try secretStore.readSecret(account: keychainAccount),
                    let latestCredentials = CopilotCredentialsParser.parse(storedSecret)
                else {
                    return .rejected
                }
                if latestCredentials != credentials {
                    return .success(latestCredentials)
                }
                try secretStore.saveSecret(
                    CopilotCredentialsParser.storedCredential(from: updated),
                    account: keychainAccount
                )
            } catch {
                return .persistenceFailed
            }
            return .success(updated)
        } catch {
            return .temporarilyUnavailable
        }
    }

    func resolveOrganizationAllotment(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        date: Date = Date()
    ) async throws -> Double? {
        if let override = configuration.copilotTotalAllotment, override > 0 {
            return override
        }

        guard let request = makeOrganizationSeatCountRequest(accessToken: accessToken, configuration: configuration) else {
            return nil
        }

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let seatCount = CopilotSeatCountParser.parse(data),
            seatCount > 0
        else {
            return nil
        }

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        guard let year = components.year, let month = components.month else {
            return nil
        }

        return Double(seatCount * Self.creditsPerSeat(year: year, month: month))
    }

    private func authenticationFailureMessage(for credentials: CopilotCredentials) -> String {
        if credentials.isExpired(at: now()) {
            return "GitHub credential expired. Sign in again."
        }
        if credentials.expiresAt != nil {
            return "GitHub authorization was revoked. Sign in again."
        }
        return "GitHub credential was rejected. Sign in again."
    }

    private static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Retry-After") != nil
            || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
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
}

private enum CopilotCredentialRefreshResult: Sendable {
    case success(CopilotCredentials)
    case expired
    case rejected
    case temporarilyUnavailable
    case persistenceFailed
}

private struct CopilotTokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let refreshTokenExpiresIn: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
    }
}
