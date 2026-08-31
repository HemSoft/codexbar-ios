import XCTest
@testable import CodexBarIOS

final class ProviderUsageCardHiddenSeverityTests: XCTestCase {
    func testHiddenMetricExplainsCardSeverityAndVoiceOver() throws {
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Usage",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.cursorModelsStableKey,
                    label: "Cursor Models",
                    used: 38,
                    limit: 100
                ),
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 100,
                    limit: 100
                ),
            ],
            fetchedAt: Date()
        )
        let hiddenMetricID = CursorUsageIdentity.otherModelsMetricID
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { $0 != hiddenMetricID }
            )
        )

        XCTAssertEqual(alert.title, "Critical status from hidden metric")
        XCTAssertEqual(alert.message, "Hidden metric Other Models is currently at 100%.")
        XCTAssertNil(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { _ in true }
            )
        )
        XCTAssertEqual(
            ProviderUsageCard.disclosureAccessibilityLabel(
                for: result,
                statusText: "Current",
                isRefreshing: false,
                isPerformingRecovery: false,
                severity: .critical,
                severitySource: alert.message
            ),
            "Cursor, Current, Critical status, Hidden metric Other Models is currently at 100%."
        )
    }

    func testHiddenMetricExplainsProjectedSeverity() throws {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Usage",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
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
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                now: now,
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertEqual(
            alert.message,
            "Hidden metric Other Models is currently at 40% and projected to reach 100%."
        )

        let cachedResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: "Refresh failed. Showing last known data.",
            bars: result.bars,
            barsFetchedAt: now,
            failureMessage: "Refresh failed",
            fetchedAt: now
        )
        let cachedAlert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: cachedResult,
                cardSeverity: .critical,
                now: now,
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertEqual(
            cachedAlert.message,
            "Hidden metric Other Models was last known at 40% and was projected to reach 100%."
        )
    }

    func testHiddenBalanceExplainsAlertSeverity() throws {
        let result = ProviderUsageResult(
            accountID: "openRouter.personal",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date()
        )
        let balanceAlert = UsageAlertDetail(
            id: "balance.openRouter.personal",
            accountID: result.accountID,
            kind: .balance,
            title: "Balance below $5.00",
            message: "$4.50 remaining for OpenRouter.",
            severity: .warning
        )
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .warning,
                alerts: [balanceAlert],
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertEqual(alert.title, "Balance below $5.00 from hidden metric")
        XCTAssertEqual(alert.message, "Hidden metric Credit balance is currently at $4.50.")
    }

    func testFreshHiddenBalanceIsExplainedWhenBarsAreStale() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_200)
        let result = ProviderUsageResult(
            accountID: "openCodeZen.personal",
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen",
            subtitle: "Go refresh failed",
            bars: [UsageBar(stableKey: "weekly", label: "Weekly", used: 20, limit: 100)],
            barsFetchedAt: fetchedAt.addingTimeInterval(-60),
            creditsRemaining: 4.50,
            creditsFetchedAt: fetchedAt,
            failureMessage: "Go refresh failed",
            preserveCachedBarsOnFailure: true,
            fetchedAt: fetchedAt
        )
        let balanceAlert = UsageAlertDetail(
            id: "balance.openCodeZen.personal",
            accountID: result.accountID,
            kind: .balance,
            title: "Balance below $5.00",
            message: "$4.50 remaining for OpenCode Go + Zen.",
            severity: .warning
        )
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .warning,
                alerts: [balanceAlert],
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertFalse(result.hasFreshBars)
        XCTAssertTrue(result.hasCurrentCredits)
        XCTAssertEqual(alert.message, "Hidden metric Zen credit balance is currently at $4.50.")
    }

    func testCachedHiddenUsageIsLabeledLastKnown() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_785_000_300)
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Refresh failed. Showing last known data.",
            bars: [
                UsageBar(
                    stableKey: CursorUsageIdentity.otherModelsStableKey,
                    label: "Other Models",
                    used: 100,
                    limit: 100
                ),
            ],
            barsFetchedAt: fetchedAt,
            failureMessage: "Refresh failed",
            fetchedAt: fetchedAt
        )
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { _ in false }
            )
        )

        XCTAssertTrue(result.hasFreshBars)
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertEqual(alert.message, "Hidden metric Other Models was last known at 100%.")
    }

    func testHiddenSpendExplainsReachedLimitSeverity() throws {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Usage credits",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Monthly spend",
                    minorUnits: 5_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 5_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date()
        )
        let spentMetricID = "claude.monetary.spent.usd"
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { $0 != spentMetricID }
            )
        )

        XCTAssertEqual(alert.title, "Critical status from hidden metric")
        XCTAssertEqual(
            alert.message,
            "Hidden metric Monthly spend is currently at $50.00 and has reached the $50.00 limit."
        )

        let cachedResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: "Refresh failed. Showing last known data.",
            bars: [],
            monetaryMetrics: result.monetaryMetrics,
            failureMessage: "Refresh failed",
            fetchedAt: result.fetchedAt
        )
        let cachedAlert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: cachedResult,
                cardSeverity: .critical,
                isMetricVisible: { $0 != spentMetricID }
            )
        )

        XCTAssertEqual(
            cachedAlert.message,
            "Hidden metric Monthly spend was last known at $50.00 "
                + "and was last known to have reached the $50.00 limit."
        )
    }
}
