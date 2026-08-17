import XCTest
@testable import CodexBarIOS

final class UsageAlertTests: XCTestCase {
    @MainActor
    func testUsageAlertSettingsPersistAndValidateThresholdRelationship() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertFalse(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.warningThreshold, 0.75)
        XCTAssertEqual(store.usageAlertSettings.criticalThreshold, 0.90)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 5.00)

        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertWarningThreshold(0.60)
        store.updateUsageAlertCriticalThreshold(0.80)
        store.updateUsageAlertBalanceThreshold(-5)
        store.updateUsageAlertActiveIDs([
            "severity.warning.codex.personal",
            "balance.openRouter",
        ])

        let reloadedStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        XCTAssertTrue(reloadedStore.usageAlertSettings.isEnabled)
        XCTAssertEqual(reloadedStore.usageAlertSettings.warningThreshold, 0.60)
        XCTAssertEqual(reloadedStore.usageAlertSettings.criticalThreshold, 0.80)
        XCTAssertEqual(reloadedStore.usageAlertSettings.balanceThreshold, 0)
        XCTAssertEqual(
            reloadedStore.usageAlertActiveIDs,
            ["severity.warning.codex.personal", "balance.openRouter"]
        )

        reloadedStore.updateUsageAlertWarningThreshold(1)
        XCTAssertEqual(reloadedStore.usageAlertSettings.warningThreshold, 0.79)
        reloadedStore.updateUsageAlertCriticalThreshold(0.50)
        XCTAssertEqual(reloadedStore.usageAlertSettings.criticalThreshold, 0.80)
    }

    func testUsageAlertThresholdsNormalizeNonFiniteInputs() {
        let thresholds = UsageSeverityThresholds(
            warning: .nan,
            critical: .nan
        )
        XCTAssertEqual(thresholds, .default)

        var settings = UsageAlertSettings(
            warningThreshold: .nan,
            criticalThreshold: .nan
        )
        XCTAssertEqual(settings.warningThreshold, 0.75)
        XCTAssertEqual(settings.criticalThreshold, 0.90)

        settings.updateWarningThreshold(.nan)
        settings.updateCriticalThreshold(.nan)
        XCTAssertEqual(settings.warningThreshold, 0.75)
        XCTAssertEqual(settings.criticalThreshold, 0.90)
    }

    @MainActor
    func testLegacySettingsMigrateToSeverityDefaults() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "usageThreshold": 0.55,
            "balanceThreshold": 7.0,
            "includesSeverityAlerts": false,
        ])
        defaults.set(legacyData, forKey: "usageAlertSettings")

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertTrue(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.warningThreshold, 0.75)
        XCTAssertEqual(store.usageAlertSettings.criticalThreshold, 0.90)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 7)

        let migratedData = try XCTUnwrap(defaults.data(forKey: "usageAlertSettings"))
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["warningThreshold"] as? Double, 0.75)
        XCTAssertEqual(migratedObject["criticalThreshold"] as? Double, 0.90)
        XCTAssertNil(migratedObject["usageThreshold"])
        XCTAssertNil(migratedObject["includesSeverityAlerts"])
    }

    @MainActor
    func testLegacySettingsMigrationPreservesCredentialReadError() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration(
            providerID: .claude,
            authMethod: .browserSession
        )
        defaults.set(
            try JSONEncoder().encode([configuration]),
            forKey: "providerConfigurations"
        )
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "isEnabled": true,
                "usageThreshold": 0.80,
                "balanceThreshold": 5.0,
                "includesSeverityAlerts": true,
            ]),
            forKey: "usageAlertSettings"
        )

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: FailingReadSecretStore()
        )

        XCTAssertEqual(
            store.lastError,
            "Could not read the saved credential for Claude: Keychain unavailable"
        )
        XCTAssertEqual(store.usageAlertSettings.warningThreshold, 0.75)
        XCTAssertEqual(store.usageAlertSettings.criticalThreshold, 0.90)
    }

    @MainActor
    func testUnknownFutureSettingsPayloadIsNotRewrittenAsLegacy() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let futureData = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "futureWarningThreshold": 0.65,
            "futureCriticalThreshold": 0.85,
            "balanceThreshold": 8.0,
        ])
        defaults.set(futureData, forKey: "usageAlertSettings")

        _ = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore()
        )

        XCTAssertEqual(defaults.data(forKey: "usageAlertSettings"), futureData)
    }

    @MainActor
    func testThresholdChangesInvalidateOnlyAffectedSuppressionState() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        let warningID = "severity.warning.codex.personal"
        let criticalID = "severity.critical.codex.personal"
        let balanceID = "balance.openRouter"
        store.updateUsageAlertActiveIDs([warningID, criticalID, balanceID])

        store.updateUsageAlertCriticalThreshold(0.95)
        XCTAssertEqual(store.usageAlertActiveIDs, [warningID, balanceID])

        store.updateUsageAlertActiveIDs([warningID, criticalID, balanceID])
        store.updateUsageAlertWarningThreshold(0.70)
        XCTAssertEqual(store.usageAlertActiveIDs, [criticalID, balanceID])

        store.updateUsageAlertActiveIDs([warningID, criticalID, balanceID])
        store.updateUsageAlertBalanceThreshold(10)
        XCTAssertEqual(store.usageAlertActiveIDs, [warningID, criticalID])

        store.updateUsageAlertsEnabled(true)
        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)
    }

    func testCurrentUsageUsesConfiguredWarningAndCriticalThresholds() {
        let settings = UsageAlertSettings(
            isEnabled: true,
            warningThreshold: 0.60,
            criticalThreshold: 0.85
        )
        let warning = result(used: 60)
        let critical = result(used: 85)

        let warningEvaluation = UsageAlertEvaluator.evaluate(
            results: [warning],
            settings: settings,
            activeAlertIDs: []
        )
        XCTAssertEqual(warningEvaluation.notifications.count, 1)
        XCTAssertEqual(warningEvaluation.notifications.first?.kind, .severity)
        XCTAssertEqual(warningEvaluation.notifications.first?.title, "Codex Warning")
        XCTAssertEqual(
            warningEvaluation.notifications.first?.body,
            "Warning status. Weekly current usage is 60% (Warning at 60%)."
        )
        XCTAssertEqual(warningEvaluation.activeAlerts.first?.severity, .warning)
        XCTAssertEqual(
            warningEvaluation.activeAlertIDs,
            ["severity.warning.codex.personal"]
        )

        let criticalEvaluation = UsageAlertEvaluator.evaluate(
            results: [critical],
            settings: settings,
            activeAlertIDs: []
        )
        XCTAssertEqual(criticalEvaluation.notifications.count, 1)
        XCTAssertEqual(
            criticalEvaluation.notifications.first?.title,
            "Codex Critical Alert"
        )
        XCTAssertEqual(
            criticalEvaluation.notifications.first?.body,
            "Critical status. Weekly current usage is 85% (Critical Alert at 85%)."
        )
        XCTAssertEqual(criticalEvaluation.activeAlerts.first?.severity, .critical)
        XCTAssertEqual(
            criticalEvaluation.activeAlertIDs,
            [
                "severity.warning.codex.personal",
                "severity.critical.codex.personal",
            ]
        )
    }

    func testNotificationsIdentifyCustomAndFallbackLabelsForSameProvider() {
        let evaluations = [
            result(accountID: "codex.first-private-id", title: "Work Codex", used: 80),
            result(accountID: "codex.second-private-id", title: "Codex 2", used: 80),
        ].map {
            UsageAlertEvaluator.evaluate(
                results: [$0],
                settings: UsageAlertSettings(isEnabled: true),
                activeAlertIDs: []
            )
        }

        XCTAssertEqual(
            evaluations.compactMap { $0.notifications.first?.title },
            ["Work Codex Warning", "Codex 2 Warning"]
        )
        let notificationText = evaluations.flatMap(\.notifications).map {
            "\($0.title) \($0.body)"
        }.joined(separator: " ")
        XCTAssertFalse(notificationText.contains("first-private-id"))
        XCTAssertFalse(notificationText.contains("second-private-id"))
    }

    func testLegacySuppressionIDsMigrateWithoutDuplicateNotifications() throws {
        let settings = UsageAlertSettings(isEnabled: true)

        let warning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: ["usage.codex.personal.weekly"]
        )
        XCTAssertTrue(warning.notifications.isEmpty)
        XCTAssertEqual(
            warning.activeAlertIDs,
            ["severity.warning.codex.personal"]
        )

        let critical = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: settings,
            activeAlertIDs: ["severity.codex.personal"]
        )
        XCTAssertEqual(
            critical.notifications.map(\.title),
            ["Codex Critical Alert"]
        )
        XCTAssertEqual(
            critical.activeAlertIDs,
            [
                "severity.warning.codex.personal",
                "severity.critical.codex.personal",
            ]
        )

        let criticalNotification = try XCTUnwrap(critical.notifications.first)
        var activeAlertIDs = critical.activeAlertIDs
        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: criticalNotification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: ["severity.codex.personal"],
            knownAccountIDs: ["codex.personal"]
        )
        XCTAssertEqual(activeAlertIDs, ["severity.warning.codex.personal"])

        let recoveredToWarning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: activeAlertIDs
        )
        XCTAssertTrue(recoveredToWarning.notifications.isEmpty)
    }

    func testLegacySuppressionIDsUseExactAccountIdentity() throws {
        let defaultResult = result(accountID: "codex", used: 95)
        let legacySecondaryAlertID = "usage.codex.secondary.weekly"
        let settings = UsageAlertSettings(isEnabled: true)

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [defaultResult],
            settings: settings,
            activeAlertIDs: [legacySecondaryAlertID],
            knownAccountIDs: ["codex", "codex.secondary"]
        )

        XCTAssertEqual(
            evaluation.notifications.map(\.title),
            ["Codex Critical Alert"]
        )
        let notification = try XCTUnwrap(evaluation.notifications.first)
        var activeAlertIDs = evaluation.activeAlertIDs
        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: notification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: [legacySecondaryAlertID],
            knownAccountIDs: ["codex", "codex.secondary"]
        )
        XCTAssertTrue(activeAlertIDs.isEmpty)
    }

    func testProjectedUsageUsesConfiguredThresholds() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let projectedResult = result(
            used: 40,
            projectionCurrent: 40,
            projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
            projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60),
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            warningThreshold: 0.70,
            criticalThreshold: 0.95
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [projectedResult],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.activeAlerts.first?.severity, .critical)
        XCTAssertEqual(
            evaluation.activeAlerts.first?.message,
            "Weekly projected usage is 100% (Critical Alert at 95%)."
        )
        XCTAssertEqual(
            evaluation.notifications.first?.body,
            "Critical status. Weekly projected usage is 100% (Critical Alert at 95%)."
        )
    }

    func testEscalationRecoveryAndRearmingProduceOnlyUsefulNotifications() {
        let settings = UsageAlertSettings(isEnabled: true)

        let warning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: []
        )
        XCTAssertEqual(warning.notifications.map(\.title), ["Codex Warning"])

        let critical = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: settings,
            activeAlertIDs: warning.activeAlertIDs
        )
        XCTAssertEqual(critical.notifications.map(\.title), ["Codex Critical Alert"])

        let recoveredToWarning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: critical.activeAlertIDs
        )
        XCTAssertTrue(recoveredToWarning.notifications.isEmpty)
        XCTAssertEqual(
            recoveredToWarning.activeAlertIDs,
            ["severity.warning.codex.personal"]
        )

        let recoveredToNormal = UsageAlertEvaluator.evaluate(
            results: [result(used: 50)],
            settings: settings,
            activeAlertIDs: recoveredToWarning.activeAlertIDs
        )
        XCTAssertTrue(recoveredToNormal.activeAlertIDs.isEmpty)

        let rearmed = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: recoveredToNormal.activeAlertIDs
        )
        XCTAssertEqual(rearmed.notifications.map(\.title), ["Codex Warning"])
    }

    func testMultipleMetricsChooseTheLargestCrossingRegardlessOfArrayOrder() {
        let bars = [
            UsageBar(stableKey: "five-hour", label: "5-hour", used: 105, limit: 100),
            UsageBar(stableKey: "weekly", label: "Weekly", used: 112, limit: 100),
        ]
        func makeResult(bars: [UsageBar]) -> ProviderUsageResult {
            ProviderUsageResult(
                accountID: "codex.personal",
                providerID: .codex,
                title: "Codex",
                subtitle: "Live usage",
                bars: bars,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            )
        }

        let evaluations = [bars, Array(bars.reversed())].map { bars in
            UsageAlertEvaluator.evaluate(
                results: [makeResult(bars: Array(bars))],
                settings: UsageAlertSettings(isEnabled: true),
                activeAlertIDs: []
            )
        }

        XCTAssertTrue(evaluations.allSatisfy { $0.notifications.count == 1 })
        XCTAssertEqual(
            evaluations.compactMap { $0.notifications.first?.body },
            [
                "Critical status. Weekly current usage is 112% (Critical Alert at 90%).",
                "Critical status. Weekly current usage is 112% (Critical Alert at 90%).",
            ]
        )
        XCTAssertTrue(evaluations.allSatisfy { evaluation in
            evaluation.activeAlerts.count == 1
                && !evaluation.activeAlertIDs.contains { $0.hasPrefix("usage.") }
        })
    }

    func testFailedCriticalDeliveryClearsCompanionWarningLatch() throws {
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: UsageAlertSettings(isEnabled: true),
            activeAlertIDs: []
        )
        let notification = try XCTUnwrap(evaluation.notifications.first)
        var activeAlertIDs = evaluation.activeAlertIDs

        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: notification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: [],
            knownAccountIDs: ["codex.personal"]
        )

        XCTAssertTrue(activeAlertIDs.isEmpty)
        let warningEvaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: UsageAlertSettings(isEnabled: true),
            activeAlertIDs: activeAlertIDs
        )
        XCTAssertEqual(warningEvaluation.notifications.map(\.title), ["Codex Warning"])
    }

    func testFailedCriticalDeliveryRetainsPreviouslyDeliveredWarningLatch() throws {
        let settings = UsageAlertSettings(isEnabled: true)
        let warningEvaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: []
        )
        let criticalEvaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: settings,
            activeAlertIDs: warningEvaluation.activeAlertIDs
        )
        let criticalNotification = try XCTUnwrap(
            criticalEvaluation.notifications.first
        )
        var activeAlertIDs = criticalEvaluation.activeAlertIDs

        UsageAlertEvaluator.removeActiveAlertIDs(
            forFailedDelivery: criticalNotification,
            from: &activeAlertIDs,
            previouslyActiveAlertIDs: warningEvaluation.activeAlertIDs,
            knownAccountIDs: ["codex.personal"]
        )

        XCTAssertEqual(activeAlertIDs, ["severity.warning.codex.personal"])
        let recoveredWarning = UsageAlertEvaluator.evaluate(
            results: [result(used: 80)],
            settings: settings,
            activeAlertIDs: activeAlertIDs
        )
        XCTAssertTrue(recoveredWarning.notifications.isEmpty)
    }

    func testSpendLimitRemainsCriticalRegardlessOfPercentageThresholds() {
        let result = ProviderUsageResult(
            accountID: "claude.capped",
            providerID: .claude,
            title: "Work Claude",
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

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                warningThreshold: 0.98,
                criticalThreshold: 0.99
            ),
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.severity])
        XCTAssertEqual(evaluation.notifications.first?.title, "Work Claude Critical Alert")
        XCTAssertEqual(evaluation.activeAlerts.first?.severity, .critical)
        XCTAssertEqual(
            evaluation.activeAlerts.first?.message,
            "Work Claude reached its monthly usage-credit spend limit."
        )
    }

    func testLowBalanceAlertBehaviorRemainsIndependent() {
        let result = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(isEnabled: true, balanceThreshold: 5),
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.balance])
        XCTAssertEqual(evaluation.notifications.first?.title, "OpenRouter balance alert")
        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Balance below $5.00")
    }

    func testStaleBarsPreserveSuppressionWithoutSendingNewAlert() {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let settings = UsageAlertSettings(isEnabled: true)
        let freshResult = result(used: 80, fetchedAt: fetchedAt)
        let first = UsageAlertEvaluator.evaluate(
            results: [freshResult],
            settings: settings,
            activeAlertIDs: []
        )
        let staleResult = ProviderUsageResult(
            accountID: freshResult.accountID,
            providerID: freshResult.providerID,
            title: freshResult.title,
            subtitle: "Cached usage",
            bars: freshResult.bars,
            barsFetchedAt: fetchedAt,
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )

        let stale = UsageAlertEvaluator.evaluate(
            results: [staleResult],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertTrue(stale.notifications.isEmpty)
        XCTAssertTrue(stale.activeAlerts.isEmpty)
        XCTAssertEqual(stale.activeAlertIDs, first.activeAlertIDs)
    }

    func testSuppressionPreservationUsesExactAccountIdentity() {
        let activeAlertIDs: Set<String> = [
            "severity.warning.codex",
            "severity.warning.codex.secondary",
            "balance.openrouter.failed",
        ]

        let preserved = UsageAlertEvaluator.activeAlertIDs(
            activeAlertIDs,
            belongingTo: ["codex.secondary", "openrouter.failed"],
            knownAccountIDs: ["codex", "codex.secondary", "openrouter.failed"]
        )

        XCTAssertEqual(
            preserved,
            [
                "severity.warning.codex.secondary",
                "balance.openrouter.failed",
            ]
        )
    }

    func testDisabledAlertsClearSuppressionAndDetails() {
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result(used: 95)],
            settings: UsageAlertSettings(isEnabled: false),
            activeAlertIDs: [
                "severity.warning.codex.personal",
                "severity.critical.codex.personal",
            ]
        )

        XCTAssertTrue(evaluation.notifications.isEmpty)
        XCTAssertTrue(evaluation.activeAlertIDs.isEmpty)
        XCTAssertTrue(evaluation.activeAlerts.isEmpty)
    }

    func testUsageBarCurrentAndProjectedSeverityAcceptConfiguredThresholds() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let thresholds = UsageSeverityThresholds(warning: 0.50, critical: 0.80)
        let bar = UsageBar(
            label: "Weekly",
            used: 40,
            limit: 100,
            projectionCurrent: 40,
            projectionLimit: 100,
            projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
            projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60)
        )

        XCTAssertEqual(bar.severity(using: thresholds), .normal)
        XCTAssertEqual(
            bar.projectedSeverity(at: now, thresholds: thresholds),
            .critical
        )
        XCTAssertEqual(
            bar.effectiveSeverity(at: now, thresholds: thresholds),
            .critical
        )
    }

    func testHistorySnapshotsCaptureConfiguredSeverity() {
        let snapshot = UsageHistorySnapshot(
            result: result(used: 60),
            severityThresholds: UsageSeverityThresholds(
                warning: 0.50,
                critical: 0.80
            )
        )

        XCTAssertEqual(snapshot.bars.first?.effectiveSeverity, .warning)
        XCTAssertEqual(snapshot.highestSeverity, .warning)
    }

    @MainActor
    func testHistorySeriesRecomputesProjectedSeverityUsingActiveThresholds() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capturedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let projectedResult = result(
            used: 60,
            projectionCurrent: 60,
            projectionPeriodStart: capturedAt.addingTimeInterval(-75),
            projectionPeriodEnd: capturedAt.addingTimeInterval(25),
            fetchedAt: capturedAt
        )
        let historyStore = UsageHistoryStore(defaults: defaults)

        historyStore.record(results: [projectedResult], now: capturedAt)

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(
            reloadedStore.historySeries(
                for: projectedResult,
                severityThresholds: UsageSeverityThresholds(
                    warning: 0.75,
                    critical: 0.90
                )
            ).points.map(\.severity),
            [.warning]
        )
        XCTAssertEqual(
            reloadedStore.historySeries(
                for: projectedResult,
                severityThresholds: UsageSeverityThresholds(
                    warning: 0.85,
                    critical: 0.95
                )
            ).points.map(\.severity),
            [.normal]
        )
    }

    @MainActor
    func testWidgetAndWatchSnapshotsUseConfiguredThresholds() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = store.addAccount(for: .codex)
        XCTAssertTrue(store.saveSecret("test-token", for: configuration))
        store.updateUsageAlertWarningThreshold(0.50)
        store.updateUsageAlertCriticalThreshold(0.80)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(stableKey: "weekly", label: "Weekly", used: 60, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults
        )
        let widgetProvider = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        XCTAssertEqual(widgetProvider.bars.first?.severity, .warning)
        XCTAssertEqual(widgetProvider.severity, .warning)

        let watchSnapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store
        )
        XCTAssertEqual(watchSnapshot.accounts.first?.metrics.first?.severity, .warning)
    }

    private func result(
        accountID: String = "codex.personal",
        title: String = "Codex",
        used: Double,
        projectionCurrent: Double? = nil,
        projectionPeriodStart: Date? = nil,
        projectionPeriodEnd: Date? = nil,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_783_667_520)
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: accountID,
            providerID: .codex,
            title: title,
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    stableKey: "weekly",
                    label: "Weekly",
                    used: used,
                    limit: 100,
                    projectionCurrent: projectionCurrent,
                    projectionLimit: projectionCurrent == nil ? nil : 100,
                    projectionPeriodStart: projectionPeriodStart,
                    projectionPeriodEnd: projectionPeriodEnd
                ),
            ],
            fetchedAt: fetchedAt
        )
    }
}
