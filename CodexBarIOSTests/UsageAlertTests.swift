import XCTest
@testable import CodexBarIOS

final class UsageAlertTests: XCTestCase {
    @MainActor
    func testUsageAlertSettingsPersistAndClamp() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertFalse(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.usageThreshold, 0.80)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 5.00)

        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertUsageThreshold(1.8)
        store.updateUsageAlertBalanceThreshold(-5)
        store.updateUsageAlertIncludesSeverityAlerts(false)
        store.updateUsageAlertActiveIDs(["usage.codex.weekly", "balance.openRouter"])

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertTrue(reloadedStore.usageAlertSettings.isEnabled)
        XCTAssertEqual(reloadedStore.usageAlertSettings.usageThreshold, 1.0)
        XCTAssertEqual(reloadedStore.usageAlertSettings.balanceThreshold, 0)
        XCTAssertFalse(reloadedStore.usageAlertSettings.includesSeverityAlerts)
        XCTAssertEqual(reloadedStore.usageAlertActiveIDs, ["usage.codex.weekly", "balance.openRouter"])
    }

    @MainActor
    func testUsageAlertSettingsChangeClearsActiveSuppressionState() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        store.updateUsageAlertActiveIDs(["usage.codex.weekly"])
        store.updateUsageAlertUsageThreshold(0.90)

        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)
    }

    func testUsageAlertEvaluatorSendsOnceUntilRecovery() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 81,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.notifications.first?.title, "Codex 5-hour alert")
        XCTAssertEqual(first.notifications.first?.accountID, "codex.personal")
        XCTAssertEqual(first.notifications.first?.kind, .usage)
        XCTAssertEqual(first.notifications.first?.body, "5-hour at 81%. 81 of 100 used. Alert threshold: 80%.")
        XCTAssertEqual(first.activeAlerts.count, 1)
        XCTAssertEqual(first.activeAlerts.first?.accountID, "codex.personal")
        XCTAssertEqual(first.activeAlerts.first?.title, "5-hour at 81%")

        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.activeAlerts, first.activeAlerts)

        let recoveredResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 40,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let recovered = UsageAlertEvaluator.evaluate(
            results: [recoveredResult],
            settings: settings,
            activeAlertIDs: repeated.activeAlertIDs
        )
        XCTAssertTrue(recovered.activeAlertIDs.isEmpty)

        let crossedAgain = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: recovered.activeAlertIDs
        )
        XCTAssertEqual(crossedAgain.notifications.count, 1)
    }

    func testUsageAlertEvaluatorUsesInjectedNowForResetDescription() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = now.addingTimeInterval(2 * 60 * 60)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "5-hour",
                    used: 81,
                    limit: 100,
                    resetDescription: "stale reset text",
                    resetsAt: resetAt,
                    resetDisplayStyle: .relativeWithLocalTime
                ),
            ],
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        let body = try XCTUnwrap(evaluation.notifications.first?.body)
        XCTAssertTrue(body.contains("Resets 2h 0m"))
        XCTAssertFalse(body.contains("stale reset text"))
    }

    func testUsageAlertEvaluatorUsesStableUsageKeysForMutableLabels() {
        let firstResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    label: "On-demand $12.00 / $20.00",
                    used: 12,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let secondResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    label: "On-demand $14.00 / $20.00",
                    used: 14,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let settings = UsageAlertSettings(isEnabled: true, usageThreshold: 0.50)

        let first = UsageAlertEvaluator.evaluate(results: [firstResult], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [secondResult],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.activeAlertIDs, ["usage.cursor.main.on-demand"])
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorDeduplicatesBarsWithSameStableKey() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "On-demand $12.00 / $20.00", used: 12, limit: 20),
                UsageBar(label: "On-demand $18.00 / $30.00", used: 18, limit: 30),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.50,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorReportsBalanceThreshold() {
        let result = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(isEnabled: true, balanceThreshold: 5)

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "OpenRouter balance alert")
        XCTAssertEqual(evaluation.notifications.first?.accountID, "openRouter.main")
        XCTAssertEqual(evaluation.notifications.first?.kind, .balance)
        XCTAssertTrue(evaluation.activeAlertIDs.contains("balance.openRouter.main"))
        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Balance below $5.00")
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "$4.50 remaining for OpenRouter.")
    }

    func testUsageAlertEvaluatorAlertsScopedClaudeBarsWithoutTreatingHeadroomAsBalance() {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Fable weekly limit", used: 85, limit: 100),
            ],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 250,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.usage])
        XCTAssertEqual(evaluation.notifications.first?.title, "Claude Fable weekly limit alert")
        XCTAssertFalse(evaluation.activeAlertIDs.contains("balance.claude.personal"))

        let staleBarsResult = ProviderUsageResult(
            accountID: "claude.stale-bars",
            providerID: .claude,
            title: "Claude",
            subtitle: "Fresh monetary usage with cached rate limits",
            bars: [
                UsageBar(label: "Fable weekly limit", used: 85, limit: 100),
            ],
            barsFetchedAt: Date(timeIntervalSince1970: 1_783_667_520),
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let staleBarsEvaluation = UsageAlertEvaluator.evaluate(
            results: [staleBarsResult],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.80,
                includesSeverityAlerts: true
            ),
            activeAlertIDs: []
        )
        XCTAssertTrue(staleBarsEvaluation.notifications.isEmpty)
        XCTAssertTrue(staleBarsEvaluation.activeAlerts.isEmpty)

        let cappedResult = ProviderUsageResult(
            accountID: "claude.capped",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 5000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 5000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let cappedEvaluation = UsageAlertEvaluator.evaluate(
            results: [cappedResult],
            settings: UsageAlertSettings(isEnabled: true, includesSeverityAlerts: true),
            activeAlertIDs: []
        )
        XCTAssertEqual(cappedResult.highestSeverity, .critical)
        XCTAssertEqual(cappedEvaluation.notifications.map(\.kind), [.severity])
        XCTAssertEqual(
            cappedEvaluation.activeAlerts.first?.message,
            "The monthly usage-credit spend limit has been reached."
        )

        let zeroCapResult = ProviderUsageResult(
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 0,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 0,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        XCTAssertEqual(zeroCapResult.highestSeverity, .normal)
    }

    func testUsageAlertEvaluatorKeepsExistingAlertIDsWhileBarsAreStale() {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: true
        )
        let freshResult = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [UsageBar(label: "Fable weekly limit", used: 85, limit: 100)],
            fetchedAt: fetchedAt
        )
        let firstEvaluation = UsageAlertEvaluator.evaluate(
            results: [freshResult],
            settings: settings,
            activeAlertIDs: []
        )
        let staleResult = ProviderUsageResult(
            accountID: freshResult.accountID,
            providerID: freshResult.providerID,
            title: freshResult.title,
            subtitle: "Fresh monetary usage with cached rate limits",
            bars: freshResult.bars,
            barsFetchedAt: fetchedAt,
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )

        let repeatedEvaluation = UsageAlertEvaluator.evaluate(
            results: [staleResult],
            settings: settings,
            activeAlertIDs: firstEvaluation.activeAlertIDs
        )
        XCTAssertTrue(repeatedEvaluation.notifications.isEmpty)
        XCTAssertTrue(repeatedEvaluation.activeAlerts.isEmpty)
        XCTAssertEqual(repeatedEvaluation.activeAlertIDs, firstEvaluation.activeAlertIDs)

        let coldEvaluation = UsageAlertEvaluator.evaluate(
            results: [staleResult],
            settings: settings,
            activeAlertIDs: []
        )
        XCTAssertTrue(coldEvaluation.activeAlertIDs.isEmpty)
    }

    func testUsageAlertEvaluatorReturnsCardScopedActiveAlerts() {
        let codex = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Weekly", used: 90, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let cursor = ProviderUsageResult(
            accountID: "cursor.work",
            providerID: .cursor,
            title: "Cursor Work",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Included", used: 40, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let openRouter = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 2,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [codex, cursor, openRouter],
            settings: settings,
            activeAlertIDs: []
        )
        let activeAlertsByAccountID = Dictionary(grouping: evaluation.activeAlerts, by: \.accountID)

        XCTAssertEqual(Set(activeAlertsByAccountID.keys), ["codex.personal", "openRouter.main"])
        XCTAssertEqual(activeAlertsByAccountID["codex.personal"]?.map(\.kind), [.usage])
        XCTAssertEqual(activeAlertsByAccountID["openRouter.main"]?.map(\.kind), [.balance])
        XCTAssertNil(activeAlertsByAccountID["cursor.work"])
    }

    func testUsageAlertEvaluatorPreservesSuppressionForExactAccountsThatDidNotRefresh() {
        let activeAlertIDs: Set<String> = [
            "usage.codex.weekly",
            "usage.codex.secondary.weekly",
            "balance.openrouter.failed",
        ]

        let preserved = UsageAlertEvaluator.activeAlertIDs(
            activeAlertIDs,
            belongingTo: ["codex.secondary", "openrouter.failed"],
            knownAccountIDs: ["codex", "codex.secondary", "openrouter.failed"]
        )

        XCTAssertEqual(
            preserved,
            ["usage.codex.secondary.weekly", "balance.openrouter.failed"]
        )
    }

    func testUsageAlertEvaluatorClearsSuppressionWhenNoAccountsArePreserved() {
        let preserved = UsageAlertEvaluator.activeAlertIDs(
            ["usage.codex.weekly"],
            belongingTo: [],
            knownAccountIDs: ["codex"]
        )

        XCTAssertTrue(preserved.isEmpty)
    }

    func testUsageAlertEvaluatorUsesWarningPresentationBelowSeverityThreshold() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "5-hour", used: 55, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.50,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.activeAlerts.first?.severity, .warning)
    }

    func testUsageAlertEvaluatorUsesSeverityWhenSpecificThresholdsDoNotMatch() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Included usage - Total 76%",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    label: "Total",
                    used: 76,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "Cursor Warning alert")
        XCTAssertTrue(evaluation.activeAlertIDs.contains("severity.cursor.main"))
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "Total is currently at 76%.")
    }

    func testUsageAlertEvaluatorExplainsProjectedSeverity() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 40,
                    limit: 100,
                    projectionCurrent: 40,
                    projectionLimit: 100,
                    projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
                    projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60)
                ),
            ],
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            includesSeverityAlerts: true
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Critical status")
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "Weekly is projected to reach 100%.")
    }

    func testUsageAlertEvaluatorReportsSeverityAlongsideSpecificThresholds() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    label: "Weekly usage limit",
                    used: 95,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.map(\.title), ["Codex Weekly usage limit alert", "Codex Critical alert"])
        XCTAssertEqual(first.activeAlertIDs, ["usage.codex.personal.weekly-usage-limit", "severity.codex.personal"])
        XCTAssertEqual(first.activeAlerts.map(\.accountID), ["codex.personal", "codex.personal"])
        XCTAssertTrue(repeated.notifications.isEmpty)
    }

    func testUsageAlertEvaluatorPreservesClaudeWeeklyAlertIdentity() {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    stableKey: "weekly-all",
                    label: "All models weekly usage limit",
                    used: 90,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let legacyAlertID = "usage.claude.personal.weekly-usage-limit"

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.80,
                includesSeverityAlerts: false
            ),
            activeAlertIDs: [legacyAlertID]
        )

        XCTAssertTrue(evaluation.notifications.isEmpty)
        XCTAssertEqual(evaluation.activeAlertIDs, [legacyAlertID])
    }

}
