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
                fraction: 1.374,
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
                fraction: 1.18,
                at: now
            ),
            selection: WatchComplicationSelection(
                accountID: "cursor.personal",
                metricID: "cursor.api"
            ),
            at: now
        )

        XCTAssertEqual(cursorModels.availability, .value)
        XCTAssertEqual(cursorModels.exactValue, "137%")
        XCTAssertEqual(cursorModels.usedFraction, 1.374)
        XCTAssertEqual(cursorModels.clampedUsedFraction, 1)
        XCTAssertEqual(otherModels.availability, .value)
        XCTAssertEqual(otherModels.exactValue, "118%")
        XCTAssertEqual(otherModels.usedFraction, 1.18)
        XCTAssertEqual(otherModels.clampedUsedFraction, 1)
    }

    func testWatchGaugeTextNormalizesNegativeFractions() {
        let sample = WatchUsageSample(
            id: "negative",
            providerName: "Provider",
            accountLabel: "Account",
            metricLabel: "Usage",
            exactValue: "-5%",
            usedFraction: -0.05,
            severity: .normal,
            resetText: nil,
            visualizationStyle: .circularRing,
            freshnessText: "Updated just now"
        )

        XCTAssertEqual(sample.percentageText, "0%")
        XCTAssertEqual(sample.clampedUsedFraction, 0)
    }

    func testConfirmedGoogleAliasPreservesCodingSelectionAndMissingSourceStatus() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let apps = WatchMetricSnapshot(id: "gemini.weekly", label: "Gemini Apps weekly", exactValue: "10%")
        let coding = WatchMetricSnapshot(id: "antigravity.gemini-weekly", label: "Gemini Models weekly", exactValue: "31%")
        let selection = WatchComplicationSelection(accountID: "legacy-coding", metricID: "antigravity.gemini-weekly")
        for metrics in [[apps, coding], [apps]] {
            let original = WatchDashboardSnapshot(
                generatedAt: now, refreshIntervalSeconds: 300,
                accounts: [WatchAccountSnapshot(
                    id: "gemini.account", legacyAccountIDs: ["legacy-coding"], providerName: "Google Gemini",
                    accountLabel: "Personal", fetchedAt: now, metrics: metrics
                ),
                ]
            )
            let decoded = try WatchDashboardSnapshot.decode(JSONEncoder().encode(original))
            XCTAssertEqual(decoded.accounts.first?.legacyAccountIDs, ["legacy-coding"])
            let resolver = WatchComplicationResolver()
            let sample = resolver.resolve(snapshot: decoded, selection: selection, at: now)
            let automaticLegacy = resolver.resolve(
                snapshot: decoded, selection: WatchComplicationSelection(accountID: "legacy-coding", metricID: nil), at: now
            )
            XCTAssertEqual(sample.availability, metrics.count == 2 ? .value : .unavailable)
            XCTAssertEqual(automaticLegacy.availability, sample.availability)
            if metrics.count == 2 {
                XCTAssertEqual(sample.exactValue, "31%")
                XCTAssertEqual(automaticLegacy.metricLabel, "Gemini Models weekly")
                let choices = WatchComplicationChoiceCatalog(snapshot: decoded)
                XCTAssertEqual(choices.accounts(for: ["legacy-coding"]).first?.providerName, "Google Gemini")
                XCTAssertEqual(choices.metrics(for: ["legacy-coding::antigravity.gemini-weekly"]).first?.metricLabel, "Gemini Models weekly")
            }
            XCTAssertEqual(resolver.resolve(
                snapshot: decoded, selection: WatchComplicationSelection(accountID: "unlinked", metricID: coding.id), at: now
            ).availability, .unavailable)
        }
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
