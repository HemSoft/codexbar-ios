import XCTest
@testable import CodexBarWatch

final class WatchDashboardStateTests: XCTestCase {
    func testProductionStartsWithoutDemoUsage() {
        XCTAssertTrue(WatchDashboardState.empty.samples.isEmpty)
        XCTAssertEqual(WatchDashboardState.empty.statusText, "Open CodexBar on iPhone")
    }

    func testBuiltWatchDeclaresLocalSnapshotPreferenceAccess() throws {
        let bundle = Bundle(for: WatchDashboardStore.self)
        let manifestURL = try XCTUnwrap(
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        )
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let accessedAPITypes = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        let defaultsEntry = try XCTUnwrap(
            accessedAPITypes.first {
                $0["NSPrivacyAccessedAPIType"] as? String
                    == "NSPrivacyAccessedAPICategoryUserDefaults"
            }
        )
        XCTAssertEqual(
            Set(defaultsEntry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []),
            ["CA92.1"]
        )
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertTrue((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.isEmpty == true)
    }

    func testSnapshotPreservesAccountAndMetricOrder() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "copilot",
                    provider: "Copilot",
                    metricID: "low",
                    fraction: 0.2,
                    generatedAt: now
                ),
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "high",
                    fraction: 0.9,
                    generatedAt: now
                ),
            ]
        )

        let state = WatchDashboardState(
            snapshot: snapshot,
            now: now,
            isPhoneReachable: true,
            decodingError: nil
        )

        XCTAssertEqual(state.samples.map(\.id), ["copilot.low", "codex.high"])
        XCTAssertEqual(state.samples.map(\.clampedUsedFraction), [0.2, 0.9])
        XCTAssertEqual(state.statusText, "Updated just now")
    }

    func testAccessibilitySummaryIncludesMeaningWithoutColorOrGeometry() {
        let sample = WatchUsageSample(
            id: "codex",
            providerName: "Codex",
            accountLabel: "Primary",
            metricLabel: "5-hour limit",
            exactValue: "72%",
            usedFraction: 0.724,
            severity: .warning,
            resetText: "Resets in 2h",
            visualizationStyle: .semicircularDial,
            freshnessText: "Updated 3m ago"
        )

        XCTAssertEqual(sample.percentageText, "72%")
        XCTAssertEqual(
            sample.accessibilitySummary,
            "Codex, Primary, 5-hour limit, 72%, Warning, Resets in 2h, Updated 3m ago"
        )
    }

    func testPayloadRoundTripAndUnknownStyleFallback() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.72,
                    generatedAt: now,
                    style: .circularRing
                ),
            ]
        )

        XCTAssertEqual(try WatchDashboardSnapshot.decode(snapshot.encoded()), snapshot)

        let encoded = try XCTUnwrap(String(data: snapshot.encoded(), encoding: .utf8))
        let futureStyle = encoded.replacingOccurrences(of: "circularRing", with: "futureStyle")
        let decoded = try WatchDashboardSnapshot.decode(Data(futureStyle.utf8))
        XCTAssertEqual(decoded.accounts[0].metrics[0].visualizationStyle, .automatic)
    }

    func testUnsupportedVersionAndMalformedMetricDoNotCrashDecoder() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let unsupported = WatchDashboardSnapshot(
            schemaVersion: 99,
            generatedAt: now,
            refreshIntervalSeconds: nil,
            accounts: []
        )
        XCTAssertThrowsError(try WatchDashboardSnapshot.decode(unsupported.encoded())) { error in
            XCTAssertEqual(error as? WatchDashboardPayloadError, .unsupportedSchemaVersion(99))
        }

        let partialJSON = """
        {
          "schemaVersion": 1,
          "generatedAt": 2000000000000,
          "accounts": [{
            "id": "codex",
            "providerName": "Codex",
            "accountLabel": "Primary",
            "fetchedAt": 2000000000000,
            "metrics": [
              {"id":"valid","label":"Usage","exactValue":"42%","usedFraction":0.42},
              {"label":"Missing required identity"}
            ]
          }]
        }
        """
        let decoded = try WatchDashboardSnapshot.decode(Data(partialJSON.utf8))
        XCTAssertEqual(decoded.accounts[0].metrics.map(\.id), ["valid"])
        XCTAssertEqual(decoded.accounts[0].metrics[0].visualizationStyle, .automatic)
    }

    func testStaleAndDisconnectedStatesKeepLastSnapshotVisible() {
        let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: generatedAt,
            refreshIntervalSeconds: 60,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: generatedAt
                ),
            ]
        )

        let disconnected = WatchDashboardState(
            snapshot: snapshot,
            now: generatedAt.addingTimeInterval(120),
            isPhoneReachable: false,
            decodingError: nil
        )
        XCTAssertEqual(disconnected.samples.count, 1)
        XCTAssertTrue(disconnected.statusText.contains("iPhone unavailable"))

        let stale = WatchDashboardState(
            snapshot: snapshot,
            now: generatedAt.addingTimeInterval(901),
            isPhoneReachable: true,
            decodingError: nil
        )
        XCTAssertEqual(stale.samples.count, 1)
        XCTAssertTrue(stale.statusText.contains("Stale"))
    }

    func testFreshnessUsesOldestDisplayedProviderFetchInsteadOfDeliveryTime() {
        let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let oldFetch = generatedAt.addingTimeInterval(-1_800)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: generatedAt,
            refreshIntervalSeconds: 60,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: oldFetch
                ),
            ]
        )

        let state = WatchDashboardState(
            snapshot: snapshot,
            now: generatedAt,
            isPhoneReachable: true,
            decodingError: nil
        )

        XCTAssertEqual(state.statusText, "Updated 30m ago • Stale")
        XCTAssertTrue(state.samples[0].accessibilitySummary.contains("Updated 30m ago"))
    }

    @MainActor
    func testMalformedUpdatePreservesPersistedLastGoodSnapshot() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = WatchDashboardStore(defaults: defaults, session: nil)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )

        store.receive(try snapshot.applicationContext())
        store.receive([WatchDashboardSnapshot.applicationContextDataKey: Data("bad".utf8)])

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertNotNil(store.decodingError)
        let reloaded = WatchDashboardStore(defaults: defaults, session: nil)
        XCTAssertEqual(reloaded.snapshot, snapshot)
    }

    @MainActor
    func testActivationConsumesContextDeliveredBeforeFirstWatchLaunch() throws {
        let suiteName = "WatchDashboardStateTests.\(#function)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let store = WatchDashboardStore(defaults: defaults, session: nil)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let snapshot = WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: 300,
            accounts: [
                account(
                    id: "codex",
                    provider: "Codex",
                    metricID: "window",
                    fraction: 0.5,
                    generatedAt: now
                ),
            ]
        )

        store.activationCompleted(
            applicationContext: try snapshot.applicationContext(),
            isPhoneReachable: false,
            error: nil
        )

        XCTAssertEqual(store.snapshot, snapshot)
        XCTAssertFalse(store.isPhoneReachable)
        XCTAssertNil(store.decodingError)
    }

    private func account(
        id: String,
        provider: String,
        metricID: String,
        fraction: Double,
        generatedAt: Date,
        style: WatchMetricVisualizationStyle = .linearBar
    ) -> WatchAccountSnapshot {
        WatchAccountSnapshot(
            id: id,
            providerName: provider,
            accountLabel: "Primary",
            fetchedAt: generatedAt,
            metrics: [
                WatchMetricSnapshot(
                    id: metricID,
                    label: "Usage",
                    usedFraction: fraction,
                    remainingFraction: 1 - fraction,
                    exactValue: "\(Int((fraction * 100).rounded()))%",
                    visualizationStyle: style
                ),
            ]
        )
    }
}
