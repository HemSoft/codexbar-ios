import XCTest
@testable import CodexBarWatch

final class WatchComplicationCompatibilityTests: XCTestCase {
    func testSavedGreptileMetricSurvivesQuotaModeChanges() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resolver = WatchComplicationResolver()

        let savedCompleted = resolver.resolve(
            snapshot: snapshot(metricID: "greptile.review-quota", fraction: 1, at: now),
            selection: WatchComplicationSelection(
                accountID: "greptile.team",
                metricID: "greptile.completed-reviews"
            ),
            at: now
        )
        let savedQuota = resolver.resolve(
            snapshot: snapshot(metricID: "greptile.completed-reviews", fraction: 0.5, at: now),
            selection: WatchComplicationSelection(
                accountID: "greptile.team",
                metricID: "greptile.review-quota"
            ),
            at: now
        )

        XCTAssertEqual(savedCompleted.availability, .value)
        XCTAssertEqual(savedCompleted.exactValue, "100%")
        XCTAssertEqual(savedQuota.availability, .value)
        XCTAssertEqual(savedQuota.exactValue, "50%")
    }

    private func snapshot(
        metricID: String,
        fraction: Double,
        at now: Date
    ) -> WatchDashboardSnapshot {
        WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                WatchAccountSnapshot(
                    id: "greptile.team",
                    providerName: "Greptile",
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
