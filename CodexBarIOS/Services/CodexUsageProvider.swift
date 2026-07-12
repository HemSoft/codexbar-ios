import Foundation

public final class CodexUsageProvider: UsageProvider {
    private static let refreshCoordinator = CredentialRefreshCoordinator<CredentialRefreshResult>()

    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let tokenEndpoint: URL
    private let now: @Sendable () -> Date

    public let providerID = ProviderID.codex

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        tokenEndpoint: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard
            let storedSecret = try secretStore.readSecret(account: keychainAccount),
            var credentials = CodexCredentialsParser.parse(storedSecret)
        else {
            return failureResult("Not configured - sign in with ChatGPT.", configuration: configuration)
        }

        var didRefresh = false
        if credentials.shouldRefresh(at: now()) {
            guard credentials.refreshToken?.isEmpty == false else {
                if credentials.isExpired(at: now()) {
                    return failureResult(
                        "ChatGPT / Codex credential expired and cannot be renewed. Sign in again.",
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
            case .rejected:
                return failureResult(
                    "ChatGPT / Codex credential renewal was rejected. Sign in again.",
                    configuration: configuration
                )
            case .temporarilyUnavailable:
                if credentials.isExpired(at: now()) {
                    return failureResult(
                        "Could not renew the ChatGPT / Codex credential. Try again.",
                        configuration: configuration
                    )
                }
            case .persistenceFailed:
                return failureResult(
                    "Could not securely save the renewed ChatGPT / Codex credential. Sign in again.",
                    configuration: configuration
                )
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
        credentials: CodexCredentials,
        keychainAccount: String,
        canRefresh: Bool
    ) async throws -> ProviderUsageResult {
        let (data, response) = try await session.data(for: makeUsageRequest(credentials: credentials))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("ChatGPT usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return applyAccountMetadata(
                to: CodexUsageParser.parse(data, fetchedAt: now())
                    ?? failureResult("Could not parse ChatGPT usage.", configuration: configuration),
                configuration: configuration
            )
        case 401 where canRefresh && credentials.refreshToken?.isEmpty == false:
            switch await refreshCredentials(credentials, keychainAccount: keychainAccount) {
            case .success(let refreshed):
                return try await fetchUsage(
                    configuration: configuration,
                    credentials: refreshed,
                    keychainAccount: keychainAccount,
                    canRefresh: false
                )
            case .rejected:
                return failureResult(
                    "ChatGPT / Codex credential renewal was rejected. Sign in again.",
                    configuration: configuration
                )
            case .temporarilyUnavailable:
                return failureResult(
                    "Could not renew the ChatGPT / Codex credential. Try again.",
                    configuration: configuration
                )
            case .persistenceFailed:
                return failureResult(
                    "Could not securely save the renewed ChatGPT / Codex credential. Sign in again.",
                    configuration: configuration
                )
            }
        case 401:
            return failureResult(
                authenticationFailureMessage(for: credentials),
                configuration: configuration
            )
        case 403:
            return failureResult(
                "This ChatGPT account does not have access to Codex usage.",
                configuration: configuration
            )
        default:
            return failureResult("ChatGPT usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
        }
    }

    private func makeUsageRequest(credentials: CodexCredentials) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    private func refreshCredentials(
        _ credentials: CodexCredentials,
        keychainAccount: String
    ) async -> CredentialRefreshResult {
        await Self.refreshCoordinator.run(for: keychainAccount) { [self] in
            await performCredentialRefresh(credentials, keychainAccount: keychainAccount)
        }
    }

    private func performCredentialRefresh(
        _ credentials: CodexCredentials,
        keychainAccount: String
    ) async -> CredentialRefreshResult {
        do {
            guard
                let storedSecret = try secretStore.readSecret(account: keychainAccount),
                let latestCredentials = CodexCredentialsParser.parse(storedSecret)
            else {
                return .rejected
            }
            if latestCredentials != credentials {
                return .success(latestCredentials)
            }
        } catch {
            return .temporarilyUnavailable
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .rejected
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CodexWebAuthService.makeRefreshTokenRequestBody(refreshToken: refreshToken)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .temporarilyUnavailable
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                return [400, 401, 403].contains(httpResponse.statusCode) ? .rejected : .temporarilyUnavailable
            }
            guard let tokenResponse = try? JSONDecoder().decode(CodexTokenRefreshResponse.self, from: data) else {
                return .temporarilyUnavailable
            }
            if tokenResponse.error != nil {
                return .rejected
            }
            guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
                return .temporarilyUnavailable
            }

            let refreshedAt = now()
            let idToken = tokenResponse.idToken ?? credentials.idToken
            let parsedAccessToken = CodexCredentialsParser.parse(accessToken)
            let parsedIDToken = idToken.flatMap(CodexCredentialsParser.parse)
            let updated = CodexCredentials(
                accessToken: accessToken,
                refreshToken: tokenResponse.refreshToken ?? credentials.refreshToken,
                idToken: idToken,
                accountID: parsedIDToken?.accountID
                    ?? parsedAccessToken?.accountID
                    ?? credentials.accountID,
                expiresAt: tokenResponse.expiresAt.map(CodexCredentials.normalizedEpochSeconds)
                    ?? tokenResponse.expiresIn.map {
                        Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
                    }
                    ?? parsedAccessToken?.expiresAt
                    ?? parsedIDToken?.expiresAt
            )

            do {
                guard
                    let storedSecret = try secretStore.readSecret(account: keychainAccount),
                    let latestCredentials = CodexCredentialsParser.parse(storedSecret)
                else {
                    return .rejected
                }
                if latestCredentials != credentials {
                    return .success(latestCredentials)
                }
                try secretStore.saveSecret(
                    CodexCredentialsParser.storedCredential(from: updated),
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

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: now()
        )
    }

    private func authenticationFailureMessage(for credentials: CodexCredentials) -> String {
        if credentials.isExpired(at: now()) {
            return "ChatGPT / Codex credential expired. Sign in again."
        }
        if credentials.expiresAt != nil {
            return "ChatGPT / Codex authorization was revoked. Sign in again."
        }
        return "ChatGPT / Codex credential was rejected. Sign in again."
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

private enum CredentialRefreshResult: Sendable {
    case success(CodexCredentials)
    case rejected
    case temporarilyUnavailable
    case persistenceFailed
}

private struct CodexTokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int64?
    let expiresAt: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case error
    }
}
