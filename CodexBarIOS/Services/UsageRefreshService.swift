import Foundation

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefreshError: String?

    private let providers: [any UsageProvider]

    public init(
        providers: [any UsageProvider],
        initialResults: [ProviderUsageResult] = []
    ) {
        self.providers = providers
        self.results = initialResults
    }

    public func refresh(configurations: [ProviderAccountConfiguration]) async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        do {
            var nextResults: [ProviderUsageResult] = []
            for configuration in configurations where configuration.isEnabled {
                guard let provider = providers.first(where: { $0.providerID == configuration.providerID }) else {
                    continue
                }
                nextResults.append(try await provider.fetchUsage(for: configuration))
            }

            results = nextResults.sorted { $0.title < $1.title }
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    @discardableResult
    public func refresh(configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        guard
            configuration.isEnabled,
            let provider = providers.first(where: { $0.providerID == configuration.providerID })
        else {
            return nil
        }

        do {
            let result = try await provider.fetchUsage(for: configuration)
            replaceResult(result)
            lastRefreshError = nil
            return result
        } catch {
            lastRefreshError = error.localizedDescription
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
