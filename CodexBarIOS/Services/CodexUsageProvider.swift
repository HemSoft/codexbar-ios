import Foundation

public enum CodexBankedResetConsumptionOutcome: String, Equatable, Sendable {
    case reset
    case alreadyRedeemed = "already_redeemed"
    case nothingToReset = "nothing_to_reset"
    case noCredit = "no_credit"
}

public enum CodexBankedResetConsumptionError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case credentialUnavailable
    case unsupported
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Sign in with ChatGPT before using a banked reset."
        case .credentialUnavailable:
            "The ChatGPT credential could not be renewed. Sign in again."
        case .unsupported:
            "Banked reset redemption is not available for this account."
        case .invalidRequest:
            "Could not prepare this reset request. Try again."
        case .invalidResponse:
            "ChatGPT returned an unexpected reset response. Try again."
        case .httpStatus(let status):
            "ChatGPT could not use the reset (HTTP \(status)). Try again."
        }
    }
}

public protocol CodexBankedResetConsuming: UsageProvider {
    func consumeBankedReset(
        for configuration: ProviderAccountConfiguration,
        creditID: String?,
        idempotencyKey: String
    ) async throws -> CodexBankedResetConsumptionOutcome
}

public final class CodexUsageProvider: CodexBankedResetConsuming {
    private static let refreshCoordinator = CredentialRefreshCoordinator<ProviderCredentialRefreshResult<CodexCredentials>>()

    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let resetCreditsEndpoint: URL
    private let consumeResetEndpoint: URL
    private let tokenEndpoint: URL
    private let now: @Sendable () -> Date

    public let providerID = ProviderID.codex

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        resetCreditsEndpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!,
        consumeResetEndpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!,
        tokenEndpoint: URL = CodexWebAuthService.tokenEndpoint,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.resetCreditsEndpoint = resetCreditsEndpoint
        self.consumeResetEndpoint = consumeResetEndpoint
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
            case .expired, .rejected:
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
            let parsedResult = CodexUsageParser.parse(data, fetchedAt: now())
                ?? failureResult("Could not parse ChatGPT usage.", configuration: configuration)
            let resultWithResetDetails = await addResetDetails(
                to: parsedResult,
                credentials: credentials
            )
            return applyAccountMetadata(
                to: resultWithResetDetails,
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
            case .expired, .rejected:
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
        authenticatedRequest(url: usageEndpoint, method: "GET", credentials: credentials)
    }

    private func authenticatedRequest(
        url: URL,
        method: String,
        credentials: CodexCredentials
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    private func addResetDetails(
        to result: ProviderUsageResult,
        credentials: CodexCredentials
    ) async -> ProviderUsageResult {
        guard result.codexBankedRateLimitResets != nil else {
            return result
        }

        var request = authenticatedRequest(
            url: resetCreditsEndpoint,
            method: "GET",
            credentials: credentials
        )
        request.timeoutInterval = 15

        guard
            let (data, response) = try? await session.data(for: request),
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let details = CodexUsageParser.parseResetCredits(data, canConsume: true)
        else {
            return result
        }

        return replacingResetCredits(in: result, with: details)
    }

    public func consumeBankedReset(
        for configuration: ProviderAccountConfiguration,
        creditID: String?,
        idempotencyKey: String
    ) async throws -> CodexBankedResetConsumptionOutcome {
        guard !idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexBankedResetConsumptionError.invalidRequest
        }

        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        let credentials = try await credentialsForResetConsumption(keychainAccount: keychainAccount)
        return try await consumeBankedReset(
            creditID: creditID,
            idempotencyKey: idempotencyKey,
            credentials: credentials,
            keychainAccount: keychainAccount,
            canRefresh: true
        )
    }

    private func consumeBankedReset(
        creditID: String?,
        idempotencyKey: String,
        credentials: CodexCredentials,
        keychainAccount: String,
        canRefresh: Bool
    ) async throws -> CodexBankedResetConsumptionOutcome {
        var request = authenticatedRequest(
            url: consumeResetEndpoint,
            method: "POST",
            credentials: credentials
        )
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(CodexResetConsumptionRequest(
            redeemRequestID: idempotencyKey,
            creditID: creditID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ))
        guard request.httpBody != nil else {
            throw CodexBankedResetConsumptionError.invalidRequest
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexBankedResetConsumptionError.invalidResponse
        }

        if httpResponse.statusCode == 401, canRefresh, credentials.refreshToken?.isEmpty == false {
            guard case .success(let refreshed) = await refreshCredentials(
                credentials,
                keychainAccount: keychainAccount
            ) else {
                throw CodexBankedResetConsumptionError.credentialUnavailable
            }
            return try await consumeBankedReset(
                creditID: creditID,
                idempotencyKey: idempotencyKey,
                credentials: refreshed,
                keychainAccount: keychainAccount,
                canRefresh: false
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw CodexBankedResetConsumptionError.credentialUnavailable
            }
            if httpResponse.statusCode == 403 || httpResponse.statusCode == 404 {
                throw CodexBankedResetConsumptionError.unsupported
            }
            throw CodexBankedResetConsumptionError.httpStatus(httpResponse.statusCode)
        }

        guard
            let decoded = try? JSONDecoder().decode(CodexResetConsumptionResponse.self, from: data),
            let outcome = CodexBankedResetConsumptionOutcome(rawValue: decoded.code)
        else {
            throw CodexBankedResetConsumptionError.invalidResponse
        }
        return outcome
    }

    private func credentialsForResetConsumption(
        keychainAccount: String
    ) async throws -> CodexCredentials {
        guard
            let storedSecret = try secretStore.readSecret(account: keychainAccount),
            let credentials = CodexCredentialsParser.parse(storedSecret)
        else {
            throw CodexBankedResetConsumptionError.notConfigured
        }

        guard credentials.shouldRefresh(at: now()) else {
            return credentials
        }
        guard credentials.refreshToken?.isEmpty == false else {
            throw CodexBankedResetConsumptionError.credentialUnavailable
        }
        guard case .success(let refreshed) = await refreshCredentials(
            credentials,
            keychainAccount: keychainAccount
        ) else {
            throw CodexBankedResetConsumptionError.credentialUnavailable
        }
        return refreshed
    }

    private func refreshCredentials(
        _ credentials: CodexCredentials,
        keychainAccount: String
    ) async -> ProviderCredentialRefreshResult<CodexCredentials> {
        await Self.refreshCoordinator.run(for: keychainAccount) { [self] in
            await performCredentialRefresh(credentials, keychainAccount: keychainAccount)
        }
    }

    private func performCredentialRefresh(
        _ credentials: CodexCredentials,
        keychainAccount: String
    ) async -> ProviderCredentialRefreshResult<CodexCredentials> {
        await performProviderCredentialRefresh(
            credentials: credentials,
            keychainAccount: keychainAccount,
            secretStore: secretStore,
            session: session,
            now: now,
            parse: { CodexCredentialsParser.parse($0) },
            storedCredential: { CodexCredentialsParser.storedCredential(from: $0) },
            prepare: { [tokenEndpoint] _ in
                guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
                    return .finished(.rejected)
                }

                var request = URLRequest(url: tokenEndpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = CodexWebAuthService.makeRefreshTokenRequestBody(refreshToken: refreshToken)
                return .request(request)
            },
            decode: { data, refreshedAt in
                guard let tokenResponse = try? JSONDecoder().decode(CodexTokenRefreshResponse.self, from: data) else {
                    return .temporarilyUnavailable
                }
                if tokenResponse.error != nil {
                    return .rejected
                }
                guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
                    return .temporarilyUnavailable
                }

                let idToken = tokenResponse.idToken ?? credentials.idToken
                let parsedAccessToken = CodexCredentialsParser.parse(accessToken)
                let parsedIDToken = idToken.flatMap(CodexCredentialsParser.parse)
                return .success(CodexCredentials(
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
                ))
            }
        )
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
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
            barsFetchedAt: result.barsFetchedAt,
            creditsRemaining: result.creditsRemaining,
            monetaryMetrics: result.monetaryMetrics,
            usageMessages: result.usageMessages,
            codexBankedRateLimitResets: result.codexBankedRateLimitResets,
            failureMessage: result.failureMessage,
            fetchedAt: result.fetchedAt
        )
    }

    private func replacingResetCredits(
        in result: ProviderUsageResult,
        with resets: CodexBankedRateLimitResets?
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            barsFetchedAt: result.barsFetchedAt,
            creditsRemaining: result.creditsRemaining,
            monetaryMetrics: result.monetaryMetrics,
            usageMessages: result.usageMessages,
            codexBankedRateLimitResets: resets,
            failureMessage: result.failureMessage,
            fetchedAt: result.fetchedAt
        )
    }

}

private struct CodexResetConsumptionRequest: Encodable {
    let redeemRequestID: String
    let creditID: String?

    enum CodingKeys: String, CodingKey {
        case redeemRequestID = "redeem_request_id"
        case creditID = "credit_id"
    }
}

private struct CodexResetConsumptionResponse: Decodable {
    let code: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
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
