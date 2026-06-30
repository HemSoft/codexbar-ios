import Foundation

@MainActor
public final class UsageRefreshService: ObservableObject {
    @Published public private(set) var results: [ProviderUsageResult] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefreshError: String?

    private let providers: [any UsageProvider]

    public init(providers: [any UsageProvider]) {
        self.providers = providers
    }

    public func refresh() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        do {
            var nextResults: [ProviderUsageResult] = []
            for provider in providers {
                nextResults.append(try await provider.fetchUsage())
            }

            results = nextResults.sorted { $0.title < $1.title }
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
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
                DemoUsageProvider.samples.first { $0.providerID == .copilot }!,
                DemoUsageProvider.samples.first { $0.providerID == .openRouter }!,
            ]
        )
    }
}
