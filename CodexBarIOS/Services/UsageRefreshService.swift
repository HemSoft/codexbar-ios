import Foundation

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
            refreshErrorsByAccountID[result.accountID] == nil
                && !refreshingAccountIDs.contains(result.accountID)
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

    public func refresh(configurations: [ProviderAccountConfiguration]) async {
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
            .first(where: refreshingAccountIDs.contains)
        {
            await waitForRefreshToFinish(accountID: refreshingAccountID)
        }

        let enabledAccountIDs = Set(enabledConfigurations.map(\.id))
        results.removeAll { !enabledAccountIDs.contains($0.accountID) }
        refreshErrorsByAccountID = refreshErrorsByAccountID.filter { enabledAccountIDs.contains($0.key) }
        lastRefreshError = nil

        var requests: [(ProviderAccountConfiguration, any UsageProvider)] = []
        var errorsByAccountID: [String: String] = [:]
        for configuration in enabledConfigurations {
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
                group.addTask {
                    do {
                        let result = try await provider.fetchUsage(for: configuration)
                        if let message = result.failureMessage {
                            return .failure(
                                accountID: configuration.id,
                                message: message,
                                result: result
                            )
                        }
                        return .success(
                            accountID: configuration.id,
                            result: result
                        )
                    } catch {
                        let result = Self.failureResult(
                            for: configuration,
                            message: error.localizedDescription
                        )
                        return .failure(
                            accountID: configuration.id,
                            message: error.localizedDescription,
                            result: result
                        )
                    }
                }
            }

            for await outcome in group {
                switch outcome {
                case .success(let accountID, let result):
                    replaceResult(result)
                    refreshErrorsByAccountID.removeValue(forKey: accountID)
                    finishRefresh(accountID: accountID)
                case .failure(let accountID, let message, let result):
                    preserveFailureResult(result, accountID: accountID)
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
        await waitForRefreshToFinish(accountID: configuration.id)

        refreshingAccountIDs.insert(configuration.id)
        refreshErrorsByAccountID.removeValue(forKey: configuration.id)
        lastRefreshError = nil
        defer {
            finishRefresh(accountID: configuration.id)
        }

        do {
            let result = try await provider.fetchUsage(for: configuration)
            if let message = result.failureMessage {
                preserveFailureResult(result, accountID: configuration.id)
                refreshErrorsByAccountID[configuration.id] = message
                lastRefreshError = message
                return result
            }
            replaceResult(result)
            refreshErrorsByAccountID.removeValue(forKey: configuration.id)
            lastRefreshError = nil
            return result
        } catch {
            let message = error.localizedDescription
            let result = Self.failureResult(for: configuration, message: message)
            preserveFailureResult(result, accountID: configuration.id)
            refreshErrorsByAccountID[configuration.id] = message
            lastRefreshError = message
            return result
        }
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

    private func replaceResult(_ result: ProviderUsageResult) {
        var nextResults = results.filter { $0.accountID != result.accountID }
        nextResults.append(result)
        results = nextResults
    }

    private func preserveFailureResult(_ failureResult: ProviderUsageResult, accountID: String) {
        let cachedResult = results.first { $0.accountID == accountID }
        let failureHasUsageData = failureResult.creditsRemaining != nil
            || !failureResult.bars.isEmpty
            || !failureResult.monetaryMetrics.isEmpty
            || failureResult.codexBankedRateLimitResets != nil
        let dataResult: ProviderUsageResult
        if failureHasUsageData {
            dataResult = failureResult
        } else if let cachedResult {
            dataResult = cachedResult
        } else {
            replaceResult(failureResult)
            return
        }

        let subtitle = failureHasUsageData
            || failureResult.subtitle.localizedCaseInsensitiveContains("last known data")
            ? failureResult.subtitle
            : "\(failureResult.subtitle) Showing last known data."
        replaceResult(ProviderUsageResult(
            accountID: accountID,
            providerID: failureResult.providerID,
            title: failureResult.title,
            subtitle: subtitle,
            bars: dataResult.bars,
            barsFetchedAt: dataResult.barsFetchedAt,
            creditsRemaining: dataResult.creditsRemaining,
            monetaryMetrics: dataResult.monetaryMetrics,
            usageMessages: dataResult.usageMessages,
            codexBankedRateLimitResets: dataResult.codexBankedRateLimitResets,
            failureMessage: failureResult.failureMessage,
            fetchedAt: dataResult.fetchedAt
        ))
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

    private func finishRefresh(accountID: String) {
        refreshingAccountIDs.remove(accountID)
        let waiters = refreshCompletionWaiters.removeValue(forKey: accountID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct CodexResetAttempt {
    let idempotencyKey: String
    let creditID: String?
}

private enum AccountRefreshOutcome: Sendable {
    case success(accountID: String, result: ProviderUsageResult)
    case failure(accountID: String, message: String, result: ProviderUsageResult)
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
            ]
        )
    }
}
