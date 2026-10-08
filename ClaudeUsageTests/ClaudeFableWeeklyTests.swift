import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeFableWeeklyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_448_800)
    private let reset = Date(timeIntervalSince1970: 1_894_060_800)

    func testReturnedFableAllowanceKeepsIndependentValuesAndProjection() throws {
        let result = try parse(limits: [limit(name: "Fable", percent: 21)])
        let fable = try XCTUnwrap(result.bars.first { $0.stableKey == "weekly-scoped-fable" })
        XCTAssertEqual(fable.label, "Fable weekly usage limit")
        XCTAssertEqual(fable.used, 21)
        XCTAssertEqual(fable.limit, 100)
        XCTAssertEqual(fable.resetsAt, reset)
        XCTAssertEqual(fable.projectionPeriodStart, reset.addingTimeInterval(-604_800))
        XCTAssertEqual(result.bars.first { $0.stableKey == "session" }?.used, 42)
        XCTAssertEqual(result.bars.first { $0.stableKey == "weekly-all" }?.used, 64)
        XCTAssertEqual(Set(result.availableMetrics.map(\.id)), ["claude.session", "claude.weekly-all", "claude.weekly-scoped-fable"])
        XCTAssertTrue(result.usageMessages.contains { $0.contains("within the all-model weekly allowance") })
    }

    func testKnownFamilyNamesKeepOneStableIdentity() throws {
        for name in ["Fable", "Fable 5", "Fable 5.1", "Claude Fable", "Claude Fable 5", "Claude Fable 5.1", " fAbLe 5.1 "] {
            let result = try parse(limits: [limit(name: name, percent: 21)])
            XCTAssertEqual(result.bars.filter { $0.stableKey?.hasPrefix("weekly-scoped-") == true }.map(\.stableKey),
                           ["weekly-scoped-fable"], name)
            XCTAssertEqual(result.availableMetrics.filter { $0.id.hasPrefix("claude.weekly-scoped-") }.map(\.id),
                           ["claude.weekly-scoped-fable"], name)
        }
    }

    func testInactiveEntriesRemainEnforceableAndActiveDuplicateWins() throws {
        let inactive = limit(name: "Fable 5", percent: 12, active: false)
        let active = limit(name: "Fable 5.1", percent: 21)
        let inactiveOnly = try parse(limits: [inactive])
        XCTAssertEqual(inactiveOnly.bars.first { $0.stableKey == "weekly-scoped-fable" }?.used, 12)
        for limits in [[inactive, active], [active, inactive]] {
            let result = try parse(limits: limits)
            let bars = result.bars.filter { $0.stableKey == "weekly-scoped-fable" }
            XCTAssertEqual(bars.count, 1)
            XCTAssertEqual(bars.first?.used, 21)
        }
    }

    func testAbsentUnknownAndCreditOnlyDataCannotInventFableQuota() throws {
        for plan in ["pro", "max_20x", "team_premium", "enterprise_premium", "unknown"] {
            let missing = try parse(limits: [], plan: plan)
            XCTAssertEqual(missing.bars.map(\.stableKey), ["session", "weekly-all"], plan)
            let credits = try parse(limits: [], plan: plan, extraUsage: true)
            XCTAssertFalse(credits.monetaryMetrics.isEmpty, plan)
            XCTAssertEqual(credits.bars.map(\.stableKey), ["session", "weekly-all"], plan)
        }
        let missingPercent = try parse(limits: [limit(name: "Fable", percent: nil)])
        XCTAssertFalse(missingPercent.bars.contains { $0.stableKey == "weekly-scoped-fable" })
        let zero = try parse(limits: [limit(name: "Fable", percent: 0)])
        XCTAssertEqual(zero.bars.first { $0.stableKey == "weekly-scoped-fable" }?.used, 0)
        let other = try parse(limits: [limit(name: "Fable Experimental", percent: 7)])
        XCTAssertEqual(other.bars.first?.stableKey, "weekly-scoped-fableexperimental")
    }

    func testMixedResponsesDoNotDuplicateSharedOrOtherModelWindows() throws {
        let limits: [[String: Any]] = [
            limit(name: "Fable", percent: 21), limit(name: "Fable 5.1", percent: 21),
            limit(name: "Sonnet", percent: 9), limit(name: "Opus", percent: 17),
            ["kind": "session", "percent": 42], ["kind": "weekly_all", "percent": 64],
        ]
        for ordered in [limits, Array(limits.reversed())] {
            let result = try parse(limits: ordered)
            XCTAssertEqual(Set(result.bars.compactMap(\.stableKey)),
                           ["session", "weekly-all", "weekly-scoped-fable", "sonnet-weekly-limit", "opus-weekly-limit"])
            XCTAssertEqual(result.bars.count, 5)
            XCTAssertEqual(result.bars.first { $0.stableKey == "weekly-scoped-fable" }?.used, 21)
        }
    }

    @MainActor
    func testSavedChoicesHistoryWidgetAndWatchKeepFableSeparateByAccount() throws {
        let suite = "ClaudeFableWeeklyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: FableFixtureSecretStore())
        let first = store.addAccount(for: .claude)
        let second = store.addAccount(for: .claude)
        XCTAssertTrue(store.saveSecret("synthetic", for: first))
        XCTAssertTrue(store.saveSecret("synthetic", for: second))
        let original = bound(try parse(limits: [limit(name: "Fable", percent: 21)]), to: first)
        let changedName = bound(try parse(limits: [limit(name: "Fable 5.1", percent: 21)]), to: first)
        let other = bound(try parse(limits: [limit(name: "Fable 5", percent: 7)]), to: second)
        let id = "claude.weekly-scoped-fable"
        _ = store.reconcileMetricLayout(accountID: first.id, availableMetricIDs: original.availableMetrics.map(\.id))
        store.updateMetricWidth(.full, accountID: first.id, metricID: id)
        store.updateVisualizationStyle(.circularRing, accountID: first.id, metricID: id)
        _ = store.reconcileMetricLayout(accountID: second.id, availableMetricIDs: other.availableMetrics.map(\.id))
        store.updateMetricVisibility(false, accountID: first.id, metricID: id)
        XCTAssertFalse(store.isMetricVisible(accountID: first.id, metricID: id))
        XCTAssertTrue(store.isMetricVisible(accountID: second.id, metricID: id))
        let layout = store.metricLayouts[first.id]
        _ = store.reconcileMetricLayout(accountID: first.id, availableMetricIDs: changedName.availableMetrics.map(\.id))
        XCTAssertEqual(store.metricLayouts[first.id], layout)
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: FableFixtureSecretStore())
        XCTAssertEqual(restored.metricLayouts[first.id], layout)
        XCTAssertFalse(restored.isMetricVisible(accountID: first.id, metricID: id))
        XCTAssertTrue(restored.isMetricVisible(accountID: second.id, metricID: id))
        restored.updateMetricVisibility(true, accountID: first.id, metricID: id)
        let shown = ProviderConfigurationStore(defaults: defaults, secretStore: FableFixtureSecretStore())
        XCTAssertTrue(shown.isMetricVisible(accountID: first.id, metricID: id))
        XCTAssertEqual(shown.metricLayouts[first.id]?.preferences[id]?.width, .full)
        XCTAssertEqual(shown.visualizationStyle(accountID: first.id, metricID: id), .circularRing)
        let history = UsageHistoryStore(defaults: defaults)
        history.record(results: [original, other], now: now)
        let snapshots = UsageHistoryStore(defaults: defaults).snapshots
        XCTAssertEqual(snapshots.count, 2)
        for (account, value) in [(first.id, 21.0), (second.id, 7.0)] {
            let snapshot = try XCTUnwrap(snapshots.first { $0.accountID == account })
            XCTAssertEqual(snapshot.bars.first { $0.stableKey == "weekly-scoped-fable" }?.used, value)
        }
        WidgetSnapshotPublisher.publish(results: [changedName, other], configurationStore: restored,
                                        snapshotDefaults: defaults, now: now)
        let widgets = WidgetSnapshotStore.loadSnapshot(defaults: defaults).results
        for (account, fraction) in [(first.id, 0.21), (second.id, 0.07)] {
            let widget = try XCTUnwrap(widgets.first { $0.accountID == account })
            let tile = try XCTUnwrap(widget.bars.first { $0.metricID == id })
            XCTAssertEqual(tile.fractionUsed, fraction)
            XCTAssertEqual(tile.label, "Fable weekly usage limit")
        }
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [changedName, other], configurationStore: restored, now: now)
        for (account, value) in [(first.id, "21%"), (second.id, "7%")] {
            let watchID = WatchSnapshotPublisher.snapshotAccountID(providerID: .claude, configurationID: account)
            let metric = try XCTUnwrap(watch.accounts.first { $0.id == watchID }?.metrics.first { $0.id == id })
            XCTAssertEqual(metric.exactValue, value)
            XCTAssertEqual(metric.resetsAt, reset)
        }
    }

    func testProviderDoesNotCarryFableAcrossAccountOrCredentialChanges() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FableAccountProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let first = ProviderAccountConfiguration(id: "fable-first", providerID: .claude, authMethod: .cliToken)
        let second = ProviderAccountConfiguration(id: "fable-second", providerID: .claude, authMethod: .cliToken)
        let secrets = FableAccountSecrets()
        secrets.set("fable-first-token", for: first)
        secrets.set("fable-second-token", for: second)
        let provider = ClaudeUsageProvider(secretStore: secrets, session: session)
        FableAccountProtocol.configure(token: "fable-first-token", status: 200,
                                       body: try providerBody(percent: 21))
        FableAccountProtocol.configure(token: "fable-second-token", status: 200,
                                       body: try providerBody(percent: nil))
        let initial = try await provider.fetchUsage(for: first)
        XCTAssertEqual(initial.accountID, first.id)
        XCTAssertEqual(initial.bars.first { $0.stableKey == "weekly-scoped-fable" }?.used, 21)
        let separate = try await provider.fetchUsage(for: second)
        XCTAssertEqual(separate.accountID, second.id)
        XCTAssertFalse(separate.bars.contains { $0.stableKey == "weekly-scoped-fable" })
        secrets.set("fable-changed-organization-token", for: first)
        FableAccountProtocol.configure(token: "fable-changed-organization-token", status: 503, body: "{}")
        let unavailable = try await provider.fetchUsage(for: first)
        XCTAssertNotNil(unavailable.failureMessage)
        XCTAssertTrue(unavailable.bars.isEmpty, "A changed credential must not retain the old organization's Fable allowance")
        FableAccountProtocol.configure(token: "fable-changed-organization-token", status: 200,
                                       body: try providerBody(percent: 7))
        let changed = try await provider.fetchUsage(for: first)
        XCTAssertEqual(changed.bars.first { $0.stableKey == "weekly-scoped-fable" }?.used, 7)
        FableAccountProtocol.configure(token: "fable-changed-organization-token", status: 200,
                                       body: try providerBody(percent: nil))
        let creditsOnly = try await provider.fetchUsage(for: first)
        XCTAssertFalse(creditsOnly.monetaryMetrics.isEmpty)
        XCTAssertFalse(creditsOnly.bars.contains { $0.stableKey == "weekly-scoped-fable" })
        XCTAssertEqual(creditsOnly.bars.first { $0.stableKey == "weekly-all" }?.used, 64)
    }

    private func providerBody(percent: Double?) throws -> String {
        let scoped = percent.map { [limit(name: "Fable 5.1", percent: $0)] } ?? []
        let object: [String: Any] = [
            "five_hour": ["utilization": 42], "seven_day": ["utilization": 64], "limits": scoped,
            "extra_usage": ["is_enabled": true, "monthly_limit": 5_000, "used_credits": 700],
        ]
        return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private func limit(name: String, percent: Double?, active: Bool = true) -> [String: Any] {
        [
            "kind": "weekly_scoped", "group": "weekly", "percent": percent.map { $0 as Any } ?? NSNull(),
            "resets_at": "2030-01-08T00:00:00Z", "is_active": active, "scope": ["model": ["display_name": name]],
        ]
    }

    private func parse(limits: [[String: Any]], plan: String = "max_20x", extraUsage: Bool = false) throws -> ProviderUsageResult {
        var object: [String: Any] = [
            "five_hour": ["utilization": 42, "resets_at": "2030-01-01T00:00:00Z"],
            "seven_day": ["utilization": 64, "resets_at": "2030-01-08T00:00:00Z"],
            "limits": limits,
        ]
        if extraUsage { object["extra_usage"] = ["is_enabled": true, "monthly_limit": 5_000, "used_credits": 700] }
        return try XCTUnwrap(ClaudeUsageParser.parse(JSONSerialization.data(withJSONObject: object), subscriptionType: plan, fetchedAt: now))
    }

    func testOlderFableChoicesMigrateWithoutOverwritingCanonicalChoices() throws {
        let canonical = "claude.weekly-scoped-fable"
        let preference = MetricTilePreference(isVisible: false, visualizationStyle: .circularRing,
                                             width: .full, watchVisibility: .show, isNewlyDiscovered: false)
        for stableKey in [
            "weekly-scoped-fable5", "weekly-scoped-fable51", "weekly-scoped-claudefable",
            "weekly-scoped-claudefable5", "weekly-scoped-claudefable51",
        ] {
            let legacy = "claude.\(stableKey)"
            var layout = AccountMetricLayout(orderedMetricIDs: ["claude.session", legacy, "claude.weekly-all"],
                                             preferences: [legacy: preference], hasCustomMetricOrder: true)
            ClaudeFableMetricPreferenceCompatibility.migrate(layout: &layout, availableMetricIDs: [canonical, "claude.session"])
            XCTAssertEqual(layout.preferences[canonical], preference, legacy)
            XCTAssertNil(layout.preferences[legacy], legacy)
            XCTAssertEqual(layout.orderedMetricIDs, ["claude.session", canonical, "claude.weekly-all"])
            XCTAssertTrue(layout.hasCustomMetricOrder)
            let migrated = layout
            ClaudeFableMetricPreferenceCompatibility.migrate(layout: &layout, availableMetricIDs: [canonical])
            XCTAssertEqual(layout, migrated, "Migration must be idempotent")
            XCTAssertEqual(try JSONDecoder().decode(AccountMetricLayout.self, from: JSONEncoder().encode(layout)), migrated)
        }
        let legacy = "claude.weekly-scoped-fable5"
        let canonicalChoice = MetricTilePreference(isNewlyDiscovered: false)
        var existing = AccountMetricLayout(orderedMetricIDs: [legacy, "claude.session", canonical],
                                          preferences: [legacy: preference, canonical: canonicalChoice])
        ClaudeFableMetricPreferenceCompatibility.migrate(layout: &existing, availableMetricIDs: [canonical])
        XCTAssertEqual(existing.preferences[canonical], canonicalChoice, "An explicit canonical choice takes precedence")
        XCTAssertEqual(existing.orderedMetricIDs, ["claude.session", canonical])
        var absent = AccountMetricLayout(orderedMetricIDs: [legacy], preferences: [legacy: preference])
        let original = absent
        ClaudeFableMetricPreferenceCompatibility.migrate(layout: &absent, availableMetricIDs: ["claude.weekly-all"])
        XCTAssertEqual(absent, original, "Missing provider data must not migrate or discard choices")
        ClaudeFableMetricPreferenceCompatibility.migrate(layout: &absent, availableMetricIDs: [canonical, legacy])
        XCTAssertEqual(absent, original, "Do not merge identities still returned as distinct metrics")
        let newerLegacy = "claude.weekly-scoped-fable51"
        var duplicate = AccountMetricLayout(orderedMetricIDs: [legacy, "claude.session", newerLegacy, canonical],
                                           preferences: [legacy: MetricTilePreference(), newerLegacy: preference,
                                                         canonical: MetricTilePreference(),
                                           ])
        ClaudeFableMetricPreferenceCompatibility.migrate(layout: &duplicate, availableMetricIDs: [canonical])
        XCTAssertEqual(duplicate.preferences[canonical], preference, "Retain the customized alias rather than a default duplicate")
        XCTAssertEqual(duplicate.orderedMetricIDs, [canonical, "claude.session"],
                       "A default discovered canonical entry must retain the older chosen position")
    }

    @MainActor
    func testDailyHistoryKeepsOldFableAliasesInOneComponent() throws {
        for stableKey in [
            "weekly-scoped-fable5", "weekly-scoped-fable51", "weekly-scoped-claudefable",
            "weekly-scoped-claudefable5", "weekly-scoped-claudefable51",
        ] {
            let suite = "ClaudeFableLegacyHistory.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let history = UsageHistoryStore(defaults: defaults)
            let account = ProviderAccountConfiguration(id: "legacy-fable", providerID: .claude,
                                                       accountLabel: "Synthetic", authMethod: .browserSession)
            let older = ProviderUsageResult(accountID: account.id, providerID: .claude, title: account.displayName,
                                            subtitle: "Synthetic", bars: [UsageBar(stableKey: stableKey, label: "Fable 5 weekly usage limit",
                                                used: 12, limit: 100, resetsAt: reset),
                                            ], fetchedAt: now)
            history.record(results: [older], now: now)
            let parsed = try parse(limits: [limit(name: "Fable 5.1", percent: 21)])
            let current = ProviderUsageResult(accountID: account.id, providerID: .claude, title: account.displayName,
                                              subtitle: "Synthetic", bars: parsed.bars, fetchedAt: now.addingTimeInterval(60))
            history.record(results: [current], now: now.addingTimeInterval(60))
            let dailyFable = history.dailySnapshots.filter {
                $0.bars.contains { ["weekly-scoped-fable", stableKey].contains($0.stableKey ?? "") }
            }
            XCTAssertEqual(dailyFable.count, 1, stableKey)
            XCTAssertEqual(dailyFable.first?.bars.first?.used, 21)
            XCTAssertEqual(history.snapshots.count, 2, "Retain original historical samples")
            XCTAssertEqual(UsageHistoryStore(defaults: defaults).dailySnapshots, history.dailySnapshots)
        }
    }

    private func bound(_ result: ProviderUsageResult, to account: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(accountID: account.id, providerID: .claude, title: account.displayName,
                            subtitle: result.subtitle, bars: result.bars, fetchedAt: now)
    }
}

private struct FableFixtureSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? { "synthetic" }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}

private final class FableAccountSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func set(_ token: String, for account: ProviderAccountConfiguration) {
        lock.withLock { values[ProviderConfigurationStore.keychainAccount(for: account)] = token }
    }
    func readSecret(account: String) throws -> String? { lock.withLock { values[account] } }
    func saveSecret(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func deleteSecret(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

private class FableAccountProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (Int, String)] = [:]
    static func configure(token: String, status: Int, body: String) {
        lock.withLock { responses["Bearer " + token] = (status, body) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let result = Self.lock.withLock { Self.responses[request.value(forHTTPHeaderField: "Authorization") ?? ""] ?? (403, "{}") }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
