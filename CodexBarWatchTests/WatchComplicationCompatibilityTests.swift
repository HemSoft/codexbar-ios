import XCTest
@testable import CodexBarWatch

final class WatchComplicationCompatibilityTests: XCTestCase {
    func testSavedGreptileMetricSurvivesQuotaModeChanges() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resolver = WatchComplicationResolver()

        let quotaForSavedCompletedSelection = resolver.resolve(
            snapshot: snapshot(metricID: "greptile.review-quota", fraction: 1, at: now),
            selection: WatchComplicationSelection(
                accountID: "greptile.team",
                metricID: "greptile.completed-reviews"
            ),
            at: now
        )
        let completedForSavedQuotaSelection = resolver.resolve(
            snapshot: snapshot(metricID: "greptile.completed-reviews", fraction: 0.5, at: now),
            selection: WatchComplicationSelection(
                accountID: "greptile.team",
                metricID: "greptile.review-quota"
            ),
            at: now
        )

        XCTAssertEqual(quotaForSavedCompletedSelection.availability, .value)
        XCTAssertEqual(quotaForSavedCompletedSelection.exactValue, "100%")
        XCTAssertEqual(completedForSavedQuotaSelection.availability, .value)
        XCTAssertEqual(completedForSavedQuotaSelection.exactValue, "50%")
    }

    func testSavedCursorMetricsSurviveSemanticIdentityUpgrade() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resolver = WatchComplicationResolver()

        let cursorModels = resolver.resolve(
            snapshot: snapshot(
                accountID: "cursor.personal",
                providerName: "Cursor",
                metricID: "cursor.cursor-models",
                fraction: 0.25,
                at: now
            ),
            selection: WatchComplicationSelection(
                accountID: "cursor.personal",
                metricID: "cursor.auto"
            ),
            at: now
        )
        let otherModels = resolver.resolve(
            snapshot: snapshot(
                accountID: "cursor.personal",
                providerName: "Cursor",
                metricID: "cursor.other-models",
                fraction: 0.5,
                at: now
            ),
            selection: WatchComplicationSelection(
                accountID: "cursor.personal",
                metricID: "cursor.api"
            ),
            at: now
        )

        XCTAssertEqual(cursorModels.availability, .value)
        XCTAssertEqual(cursorModels.exactValue, "25%")
        XCTAssertEqual(otherModels.availability, .value)
        XCTAssertEqual(otherModels.exactValue, "50%")
    }

    private func snapshot(
        accountID: String = "greptile.team",
        providerName: String = "Greptile",
        metricID: String,
        fraction: Double,
        at now: Date
    ) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: accountID,
                    providerName: providerName,
                    accountLabel: "Team",
                    fetchedAt: now,
                    metrics: [
                        WatchMetricSnapshot(
                            id: metricID,
                            label: "Reviews",
                            usedFraction: fraction,
                            remainingFraction: 1 - fraction,
                            exactValue: "\(Int(fraction * 100))%"
                        ),
                    ]
                ),
            ]
        )
    }
}
