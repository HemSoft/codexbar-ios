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

    private lazy var widgetSnapshotCoordinator = WidgetSnapshotCoordinator(
        refreshService: refreshService,
        configurationStore: configurationStore,
        publishSnapshot: { _, _ in },
        publishSettings: { _ in }
    )
    private lazy var watchSnapshotCoordinator = WatchSnapshotCoordinator(
        refreshService: refreshService,
        configurationStore: configurationStore,
        sender: UITestWatchSender(),
        publishSnapshot: { _, _, _ in }
    )

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

        let scenario = environment["CODEXBAR_UI_TEST_SCENARIO"]
        let recovery = scenario == "recovery"
        let google = ["google-six", "google-antigravity", "google-apps-only"].contains(scenario)
        if google && configurationStore.configurations.isEmpty {
            Self.seedGoogleAccounts(in: configurationStore, scenario: scenario)
        }
        if recovery && configurationStore.configurations.isEmpty {
            Self.seedRecoveryAccount(in: configurationStore)
        }
        let results = configurationStore.configurations
            .filter(configurationStore.isConfigured)
            .map { configuration in
                google ? Self.googleResult(for: configuration, stage: 0)
                    : Self.result(for: configuration, balance: configuration.id.hasPrefix("ui-navigation-") ? 90 : 25)
            }
        refreshService = UsageRefreshService(
            providers: google
                ? [UITestGoogleProvider(providerID: .gemini), UITestGoogleProvider(providerID: .antigravity)]
                : [UITestUsageProvider(failsFirstRefresh: recovery)],
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
            widgetSnapshotCoordinator: widgetSnapshotCoordinator,
            watchSnapshotCoordinator: watchSnapshotCoordinator
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
        // Place a distinct URL destination beyond the viewport on either device family.
        for index in 1...5 {
            let navigationAccount = ProviderAccountConfiguration(
                id: "ui-navigation-\(index)",
                providerID: .openRouter,
                accountLabel: index == 5 ? "Target Account" : "Scroll Account \(index)",
                groupID: group?.id,
                authMethod: .apiKey
            )
            _ = configurationStore.update(navigationAccount)
            _ = configurationStore.saveSecret("ui-test-credential", for: navigationAccount)
        }
    }

    private static func seedGoogleAccounts(in store: ProviderConfigurationStore, scenario: String?) {
        let sources: [ProviderID] = scenario == "google-apps-only" ? [.gemini]
            : (scenario == "google-six" ? [.gemini, .antigravity] : [.antigravity])
        for source in sources {
            let account = ProviderAccountConfiguration(
                id: "ui-google-\(source.rawValue)",
                providerID: source,
                accountLabel: source == .gemini ? "Apps Fixture" : "Coding Fixture",
                authMethod: source == .gemini ? .browserSession : .cliToken
            )
            _ = store.update(account)
            _ = store.saveSecret("ui-test-credential", for: account)
        }
    }

    nonisolated static func googleResult(for account: ProviderAccountConfiguration, stage: Int) -> ProviderUsageResult {
        let definitions = GoogleUsageMetricCatalog.definitions(for: account.providerID)
        let used: [String: Double] = account.providerID == .gemini ? ["five-hour": 12, "weekly": 45] : [
            "gemini-5h": stage >= 3 ? 100 : 0, "gemini-weekly": 31,
            "3p-5h": stage >= 3 ? 20 : 0, "3p-weekly": stage >= 3 ? 60 : 0,
        ]
        let unavailable = account.providerID == .antigravity && stage == 1 ? [
            "gemini-weekly": "Unavailable", "3p-5h": GoogleUsageMetricCatalog.disabledReason,
        ] : [:]
        let bars = definitions.compactMap { definition -> UsageBar? in
            guard unavailable[definition.key] == nil, let value = used[definition.key] else { return nil }
            return UsageBar(
                stableKey: definition.key, label: definition.label, used: value, limit: 100,
                resetsAt: Date().addingTimeInterval(definition.window == "5h" ? 18_000 : 604_800),
                resetDisplayStyle: .relativeWithLocalTime
            )
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: account.providerID, title: account.displayName,
            subtitle: account.providerID == .gemini ? "Gemini Apps usage" : "Antigravity quota groups",
            bars: bars,
            unavailableUsageMetrics: Dictionary(uniqueKeysWithValues: unavailable.map {
                ("\(account.providerID.rawValue).\($0.key)", $0.value)
            }),
            fetchedAt: Date()
        )
    }

    private func seedHistory() {
        let now = Date()
        for hoursAgo in [48.0, 1.0, 0.0] {
            let results = configurationStore.configurations.map {
                Self.result(
                    for: $0,
                    balance: $0.id.hasPrefix("ui-navigation-") ? 90 : 25,
                    fetchedAt: now.addingTimeInterval(-hoursAgo * 3_600)
                )
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
        if configuration.id.hasPrefix("ui-navigation-") {
            return UITestFixtures.result(for: configuration, balance: 90)
        }
        if failsNextRefresh && configuration.id == "ui-recovery-account" {
            failsNextRefresh = false
            throw UITestFixtureError.refreshFailed
        }
        return UITestFixtures.result(for: configuration, balance: 60)
    }
}

private actor UITestGoogleProvider: UsageProvider {
    nonisolated let providerID: ProviderID
    private var stage = 0

    init(providerID: ProviderID) { self.providerID = providerID }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        stage += 1
        if stage == 2 && providerID == .antigravity { throw UITestFixtureError.refreshFailed }
        return UITestFixtures.googleResult(for: configuration, stage: stage)
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
