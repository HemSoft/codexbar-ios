#if DEBUG
import Foundation
import SwiftUI

/// An explicit simulator-only launch contract. Never accepts a production defaults domain.
@MainActor
final class UITestFixtures {
    static let current: UITestFixtures? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODEXBAR_UI_TESTS"] == "1" else { return nil }
        #if targetEnvironment(simulator)
        guard let rawID = environment["CODEXBAR_UI_TEST_RUN_ID"],
              let runID = UUID(uuidString: rawID) else {
            preconditionFailure("UI tests require a UUID storage namespace")
        }
        return UITestFixtures(runID: runID, environment: environment)
        #else
        preconditionFailure("UI fixtures are available only on simulators")
        #endif
    }()

    let defaults: UserDefaults
    let configurationStore: ProviderConfigurationStore
    let refreshService: UsageRefreshService
    let historyStore: UsageHistoryStore
    let notifier = UITestNotifier()
    let statusPreferences: GitHubStatusPreferences
    let statusMonitor: GitHubStatusMonitor
    let appUpdateController: AppUpdateController

    private init(runID: UUID, environment: [String: String]) {
        let suite = "com.hemsoft.CodexBarIOS.ui-tests.\(runID.uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Cannot create UI test storage")
        }
        if environment["CODEXBAR_UI_TEST_RESET"] == "1" {
            defaults.removePersistentDomain(forName: suite)
        }
        self.defaults = defaults
        URLProtocol.registerClass(UITestNetworkBlocker.self)
        configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: UITestSecretStore(suite: suite),
            widgetSnapshotDefaults: defaults
        )
        historyStore = UsageHistoryStore(defaults: defaults)
        statusPreferences = GitHubStatusPreferences(defaults: defaults)
        statusMonitor = GitHubStatusMonitor(preferences: statusPreferences, notifier: notifier)
        appUpdateController = AppUpdateController(defaults: defaults)

        let recovery = environment["CODEXBAR_UI_TEST_SCENARIO"] == "recovery"
        if recovery && configurationStore.configurations.isEmpty {
            Self.seedRecoveryAccount(in: configurationStore)
        }
        let results = configurationStore.configurations
            .filter(configurationStore.isConfigured)
            .map { Self.result(for: $0, balance: 25) }
        refreshService = UsageRefreshService(
            providers: [UITestUsageProvider(failsFirstRefresh: recovery)],
            initialResults: results
        )
        if recovery && historyStore.snapshots.isEmpty {
            seedHistory()
        }
    }

    func contentView() -> some View {
        ContentView(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            appUpdateController: appUpdateController,
            githubStatusPreferences: statusPreferences,
            githubStatusMonitor: statusMonitor,
            usageAlertNotifier: notifier,
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            performsLifecycleWork: false,
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: refreshService,
                configurationStore: configurationStore,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: refreshService,
                configurationStore: configurationStore,
                sender: UITestWatchSender(),
                publishSnapshot: { _, _, _ in }
            )
        )
        .dynamicTypeSize(.accessibility2)
    }

    private static func seedRecoveryAccount(in configurationStore: ProviderConfigurationStore) {
        let group = configurationStore.addGroup(named: "Fixture Team")
        let account = ProviderAccountConfiguration(
            id: "ui-recovery-account",
            providerID: .openRouter,
            accountLabel: "Recovery Account",
            groupID: group?.id,
            authMethod: .apiKey
        )
        _ = configurationStore.update(account)
        _ = configurationStore.saveSecret("ui-test-credential", for: account)
    }

    private func seedHistory() {
        let now = Date()
        for hoursAgo in [48.0, 1.0, 0.0] {
            let results = configurationStore.configurations.map {
                Self.result(for: $0, balance: 25, fetchedAt: now.addingTimeInterval(-hoursAgo * 3_600))
            }
            historyStore.record(results: results, now: now)
        }
    }

    nonisolated static func result(
        for configuration: ProviderAccountConfiguration,
        balance: Double,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: configuration.displayName,
            subtitle: "Synthetic UI test balance",
            bars: [],
            creditsRemaining: balance,
            fetchedAt: fetchedAt
        )
    }
}

private struct UITestSecretStore: SecretStore {
    let suite: String

    func readSecret(account: String) throws -> String? {
        UserDefaults(suiteName: suite)?.string(forKey: "fixture-secret.\(account)")
    }

    func saveSecret(_ secret: String, account: String) throws {
        guard secret == "ui-test-credential" else { throw UITestFixtureError.invalidCredential }
        UserDefaults(suiteName: suite)?.set(secret, forKey: "fixture-secret.\(account)")
    }

    func deleteSecret(account: String) throws {
        UserDefaults(suiteName: suite)?.removeObject(forKey: "fixture-secret.\(account)")
    }
}

private actor UITestUsageProvider: UsageProvider {
    nonisolated let providerID = ProviderID.openRouter
    private var failsNextRefresh: Bool

    init(failsFirstRefresh: Bool) {
        failsNextRefresh = failsFirstRefresh
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if failsNextRefresh {
            failsNextRefresh = false
            throw UITestFixtureError.refreshFailed
        }
        return UITestFixtures.result(for: configuration, balance: 60)
    }
}

private enum UITestFixtureError: LocalizedError {
    case invalidCredential
    case refreshFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Only the synthetic UI test credential is accepted."
        case .refreshFailed: "Fixture refresh failed. Retry to recover."
        }
    }
}

@MainActor
final class UITestNotifier: UsageAlertNotifying, GitHubStatusNotifying {
    func requestAuthorization() async -> Bool { false }
    func deliver(_ notification: UsageAlertNotification) async throws {}
    func deliverGitHubStatus(_ notification: GitHubStatusNotification) async throws {}
}

@MainActor
private final class UITestWatchSender: WatchSnapshotSending {
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { false }
}

/// Defense in depth: unexpected URLSession traffic must never reach a provider.
private final class UITestNetworkBlocker: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
#endif
