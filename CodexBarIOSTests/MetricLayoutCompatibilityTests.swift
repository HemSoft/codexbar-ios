import XCTest
@testable import CodexBarIOS

final class MetricLayoutCompatibilityTests: XCTestCase {
    @MainActor
    func testGreptilePreferenceSurvivesQuotaAvailabilityChanges() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountID = "greptile.team"
        let completedID = GreptileUsageIdentity.completedReviewsMetricID
        let quotaID = GreptileUsageIdentity.reviewQuotaMetricID
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore()
        )
        _ = store.reconcileMetricLayout(accountID: accountID, availableMetricIDs: [completedID])
        store.updateMetricVisibility(false, accountID: accountID, metricID: completedID)
        store.updateVisualizationStyle(.circularRing, accountID: accountID, metricID: completedID)
        store.updateMetricWidth(.half, accountID: accountID, metricID: completedID)
        store.updateWatchMetricVisibility(.show, accountID: accountID, metricID: completedID)

        let quotaLayout = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [quotaID]
        )
        let quotaPreference = try XCTUnwrap(quotaLayout.preferences[quotaID])
        XCTAssertEqual(quotaLayout.orderedMetricIDs, [quotaID])
        XCTAssertNil(quotaLayout.preferences[completedID])
        XCTAssertFalse(quotaPreference.isVisible)
        XCTAssertEqual(quotaPreference.visualizationStyle, .circularRing)
        XCTAssertEqual(quotaPreference.width, .half)
        XCTAssertEqual(quotaPreference.watchVisibility, .show)
        XCTAssertFalse(quotaPreference.isNewlyDiscovered)

        let completedLayout = store.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: [completedID]
        )
        XCTAssertEqual(completedLayout.orderedMetricIDs, [completedID])
        XCTAssertEqual(completedLayout.preferences[completedID], quotaPreference)
        XCTAssertNil(completedLayout.preferences[quotaID])
    }
}
