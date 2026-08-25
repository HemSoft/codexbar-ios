import Foundation

struct CodexRetainedResetAttempt: Equatable, Sendable {
    let creditID: String?
}

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var refreshingAccountIDs: Set<String> = []
    @Published public private(set) var refreshErrorsByAccountID: [String: String] = [:]
    @Published public private(set) var lastRefreshError: String?

    private let providers: [any UsageProvider]
    private var refreshCompletionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var isBatchRefreshRunning = false
    private var pendingBatchConfigurations: [ProviderAccountConfiguration]?
    private var batchRefreshCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasCurrentConfigurationSnapshot = false
    private var currentConfigurationsByAccountID: [String: ProviderAccountConfiguration] = [:]
    private var refreshGenerationsByAccountID: [String: UUID] = [:]
    private var codexResetAttempts: [String: CodexResetAttempt] = [:]
    private var codexResetTasks: [String: Task<CodexBankedResetConsumptionOutcome, Error>] = [:]

    public init(
        providers: [any UsageProvider],
        initialResults: [ProviderUsageResult] = []
    ) {
        self.providers = providers
        self.results = initialResults
    }

    public var isRefreshing: Bool {
        !refreshingAccountIDs.isEmpty
    }

    public var successfulRefreshResults: [ProviderUsageResult] {
        results.filter { result in
            guard !refreshingAccountIDs.contains(result.accountID) else {
                return false
            }
            return refreshErrorsByAccountID[result.accountID] == nil
                || result.preserveCachedBarsOnFailure
                || result.preserveCachedCreditsOnFailure
        }
    }

    public var incompleteRefreshAccountIDs: Set<String> {
        Set(refreshErrorsByAccountID.keys).union(refreshingAccountIDs)
    }

    var queuedBatchRefreshCount: Int {
        batchRefreshCompletionWaiters.count
    }

    func refreshWaiterCount(for accountID: String) -> Int {
        refreshCompletionWaiters[accountID]?.count ?? 0
    }

    var trackedRefreshGenerationCount: Int {
        refreshGenerationsByAccountID.count
    }

    func hasSameRefreshInputs(
        _ first: ProviderAccountConfiguration,
        _ second: ProviderAccountConfiguration
    ) -> Bool {
        RefreshInputs(configuration: first) == RefreshInputs(configuration: second)
    }

    public func refresh(configurations: [ProviderAccountConfiguration]) async {
        updateCurrentConfigurations(configurations)
        if isBatchRefreshRunning {
            pendingBatchConfigurations = configurations
            await withCheckedContinuation { continuation in
                batchRefreshCompletionWaiters.append(continuation)
            }
            return
        }

        isBatchRefreshRunning = true
        var nextConfigurations = configurations
        while true {
            await performRefresh(configurations: nextConfigurations)
            guard let pendingConfigurations = pendingBatchConfigurations else {
                break
            }
            pendingBatchConfigurations = nil
            nextConfigurations = pendingConfigurations
        }

        isBatchRefreshRunning = false
        let waiters = batchRefreshCompletionWaiters
        batchRefreshCompletionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func performRefresh(configurations: [ProviderAccountConfiguration]) async {
        let enabledConfigurations = configurations.filter(\.isEnabled)
        while let refreshingAccountID = enabledConfigurations.lazy
            .map(\.id)
            .first(where: refreshingAccountIDs.contains) {
            await waitForRefreshToFinish(accountID: refreshingAccountID)
        }

        let enabledAccountIDs = Set(enabledConfigurations.map(\.id))
        pruneCachedState(to: enabledAccountIDs)
        lastRefreshError = nil

        var requests: [(ProviderAccountConfiguration, any UsageProvider)] = []
        var errorsByAccountID: [String: String] = [:]
        for configuration in enabledConfigurations {
            guard isCurrent(configuration) else {
                continue
            }
            guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
                let message = "This provider is unavailable."
                refreshErrorsByAccountID[configuration.id] = message
                errorsByAccountID[configuration.id] = message
                continue
            }
            requests.append((configuration, provider))
        }

        let requestedAccountIDs = Set(requests.map { $0.0.id })
        refreshingAccountIDs.formUnion(requestedAccountIDs)
        for accountID in requestedAccountIDs {
            refreshErrorsByAccountID.removeValue(forKey: accountID)
        }

        await withTaskGroup(of: AccountRefreshOutcome.self) { group in
            for (configuration, provider) in requests {
                guard let generation = refreshGenerationsByAccountID[configuration.id] else {
                    finishRefresh(accountID: configuration.id)
                    continue
                }
                group.addTask {
                    do {
                        let result = try await provider.fetchUsage(for: configuration)
                        if let message = result.failureMessage {
                            return .failure(
                                configuration: configuration,
                                generation: generation,
                                message: message,
                                result: result
                            )
                        }
                        return .success(
                            configuration: configuration,
                            generation: generation,
                            result: result
                        )
                    } catch {
                        let result = Self.failureResult(
                            for: configuration,
                            message: error.localizedDescription
                        )
                        return .failure(
                            configuration: configuration,
                            generation: generation,
                            message: error.localizedDescription,
                            result: result
                        )
                    }
                }
            }

            for await outcome in group {
                switch outcome {
                case .success(let configuration, let generation, let result):
                    let accountID = configuration.id
                    guard isCurrent(configuration, generation: generation) else {
                        finishRefresh(accountID: accountID)
                        continue
                    }
                    replaceResult(result)
                    refreshErrorsByAccountID.removeValue(forKey: accountID)
                    finishRefresh(accountID: accountID)
                case .failure(let configuration, let generation, let message, let result):
                    let accountID = configuration.id
                    guard isCurrent(configuration, generation: generation) else {
                        finishRefresh(accountID: accountID)
                        continue
                    }
                    preserveFailureResult(result, configuration: configuration)
                    refreshErrorsByAccountID[accountID] = message
                    errorsByAccountID[accountID] = message
                    finishRefresh(accountID: accountID)
                }
            }
        }

        lastRefreshError = enabledConfigurations.lazy
            .compactMap { errorsByAccountID[$0.id] }
            .first
    }

    @discardableResult
    public func refresh(configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard
            configuration.isEnabled,
            let provider = providers.first(where: { $0.providerID == configuration.providerID })
        else {
            return nil
        }
        let generation: UUID
        if hasCurrentConfigurationSnapshot {
            guard
                isCurrent(configuration),
                let currentGeneration = refreshGenerationsByAccountID[configuration.id]
            else {
                return nil
            }
            generation = currentGeneration
        } else {
            generation = registerCurrentConfiguration(configuration)
        }
        await waitForRefreshToFinish(accountID: configuration.id)
        guard isCurrent(configuration, generation: generation) else {
            return nil
        }

        refreshingAccountIDs.insert(configuration.id)
        refreshErrorsByAccountID.removeValue(forKey: configuration.id)
        lastRefreshError = nil
        defer {
            finishRefresh(accountID: configuration.id)
        }

        do {
            let result = try await provider.fetchUsage(for: configuration)
            guard isCurrent(configuration, generation: generation) else {
                return nil
            }
            if let message = result.failureMessage {
                preserveFailureResult(result, configuration: configuration)
                refreshErrorsByAccountID[configuration.id] = message
                lastRefreshError = message
                return result
            }
            replaceResult(result)
            refreshErrorsByAccountID.removeValue(forKey: configuration.id)
            lastRefreshError = nil
            return result
        } catch {
            guard isCurrent(configuration, generation: generation) else {
                return nil
            }
            let message = error.localizedDescription
            let result = Self.failureResult(for: configuration, message: message)
            preserveFailureResult(result, configuration: configuration)
            refreshErrorsByAccountID[configuration.id] = message
            lastRefreshError = message
            return result
        }
    }

    func resultAfterCurrentRefresh(
        configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult? {
        guard
            isCurrent(configuration),
            let generation = refreshGenerationsByAccountID[configuration.id]
        else {
            return nil
        }
        await waitForRefreshToFinish(accountID: configuration.id)
        guard isCurrent(configuration, generation: generation) else {
            return nil
        }
        return results.first { $0.accountID == configuration.id }
    }

    public func refresh() async {
        await refresh(configurations: ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration))
    }

    public func consumeCodexBankedReset(
        for configuration: ProviderAccountConfiguration,
        creditID: String?
    ) async throws -> CodexBankedResetConsumptionOutcome {
        guard
            configuration.providerID == .codex,
            let provider = providers.first(where: { $0.providerID == .codex }) as? any CodexBankedResetConsuming
        else {
            throw CodexBankedResetConsumptionError.unsupported
        }

        if let activeTask = codexResetTasks[configuration.id] {
            return try await activeTask.value
        }

        let attempt = codexResetAttempts[configuration.id] ?? CodexResetAttempt(
            idempotencyKey: UUID().uuidString,
            creditID: creditID
        )
        codexResetAttempts[configuration.id] = attempt
        let task = Task {
            try await provider.consumeBankedReset(
                for: configuration,
                creditID: attempt.creditID,
                idempotencyKey: attempt.idempotencyKey
            )
        }
        codexResetTasks[configuration.id] = task

        do {
            let outcome = try await task.value
            codexResetTasks[configuration.id] = nil
            codexResetAttempts[configuration.id] = nil
            return outcome
        } catch {
            codexResetTasks[configuration.id] = nil
            if !shouldRetainCodexResetAttempt(after: error) {
                codexResetAttempts[configuration.id] = nil
            }
            throw error
        }
    }

    private func shouldRetainCodexResetAttempt(after error: Error) -> Bool {
        if let resetError = error as? CodexBankedResetConsumptionError {
            switch resetError {
            case .invalidResponse:
                return true
            case .httpStatus(let status):
                return status == 408 || status == 425 || status == 429 || (500..<600).contains(status)
            case .notConfigured, .credentialUnavailable, .unsupported, .invalidRequest:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL:
                return false
            default:
                return true
            }
        }

        return false
    }

    func hasRetainedCodexResetAttempt(for accountID: String) -> Bool {
        retainedCodexResetAttempt(for: accountID) != nil
    }

    func retainedCodexResetAttempt(for accountID: String) -> CodexRetainedResetAttempt? {
        guard let attempt = codexResetAttempts[accountID] else {
            return nil
        }
        return CodexRetainedResetAttempt(creditID: attempt.creditID)
    }

    private func replaceResult(_ result: ProviderUsageResult) {
        var nextResults = results.filter { $0.accountID != result.accountID }
        nextResults.append(result)
        results = nextResults
    }

    private func preserveFailureResult(
        _ failureResult: ProviderUsageResult,
        configuration: ProviderAccountConfiguration
    ) {
        let accountID = configuration.id
        let cachedResult = results.first {
            $0.accountID == accountID
                && Self.canReuseCachedResult($0, for: failureResult)
        }
        let failureHasUsageData = failureResult.creditsRemaining != nil
            || !failureResult.bars.isEmpty
            || !failureResult.monetaryMetrics.isEmpty
            || failureResult.codexBankedRateLimitResets != nil
            || failureResult.preserveCachedBarsOnFailure
            || failureResult.preserveCachedCreditsOnFailure
        let dataResult: ProviderUsageResult
        if failureHasUsageData {
            dataResult = failureResult
        } else if let cachedResult {
            dataResult = cachedResult
        } else {
            replaceResult(failureResult)
            return
        }

        let barsResult = failureResult.preserveCachedBarsOnFailure
            ? cachedResult ?? failureResult
            : dataResult
        let creditsResult = failureResult.preserveCachedCreditsOnFailure
            ? cachedResult ?? failureResult
            : dataResult
        let subtitle = failureHasUsageData
            || failureResult.subtitle.localizedCaseInsensitiveContains("last known data")
            ? failureResult.subtitle
            : "\(failureResult.subtitle) Showing last known data."
        let title = failureResult.providerID == .openCodeZen
            ? configuration.openCodeDisplayName(
                hasGoUsage: !barsResult.bars.isEmpty,
                hasZenBalance: creditsResult.creditsRemaining != nil
            )
            : failureResult.title
        replaceResult(ProviderUsageResult(
            accountID: accountID,
            providerID: failureResult.providerID,
            title: title,
            plan: failureResult.plan ?? cachedResult?.plan,
            subtitle: subtitle,
            bars: barsResult.bars,
            barsFetchedAt: barsResult.barsFetchedAt,
            creditsRemaining: creditsResult.creditsRemaining,
            creditsFetchedAt: creditsResult.creditsFetchedAt,
            monetaryMetrics: dataResult.monetaryMetrics,
            usageMessages: dataResult.usageMessages,
            dashboardUsageMessages: dataResult.dashboardUsageMessages,
            cardInformationSections: dataResult.cardInformationSections,
            codexBankedRateLimitResets: dataResult.codexBankedRateLimitResets,
            failureMessage: failureResult.failureMessage,
            recoveryAction: failureResult.recoveryAction,
            preserveCachedBarsOnFailure: failureResult.preserveCachedBarsOnFailure,
            preserveCachedCreditsOnFailure: failureResult.preserveCachedCreditsOnFailure,
            cacheIdentity: failureResult.cacheIdentity,
            cacheScope: failureResult.cacheScope,
            allowsUnscopedCacheReuse: failureResult.allowsUnscopedCacheReuse,
            hasSuccessfulRefreshHistory: failureResult.hasSuccessfulRefreshHistory
                || cachedResult?.hasSuccessfulRefreshHistory == true,
            fetchedAt: dataResult.fetchedAt
        ))
    }

    private nonisolated static func canReuseCachedResult(
        _ cachedResult: ProviderUsageResult,
        for failureResult: ProviderUsageResult
    ) -> Bool {
        guard failureResult.providerID == .openCodeZen else {
            return true
        }
        guard let failureIdentity = failureResult.cacheIdentity else {
            guard
                failureResult.allowsUnscopedCacheReuse,
                let failureScope = failureResult.cacheScope
            else {
                return false
            }
            return cachedResult.cacheScope == failureScope
        }
        return cachedResult.cacheIdentity == failureIdentity
    }

    private nonisolated static func failureResult(
        for configuration: ProviderAccountConfiguration,
        message: String
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: configuration.providerID,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            cacheScope: configuration.providerID == .openCodeZen
                ? OpenCodeZenUsageProvider.normalizedWorkspaceId(
                    from: configuration.openCodeWorkspaceId
                )
                : nil,
            allowsUnscopedCacheReuse: true,
            fetchedAt: Date()
        )
    }

    private func waitForRefreshToFinish(accountID: String) async {
        while refreshingAccountIDs.contains(accountID) {
            await withCheckedContinuation { continuation in
                refreshCompletionWaiters[accountID, default: []].append(continuation)
            }
        }
    }

    func updateCurrentConfigurations(
        _ configurations: [ProviderAccountConfiguration]
    ) {
        let hadCurrentConfigurationSnapshot = hasCurrentConfigurationSnapshot
        hasCurrentConfigurationSnapshot = true
        let enabledConfigurations = configurations.filter(\.isEnabled)
        let nextConfigurations = Dictionary(
            uniqueKeysWithValues: enabledConfigurations.map { ($0.id, $0) }
        )
        let accountIDs = Set(currentConfigurationsByAccountID.keys)
            .union(nextConfigurations.keys)
        var invalidatedAccountIDs: Set<String> = []
        for accountID in accountIDs {
            let currentConfiguration = currentConfigurationsByAccountID[accountID]
            let nextConfiguration = nextConfigurations[accountID]
            guard currentConfiguration != nextConfiguration else {
                continue
            }
            guard refreshInputsChanged(from: currentConfiguration, to: nextConfiguration) else {
                continue
            }
            invalidatedAccountIDs.insert(accountID)
            if nextConfiguration == nil,
               !refreshingAccountIDs.contains(accountID) {
                refreshGenerationsByAccountID.removeValue(forKey: accountID)
            } else {
                refreshGenerationsByAccountID[accountID] = UUID()
            }
        }
        currentConfigurationsByAccountID = nextConfigurations

        let enabledAccountIDs = Set(nextConfigurations.keys)
        let evictedAccountIDs = hadCurrentConfigurationSnapshot ? invalidatedAccountIDs : []
        pruneCachedState(to: enabledAccountIDs.subtracting(evictedAccountIDs))
        let nextLastRefreshError = enabledConfigurations.lazy
            .compactMap { self.refreshErrorsByAccountID[$0.id] }
            .first
        if nextLastRefreshError != lastRefreshError {
            lastRefreshError = nextLastRefreshError
        }
    }

    private func pruneCachedState(to enabledAccountIDs: Set<String>) {
        let nextResults = results.filter { enabledAccountIDs.contains($0.accountID) }
        if nextResults != results {
            results = nextResults
        }
        let nextErrors = refreshErrorsByAccountID.filter { enabledAccountIDs.contains($0.key) }
        if nextErrors != refreshErrorsByAccountID {
            refreshErrorsByAccountID = nextErrors
        }
    }

    private func refreshInputsChanged(
        from currentConfiguration: ProviderAccountConfiguration?,
        to nextConfiguration: ProviderAccountConfiguration?
    ) -> Bool {
        guard let currentConfiguration, let nextConfiguration else {
            return true
        }
        return !hasSameRefreshInputs(currentConfiguration, nextConfiguration)
    }

    private func registerCurrentConfiguration(
        _ configuration: ProviderAccountConfiguration
    ) -> UUID {
        if currentConfigurationsByAccountID[configuration.id] != configuration {
            currentConfigurationsByAccountID[configuration.id] = configuration
            refreshGenerationsByAccountID[configuration.id] = UUID()
        }
        let generation = refreshGenerationsByAccountID[configuration.id] ?? UUID()
        refreshGenerationsByAccountID[configuration.id] = generation
        return generation
    }

    private func isCurrent(_ configuration: ProviderAccountConfiguration) -> Bool {
        currentConfigurationsByAccountID[configuration.id] == configuration
    }

    private func isCurrent(
        _ configuration: ProviderAccountConfiguration,
        generation: UUID
    ) -> Bool {
        guard let currentConfiguration = currentConfigurationsByAccountID[configuration.id] else {
            return false
        }
        return !refreshInputsChanged(from: configuration, to: currentConfiguration)
            && refreshGenerationsByAccountID[configuration.id] == generation
    }

    private func finishRefresh(accountID: String) {
        refreshingAccountIDs.remove(accountID)
        if currentConfigurationsByAccountID[accountID] == nil {
            refreshGenerationsByAccountID.removeValue(forKey: accountID)
        }
        let waiters = refreshCompletionWaiters.removeValue(forKey: accountID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct RefreshInputs: Equatable {
    let providerID: ProviderID
    let authMethod: ProviderAuthMethod
    let oauthClientID: String?
    let copilotAccountScope: CopilotAccountScope
    let githubOrganization: String
    let githubEnterprise: String
    let copilotTotalAllotment: Double?
    let openCodeWorkspaceId: String

    init(configuration: ProviderAccountConfiguration) {
        self.providerID = configuration.providerID
        self.authMethod = configuration.authMethod
        self.oauthClientID = configuration.oauthClientID
        self.copilotAccountScope = configuration.copilotAccountScope
        self.githubOrganization = configuration.githubOrganization
        self.githubEnterprise = configuration.githubEnterprise
        self.copilotTotalAllotment = configuration.copilotTotalAllotment
        self.openCodeWorkspaceId = configuration.openCodeWorkspaceId
    }
}

private struct CodexResetAttempt {
    let idempotencyKey: String
    let creditID: String?
}

private enum AccountRefreshOutcome: Sendable {
    case success(
        configuration: ProviderAccountConfiguration,
        generation: UUID,
        result: ProviderUsageResult
    )
    case failure(
        configuration: ProviderAccountConfiguration,
        generation: UUID,
        message: String,
        result: ProviderUsageResult
    )
}

public extension UsageRefreshService {
    static func demo() -> UsageRefreshService {
        UsageRefreshService(providers: DemoUsageProvider.samples)
    }

    static func live() -> UsageRefreshService {
        UsageRefreshService(
            providers: [
                CodexUsageProvider(),
                CopilotUsageProvider(),
                ClaudeUsageProvider(),
                OpenRouterUsageProvider(),
                OpenCodeZenUsageProvider(),
                MoonshotUsageProvider(),
                CursorUsageProvider(),
                GreptileUsageProvider(),
            ]
        )
    }
}
