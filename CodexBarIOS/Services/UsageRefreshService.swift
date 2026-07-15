import Foundation

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var refreshingAccountIDs: Set<String> = []
    @Published public private(set) var refreshErrorsByAccountID: [String: String] = [:]
    @Published public private(set) var lastRefreshError: String?

    private let providers: [any UsageProvider]

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

    public func refresh(configurations: [ProviderAccountConfiguration]) async {
        guard !isRefreshing else {
            return
        }

        let enabledConfigurations = configurations.filter(\.isEnabled)
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
                        return .success(
                            accountID: configuration.id,
                            result: try await provider.fetchUsage(for: configuration)
                        )
                    } catch {
                        return .failure(
                            accountID: configuration.id,
                            message: error.localizedDescription
                        )
                    }
                }
            }

            for await outcome in group {
                switch outcome {
                case .success(let accountID, let result):
                    replaceResult(result)
                    refreshErrorsByAccountID.removeValue(forKey: accountID)
                    refreshingAccountIDs.remove(accountID)
                case .failure(let accountID, let message):
                    refreshErrorsByAccountID[accountID] = message
                    errorsByAccountID[accountID] = message
                    refreshingAccountIDs.remove(accountID)
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
        guard !refreshingAccountIDs.contains(configuration.id) else {
            return results.first { $0.accountID == configuration.id }
        }

        refreshingAccountIDs.insert(configuration.id)
        refreshErrorsByAccountID.removeValue(forKey: configuration.id)
        lastRefreshError = nil
        defer {
            refreshingAccountIDs.remove(configuration.id)
        }

        do {
            let result = try await provider.fetchUsage(for: configuration)
            replaceResult(result)
            refreshErrorsByAccountID.removeValue(forKey: configuration.id)
            lastRefreshError = nil
            return result
        } catch {
            let message = error.localizedDescription
            refreshErrorsByAccountID[configuration.id] = message
            lastRefreshError = message
            return nil
        }
    }

    public func refresh() async {
        await refresh(configurations: ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration))
    }

    private func replaceResult(_ result: ProviderUsageResult) {
        var nextResults = results.filter { $0.accountID != result.accountID }
        nextResults.append(result)
        results = nextResults.sorted { $0.title < $1.title }
    }
}

private enum AccountRefreshOutcome: Sendable {
    case success(accountID: String, result: ProviderUsageResult)
    case failure(accountID: String, message: String)
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
                CursorUsageProvider(),
            ]
        )
    }
}
