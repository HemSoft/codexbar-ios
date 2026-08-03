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
                UsageBar(stableKey: "total", label: "Total", used: 38, limit: 100),
                UsageBar(stableKey: "api", label: "API", used: 100, limit: 100),
            ],
            fetchedAt: Date()
        )
        let hiddenMetricID = "cursor.api"
        let alert = try XCTUnwrap(
            ProviderUsageCard.hiddenSeverityAlert(
                for: result,
                cardSeverity: .critical,
                isMetricVisible: { $0 != hiddenMetricID }
            )
        )

        XCTAssertEqual(alert.title, "Critical status from hidden metric")
        XCTAssertEqual(alert.message, "Hidden metric API is currently at 100%.")
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
            "Cursor, Current, Critical status, Hidden metric API is currently at 100%."
        )
    }
}
