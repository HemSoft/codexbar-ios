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
        let githubBilling = scenario?.hasPrefix("github-billing") == true
        let googleSources = Self.googleSources(for: scenario)
        let google = !googleSources.isEmpty
        if google && configurationStore.configurations.isEmpty {
            Self.seedGoogleAccounts(in: configurationStore, sources: googleSources)
        }
        if recovery && configurationStore.configurations.isEmpty {
            Self.seedRecoveryAccount(in: configurationStore)
        }
        if githubBilling && configurationStore.configurations.isEmpty {
            Self.seedGitHubBillingAccounts(in: configurationStore, scenario: scenario)
        }
        let results = configurationStore.configurations
            .filter(configurationStore.isConfigured)
            .map { configuration in
                if google {
                    return Self.googleResult(for: configuration, sources: googleSources, stage: 0)
                }
                if githubBilling {
                    return Self.githubBillingResult(for: configuration)
                }
                return Self.result(
                    for: configuration,
                    balance: configuration.id.hasPrefix("ui-navigation-") ? 90 : 25
                )
            }
        let providers: [any UsageProvider]
        if google {
            providers = [UITestGoogleProvider(sources: googleSources)]
        } else if githubBilling {
            providers = [UITestGitHubBillingProvider()]
        } else {
            providers = [UITestUsageProvider(failsFirstRefresh: recovery)]
        }
        refreshService = UsageRefreshService(providers: providers, initialResults: results)
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

    private static func seedGitHubBillingAccounts(
        in store: ProviderConfigurationStore,
        scenario: String?
    ) {
        let group = store.addGroup(named: "GitHub Billing")
        let personalID = switch scenario {
        case "github-billing-no-personal-budget": "ui-github-billing-personal-no-budget"
        case "github-billing-incomplete": "ui-github-billing-personal-incomplete"
        default: "ui-github-billing-personal"
        }
        let personal = ProviderAccountConfiguration(
            id: personalID,
            providerID: .githubBilling,
            accountLabel: "Sample Personal",
            groupID: group?.id,
            authMethod: .browserSession,
            githubBillingAccountScope: .personal,
            githubBillingOwner: "sample-personal"
        )
        let organization = ProviderAccountConfiguration(
            id: "ui-github-billing-organization",
            providerID: .githubBilling,
            accountLabel: "Sample Organization",
            groupID: group?.id,
            authMethod: .browserSession,
            githubBillingAccountScope: .organization,
            githubBillingOwner: "sample-organization"
        )
        let accounts: [ProviderAccountConfiguration] = switch scenario {
        case "github-billing-personal",
             "github-billing-no-personal-budget",
             "github-billing-incomplete": [personal]
        case "github-billing-organization": [organization]
        default: [personal, organization]
        }
        for account in accounts {
            _ = store.update(account)
            _ = store.saveSecret("ui-test-credential", for: account)
        }
    }

    nonisolated static func githubBillingResult(
        for account: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        let periodStart = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        let periodEnd = periodStart.addingTimeInterval(30 * 24 * 60 * 60)
        if account.githubBillingAccountScope == .personal {
            if account.id.hasSuffix("no-budget") {
                return noBudgetPersonalBillingResult(account: account)
            }
            if account.id.hasSuffix("incomplete") {
                return incompletePersonalBillingResult(
                    account: account,
                    periodStart: periodStart,
                    periodEnd: periodEnd
                )
            }
            return healthyPersonalBillingResult(
                account: account,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
        }
        return organizationBillingResult(account: account, periodStart: periodStart, periodEnd: periodEnd)
    }

    nonisolated private static func noBudgetPersonalBillingResult(
        account: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
                    accountID: account.id,
                    providerID: .githubBilling,
                    title: account.displayName,
                    plan: ProviderPlanDescriptor.make(
                        providerPrefix: ProviderID.githubBilling.rawValue,
                        identifier: "free",
                        label: "Free"
                    ),
                    subtitle: "GitHub personal billing",
                    bars: [],
                    usageMessages: [],
                    cardInformationSections: [
                        ProviderCardInformationSection(
                            id: "github-billing.amounts-and-currency",
                            title: "Amounts and currency",
                            items: [
                                ProviderCardInformationItem(
                                    id: "currency",
                                    label: "Currency",
                                    detail: "USD. GitHub's billing API does not report a currency code, "
                                        + "so CodexBar shows the USD amounts GitHub lists. Amounts are not "
                                        + "converted to the device locale."
                                ),
                                ProviderCardInformationItem(
                                    id: "personal-budgets",
                                    label: "Personal budgets",
                                    detail: "GitHub does not expose personal budgets through its public API. "
                                        + "Included allowances and current charges are shown separately."
                                ),
                            ]
                        ),
                    ],
                    fetchedAt: Date()
                )
    }

    nonisolated private static func incompletePersonalBillingResult(
        account: ProviderAccountConfiguration,
        periodStart: Date,
        periodEnd: Date
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
                    accountID: account.id,
                    providerID: .githubBilling,
                    title: account.displayName,
                    plan: ProviderPlanDescriptor.make(
                        providerPrefix: ProviderID.githubBilling.rawValue,
                        identifier: "free",
                        label: "Free"
                    ),
                    subtitle: "GitHub personal billing",
                    bars: [
                        UsageBar(
                            stableKey: "actions-private-minutes",
                            label: "Private Actions minutes",
                            used: 720,
                            limit: 2_000,
                            resetsAt: periodEnd,
                            projectionCurrent: 720,
                            projectionLimit: 2_000,
                            projectionPeriodStart: periodStart,
                            projectionPeriodEnd: periodEnd,
                            showProjectionOnCurrentBar: true
                        ),
                    ],
                    monetaryMetrics: [
                        ProviderMonetaryMetric(
                            kind: .grossSpend, label: "Gross usage", minorUnits: 1_248,
                            currencyCode: "USD", decimalPlaces: 2
                        ),
                        ProviderMonetaryMetric(
                            kind: .discounts, label: "Discounts", minorUnits: 0,
                            currencyCode: "USD", decimalPlaces: 2
                        ),
                        ProviderMonetaryMetric(
                            kind: .spent,
                            label: "Net spend",
                            minorUnits: 1_248,
                            currencyCode: "USD",
                            decimalPlaces: 2,
                            detail: "Current metered charge"
                        ),
                    ],
                    usageMessages: [
                        "GitHub returned Actions or Packages storage without a recognized storage SKU, "
                            + "so the accrued storage allowance is unavailable.",
                    ],
                    cardInformationSections: [
                        ProviderCardInformationSection(
                            id: "github-billing.product.actions",
                            title: "Actions",
                            items: [
                                ProviderCardInformationItem(
                                    id: "consumed",
                                    label: "Consumed usage",
                                    detail: "$12.48 · 720 minutes"
                                ),
                                ProviderCardInformationItem(
                                    id: "discount",
                                    label: "Discount usage",
                                    detail: "$0.00"
                                ),
                                ProviderCardInformationItem(
                                    id: "billable",
                                    label: "Billable usage",
                                    detail: "$12.48"
                                ),
                                ProviderCardInformationItem(
                                    id: "included-minutes",
                                    label: "Included usage · Minutes",
                                    detail: "720 of 2,000 minutes used · 1,280 minutes remaining"
                                ),
                                ProviderCardInformationItem(
                                    id: "included-storage",
                                    label: "Included usage · Storage",
                                    detail: "GitHub returned Actions or Packages storage without a "
                                        + "recognized storage SKU, so the accrued storage allowance is unavailable."
                                ),
                            ]
                        ),
                    ],
                    fetchedAt: Date()
                )
    }

    nonisolated private static func healthyPersonalBillingResult(
        account: ProviderAccountConfiguration,
        periodStart: Date,
        periodEnd: Date
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
                accountID: account.id,
                providerID: .githubBilling,
                title: account.displayName,
                plan: ProviderPlanDescriptor.make(
                    providerPrefix: ProviderID.githubBilling.rawValue,
                    identifier: "free",
                    label: "Free"
                ),
                subtitle: "GitHub personal billing",
                bars: [
                    UsageBar(
                        stableKey: "actions-private-minutes",
                        label: "Private Actions minutes",
                        used: 720,
                        limit: 2_000,
                        resetsAt: periodEnd,
                        projectionCurrent: 720,
                        projectionLimit: 2_000,
                        projectionPeriodStart: periodStart,
                        projectionPeriodEnd: periodEnd,
                        showProjectionOnCurrentBar: true
                    ),
                    UsageBar(
                        stableKey: "actions-packages-storage",
                        label: "Actions + Packages storage",
                        used: 118,
                        limit: 360,
                        resetsAt: periodEnd
                    ),
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .grossSpend, label: "Gross usage", minorUnits: 2_520,
                        currencyCode: "USD", decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .discounts, label: "Discounts", minorUnits: 1_248,
                        currencyCode: "USD", decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .spent,
                        label: "Net spend",
                        minorUnits: 1_272,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Current metered charge"
                    ),
                ],
                usageMessages: [],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "github-billing.product.actions",
                        title: "Actions",
                        items: [
                            ProviderCardInformationItem(
                                id: "actions.consumed",
                                label: "Consumed usage",
                                detail: "$24.80 · 720 minutes · 118 GB-hours"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.discount",
                                label: "Discount usage",
                                detail: "$12.48"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.billable",
                                label: "Billable usage",
                                detail: "$12.32"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.included.minutes",
                                label: "Included usage · Minutes",
                                detail: "720 of 2,000 minutes used · 1,280 minutes remaining"
                            ),
                            ProviderCardInformationItem(
                                id: "actions.included.storage",
                                label: "Included usage · Storage",
                                detail: "118 of 360 GB-hours used (Actions and Packages storage) · "
                                    + "242 GB-hours remaining"
                            ),
                        ]
                    ),
                    ProviderCardInformationSection(
                        id: "github-billing.product.copilot",
                        title: "Copilot",
                        items: [
                            ProviderCardInformationItem(
                                id: "copilot.consumed",
                                label: "Consumed usage",
                                detail: "$0.40 · 40 requests"
                            ),
                            ProviderCardInformationItem(
                                id: "copilot.discount",
                                label: "Discount usage",
                                detail: "$0.00"
                            ),
                            ProviderCardInformationItem(
                                id: "copilot.billable",
                                label: "Billable usage",
                                detail: "$0.40"
                            ),
                        ]
                    ),
                    ProviderCardInformationSection(
                        id: "github-billing.amounts-and-currency",
                        title: "Amounts and currency",
                        items: [
                            ProviderCardInformationItem(
                                id: "currency",
                                label: "Currency",
                                detail: "USD. GitHub's billing API does not report a currency code, "
                                    + "so CodexBar shows the USD amounts GitHub lists. Amounts are not "
                                    + "converted to the device locale."
                            ),
                            ProviderCardInformationItem(
                                id: "personal-budgets",
                                label: "Personal budgets",
                                detail: "GitHub does not expose personal budgets through its public API. "
                                    + "Included allowances and current charges are shown separately."
                            ),
                        ]
                    ),
                ],
                fetchedAt: Date()
            )
    }

    nonisolated private static func organizationBillingResult(
        account: ProviderAccountConfiguration,
        periodStart: Date,
        periodEnd: Date
    ) -> ProviderUsageResult {
        return ProviderUsageResult(
            accountID: account.id,
            providerID: .githubBilling,
            title: account.displayName,
            subtitle: "GitHub organization billing",
            bars: [
                UsageBar(
                    stableKey: "budget-actions",
                    label: "Actions budget",
                    used: 62,
                    limit: 100,
                    resetsAt: periodEnd,
                    projectionCurrent: 62,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd,
                    showProjectionOnCurrentBar: true
                ),
            ],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .grossSpend, label: "Gross usage", minorUnits: 7_000,
                    currencyCode: "USD", decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .discounts, label: "Discounts", minorUnits: 800,
                    currencyCode: "USD", decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spent, label: "Net spend", minorUnits: 6_200,
                    currencyCode: "USD", decimalPlaces: 2
                ),
            ],
            cardInformationSections: [
                ProviderCardInformationSection(
                    id: "github-billing.budget.actions",
                    title: "Actions budget",
                    items: [
                        ProviderCardInformationItem(id: "scope", label: "Product budget", detail: "Actions"),
                        ProviderCardInformationItem(id: "behavior", label: "Behavior", detail: "Hard stop"),
                        ProviderCardInformationItem(id: "spend", label: "Current net spend", detail: "$62.00"),
                        ProviderCardInformationItem(
                            id: "remaining",
                            label: "Remaining headroom",
                            detail: "$38.00 · 62% consumed"
                        ),
                    ]
                ),
            ],
            fetchedAt: Date()
        )
    }

    private static func googleSources(for scenario: String?) -> [ProviderID] {
        switch scenario {
        case "google-six": [.gemini, .antigravity]
        case "google-coding-only": [.antigravity]
        case "google-apps-only": [.gemini]
        default: []
        }
    }

    nonisolated static let codingCredential: String = {
        do {
            return try AntigravityCredentials.parse(
                #"{"access_token":"ui-test-coding-token","expiry":"2030-01-01T00:00:00Z"}"#
            ).encoded()
        } catch {
            preconditionFailure("The fixed synthetic coding credential must be valid")
        }
    }()

    private static func seedGoogleAccounts(in store: ProviderConfigurationStore, sources: [ProviderID]) {
        let account = ProviderAccountConfiguration(
            id: "ui-google-gemini",
            providerID: .gemini,
            accountLabel: "Gemini Fixture",
            authMethod: .browserSession
        )
        _ = store.update(account)
        if sources.contains(.gemini) {
            _ = store.saveSecret("ui-test-credential", for: account)
        }
        if sources.contains(.antigravity) {
            _ = store.saveGeminiCodingSecret(codingCredential, for: account, confirmedSameAccount: true)
        }
    }

    nonisolated static func googleResult(
        for account: ProviderAccountConfiguration,
        sources: [ProviderID],
        stage: Int
    ) -> ProviderUsageResult {
        let definitions = GoogleUsageMetricCatalog.definitions(for: .gemini)
        let used: [String: Double] = [
            "five-hour": 12, "weekly": 45,
            "gemini-5h": stage >= 3 ? 100 : 0, "gemini-weekly": 31,
            "3p-5h": stage >= 3 ? 20 : 0, "3p-weekly": stage >= 3 ? 60 : 0,
        ]
        var unavailable: [String: String] = [:]
        for definition in definitions where !sources.contains(definition.sourceProviderID) {
            unavailable[definition.id] = "Setup required"
        }
        if sources.contains(.antigravity) && stage == 1 {
            unavailable["antigravity.gemini-weekly"] = "Unavailable"
            unavailable["antigravity.3p-5h"] = GoogleUsageMetricCatalog.disabledReason
        }
        let bars = definitions.compactMap { definition -> UsageBar? in
            guard unavailable[definition.id] == nil, let value = used[definition.key] else { return nil }
            return UsageBar(
                stableKey: definition.key, label: definition.label, used: value, limit: 100,
                resetsAt: Date().addingTimeInterval(definition.window == "5h" ? 18_000 : 604_800),
                resetDisplayStyle: .relativeWithLocalTime
            )
        }
        return ProviderUsageResult(
            accountID: account.id, providerID: .gemini, title: account.displayName,
            subtitle: "Gemini Apps and coding usage",
            bars: bars, unavailableUsageMetrics: unavailable, fetchedAt: Date()
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
        let coding = try? AntigravityCredentials.parse(secret)
        let expectedCoding = try AntigravityCredentials.parse(UITestFixtures.codingCredential)
        guard secret == "ui-test-credential" || coding == expectedCoding else {
            throw UITestFixtureError.invalidCredential
        }
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

private actor UITestGitHubBillingProvider: UsageProvider {
    nonisolated let providerID = ProviderID.githubBilling

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        UITestFixtures.githubBillingResult(for: configuration)
    }
}

private actor UITestGoogleProvider: UsageProvider {
    nonisolated let providerID = ProviderID.gemini
    private let sources: [ProviderID]
    private var stage = 0

    init(sources: [ProviderID]) { self.sources = sources }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        stage += 1
        if stage == 2 && sources == [.antigravity] { throw UITestFixtureError.refreshFailed }
        return UITestFixtures.googleResult(for: configuration, sources: sources, stage: stage)
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
