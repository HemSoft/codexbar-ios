import CryptoKit
import Foundation

public final class GrokUsageProvider: UsageProvider {
    private static let refreshCoordinator = CredentialRefreshCoordinator<ProviderCredentialRefreshResult<GrokCredential>>()
    private static let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private enum CredentialState {
        case ready(GrokCredential)
        case retry
        case reconnect
    }

    public let providerID = ProviderID.grok
    private let secretStore: SecretStore
    private let session: URLSession
    private let auth: GrokDeviceAuthService

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession? = nil
    ) {
        let session = session ?? GrokDeviceAuthService.makeSession()
        self.secretStore = secretStore
        self.session = session
        self.auth = GrokDeviceAuthService(session: session)
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard let stored = try secretStore.readSecret(account: account),
              let candidate = GrokCredential.parse(stored) else {
            return failure("Sign in with Grok to see consumer usage.", configuration: configuration)
        }
        let state = await currentCredential(candidate, keychainAccount: account)
        guard case .ready(let credential) = state else { return credentialFailure(state, configuration: configuration) }
        do {
            let result = try await fetchCandidate(credential, for: configuration)
            return try GrokCredentialLock.withLock {
                guard let saved = try secretStore.readSecret(account: account),
                      GrokCredential.parse(saved) == credential else { throw GrokAuthError.unauthorized }
                return result
            }
        } catch {
            return usageFailure(error, configuration: configuration)
        }
    }

    private func credentialFailure(
        _ state: CredentialState, configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        switch state {
        case .ready: failure("Grok usage could not be verified.", configuration: configuration)
        case .retry: failure(
            "Grok usage is temporarily unavailable. Try refreshing again.",
            configuration: configuration, recoveryAction: .retryRefresh
        )
        case .reconnect: failure(
            "Grok authorization expired or was removed. Reconnect in account settings.",
            configuration: configuration
        )
        }
    }

    private func usageFailure(_ error: Error, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        if error as? GrokAuthError == .unauthorized {
            return failure("Grok authorization was rejected. Reconnect in account settings.", configuration: configuration)
        }
        return failure(
            "Grok usage could not be verified. Try refreshing again.",
            configuration: configuration, recoveryAction: .retryRefresh
        )
    }

    func fetchCandidate(
        _ credential: GrokCredential,
        for configuration: ProviderAccountConfiguration
    ) async throws -> ProviderUsageResult {
        let identity = try await auth.userInfo(accessToken: credential.accessToken)
        guard identity.sub == credential.subject else { throw GrokAuthError.unauthorized }
        var request = URLRequest(url: Self.creditsURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            throw GrokAuthError.invalidResponse
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw GrokAuthError.unauthorized }
        if response.statusCode == 429 || (500...599).contains(response.statusCode) {
            throw GrokAuthError.temporarilyUnavailable
        }
        guard response.statusCode == 200 else { throw GrokAuthError.unsupportedAccount }
        return try Self.parseCredits(data, configuration: configuration, subject: identity.sub, now: Date())
    }

    func verifyCandidate(
        _ credential: GrokCredential, for configuration: ProviderAccountConfiguration,
        retryUntil deadline: Date,
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> ProviderUsageResult {
        var interval: TimeInterval = 5
        while true {
            try Task.checkCancellation()
            do {
                return try await fetchCandidate(credential, for: configuration)
            } catch {
                guard Self.isRetryableCandidateFailure(error), Date() < deadline else { throw error }
                try await sleep(min(interval, max(0, deadline.timeIntervalSinceNow)))
                interval = min(20, interval + 5)
            }
        }
    }

    private static func isRetryableCandidateFailure(_ error: Error) -> Bool {
        if let authError = error as? GrokAuthError {
            return authError == .temporarilyUnavailable || authError == .invalidResponse
        }
        if let networkError = error as? URLError {
            return GrokDeviceAuthService.isTransientNetworkError(networkError)
        }
        return false
    }

    private func currentCredential(_ credential: GrokCredential, keychainAccount: String) async -> CredentialState {
        guard credential.expiresAt <= Date().addingTimeInterval(60) else { return .ready(credential) }
        let outcome = await Self.refreshCoordinator.run(for: keychainAccount) { [self] in
            await self.refresh(credential, keychainAccount: keychainAccount)
        }
        if case .success(let updated) = outcome, updated.subject == credential.subject { return .ready(updated) }
        if case .temporarilyUnavailable = outcome { return .retry }
        return .reconnect
    }

    private func refresh(
        _ credential: GrokCredential, keychainAccount: String
    ) async -> ProviderCredentialRefreshResult<GrokCredential> {
        do {
            guard let latest = try GrokCredentialLock.withLock({
                GrokCredential.parse(try secretStore.readSecret(account: keychainAccount))
            }) else { return .rejected }
            if latest != credential { return .success(latest) }
            let renewed = try await renewedCredential(for: credential)
            guard case .success(let updated) = renewed else { return renewed }
            return try saveRenewedCredential(updated, replacing: credential, account: keychainAccount)
        } catch {
            return .temporarilyUnavailable
        }
    }

    private func renewedCredential(
        for credential: GrokCredential
    ) async throws -> ProviderCredentialRefreshResult<GrokCredential> {
        let (data, status) = try await auth.post("oauth2/token", values: [
            ("grant_type", "refresh_token"), ("refresh_token", credential.refreshToken),
            ("client_id", GrokDeviceAuthService.clientID),
        ])
        guard status == 200 else {
            return Self.isRejectedRenewal(data, status: status) ? .rejected : .temporarilyUnavailable
        }
        guard let token = try? GrokDeviceAuthService.token(data) else { return .temporarilyUnavailable }
        let expiresAt = Date().addingTimeInterval(token.expiresIn)
        let identity: GrokIdentity
        do {
            identity = try await auth.verifiedIdentity(
                accessToken: token.accessToken,
                deadline: min(expiresAt, Date().addingTimeInterval(90))
            )
        } catch GrokAuthError.unauthorized {
            return .rejected
        }
        guard identity.sub == credential.subject else { return .rejected }
        return .success(GrokCredential(
            kind: credential.kind, accessToken: token.accessToken,
            refreshToken: token.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? credential.refreshToken,
            expiresAt: expiresAt, subject: credential.subject,
            email: identity.email ?? credential.email
        ))
    }

    private static func isRejectedRenewal(_ data: Data, status: Int) -> Bool {
        guard [400, 401, 403].contains(status),
              let reply = try? JSONDecoder().decode(GrokRenewalError.self, from: data) else { return false }
        return reply.error == "invalid_grant" || reply.error == "invalid_token"
    }

    private func saveRenewedCredential(
        _ updated: GrokCredential, replacing credential: GrokCredential, account: String
    ) throws -> ProviderCredentialRefreshResult<GrokCredential> {
        try GrokCredentialLock.withLock {
            guard let saved = try secretStore.readSecret(account: account),
                  let current = GrokCredential.parse(saved) else { return .rejected }
            if current != credential { return .success(current) }
            try secretStore.saveSecret(try updated.encoded(), account: account)
            return .success(updated)
        }
    }

    private func failure(
        _ message: String, configuration: ProviderAccountConfiguration,
        recoveryAction: ProviderUsageRecoveryAction = .reauthenticate
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id, providerID: .grok, title: configuration.displayName,
            subtitle: message, bars: [], failureMessage: message, recoveryAction: recoveryAction,
            fetchedAt: Date()
        )
    }

    static func parseCredits(
        _ data: Data, configuration: ProviderAccountConfiguration, subject: String, now: Date
    ) throws -> ProviderUsageResult {
        guard let response = try? JSONDecoder().decode(GrokCreditsResponse.self, from: data),
              let config = response.config else { throw GrokAuthError.invalidResponse }
        let period = config.currentPeriod
        let start = period?.start.flatMap(date)
        let end = period?.end.flatMap(date)
        let supportedPeriod = ["USAGE_PERIOD_TYPE_WEEKLY", "USAGE_PERIOD_TYPE_MONTHLY"].contains(period?.type ?? "")
        let activePeriod = supportedPeriod && start != nil && end != nil
            && start! <= now && end! > now
        let percent = config.creditUsagePercent
        let hasPercent = percent != nil && percent!.isFinite && percent! >= 0
        let bar: UsageBar? = if activePeriod && hasPercent && config.isUnifiedBillingUser != false {
            UsageBar(
                stableKey: "included-usage", label: period?.type == "USAGE_PERIOD_TYPE_WEEKLY"
                    ? "Weekly included usage" : "Monthly included usage",
                used: percent!, limit: 100, resetsAt: end,
                projectionCurrent: percent!, projectionLimit: 100,
                projectionPeriodStart: start, projectionPeriodEnd: end
            )
        } else {
            nil
        }
        let reason = unavailableReason(config, supportedPeriod: supportedPeriod, activePeriod: activePeriod)
        let balance = money(config.prepaidBalance, kind: .balance, label: "Extra Usage Credits")
        let spent = money(config.onDemandUsed, kind: .spent, label: "On-demand spending")
        let cap = money(config.onDemandCap, kind: .spendLimit, label: "On-demand cap")
        let products = (config.productUsage ?? []).compactMap(productInformation)
        let cacheIdentity = Data(SHA256.hash(data: Data(subject.utf8))).base64EncodedString()
        return ProviderUsageResult(
            accountID: configuration.id, providerID: .grok, title: configuration.displayName,
            subtitle: bar == nil ? reason : "Grok consumer usage",
            bars: bar.map { [$0] } ?? [],
            monetaryMetrics: [balance, spent, cap].compactMap { $0 },
            usageMessages: bar == nil ? [reason] : [],
            cardInformationSections: products.isEmpty ? [] : [
                ProviderCardInformationSection(id: "grok.products", title: "Usage breakdown", items: products),
            ],
            cacheIdentity: cacheIdentity, cacheScope: "consumer.\(cacheIdentity)", fetchedAt: now
        )
    }

    private static func unavailableReason(
        _ config: GrokCreditsConfig, supportedPeriod: Bool, activePeriod: Bool
    ) -> String {
        if config.isUnifiedBillingUser == false { return "No shared paid allowance was reported." }
        if !supportedPeriod { return "Grok did not report a supported usage period." }
        if !activePeriod { return "Grok did not report an active usage period." }
        return "Grok did not report included usage."
    }

    private static func productInformation(_ product: GrokProductUsage) -> ProviderCardInformationItem? {
        guard let name = product.product?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let value = product.usagePercent, value.isFinite, value >= 0 else { return nil }
        return ProviderCardInformationItem(id: "grok.product.\(name)", label: name, detail: "\(value.formatted())%")
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func money(
        _ amount: GrokCreditsAmount?, kind: ProviderMonetaryMetricKind, label: String
    ) -> ProviderMonetaryMetric? {
        guard let cents = amount?.val, cents >= 0 else { return nil }
        return ProviderMonetaryMetric(kind: kind, label: label, minorUnits: cents, currencyCode: "USD", decimalPlaces: 2)
    }
}

private struct GrokRenewalError: Decodable {
    let error: String
}

private struct GrokCreditsResponse: Decodable {
    let config: GrokCreditsConfig?
}

private struct GrokCreditsConfig: Decodable {
    let creditUsagePercent: Double?
    let currentPeriod: GrokCreditsPeriod?
    let isUnifiedBillingUser: Bool?
    let prepaidBalance: GrokCreditsAmount?
    let onDemandUsed: GrokCreditsAmount?
    let onDemandCap: GrokCreditsAmount?
    let productUsage: [GrokProductUsage]?
}

private struct GrokCreditsPeriod: Decodable {
    let type: String?
    let start: String?
    let end: String?
}

private struct GrokCreditsAmount: Decodable {
    let val: Decimal?
}

private struct GrokProductUsage: Decodable {
    let product: String?
    let usagePercent: Double?
}
