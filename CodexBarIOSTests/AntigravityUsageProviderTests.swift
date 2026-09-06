import XCTest
@testable import CodexBarIOS

final class AntigravityUsageProviderTests: XCTestCase {
    private static let configuration = ProviderAccountConfiguration(
        id: "antigravity-test", providerID: .antigravity, authMethod: .cliToken
    )
    private static let now = Date(timeIntervalSince1970: 1_788_640_000)

    func testFourIndependentBucketsConvertRemainingExactlyOnce() throws {
        let result = try Self.result(Self.payload())
        XCTAssertEqual(result.providerID, .antigravity)
        XCTAssertEqual(result.bars.map(\.stableKey), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(result.bars.map(\.usageText), ["100%", "31%", "20%", "60%"])
        XCTAssertEqual(result.bars[1].used, 31, accuracy: 0.000_001)
        XCTAssertEqual(result.bars[0].severity, .critical)
        XCTAssertEqual(result.bars[1].resetsAt, AntigravityQuotaParser.date("2030-09-11T16:22:20Z"))
        XCTAssertNil(result.failureMessage)
    }

    func testMissingDisabledDuplicateAndInvalidBucketsStayUnavailable() throws {
        let invalid: [Any] = [NSNull(), -0.1, 1.1]
        for fraction in invalid {
            var buckets = Self.buckets()
            buckets[0]["remainingFraction"] = fraction
            let result = try Self.result(Self.payload(buckets))
            XCTAssertEqual(result.bars.count, 3)
            XCTAssertFalse(result.bars.contains { $0.stableKey == "gemini-5h" })
            XCTAssertEqual(result.usageMessages, ["Unavailable: Gemini Models five-hour."])
        }
        for mutation in ["disabled", "window", "resetTime", "duplicate", "missing"] {
            var buckets = Self.buckets()
            switch mutation {
            case "disabled": buckets[0]["disabled"] = true
            case "window": buckets[0]["window"] = "weekly"
            case "resetTime": buckets[0]["resetTime"] = "2020-01-01T00:00:00Z"
            case "duplicate": buckets.append(buckets[0])
            default: buckets.removeFirst()
            }
            XCTAssertEqual(try Self.result(Self.payload(buckets)).bars.count, 3)
        }
    }

    func testEmptyWrongShapeAndNonNumericFractionsCannotBecomeZeroUsage() throws {
        let empty = try Self.result(Self.payload([]))
        XCTAssertNotNil(empty.failureMessage)
        XCTAssertTrue(empty.bars.isEmpty)
        for data in [Data("{}".utf8), Data("not JSON".utf8)] {
            XCTAssertThrowsError(try Self.result(data))
        }
        let nonNumbers: [Any] = [true, "0.69"]
        for invalid in nonNumbers {
            var buckets = Self.buckets()
            buckets[0]["remainingFraction"] = invalid
            XCTAssertThrowsError(try Self.result(Self.payload(buckets)))
        }
    }

    func testResetMayBeAbsentButMalformedResetMakesBucketUnavailable() throws {
        var buckets = Self.buckets()
        buckets[0].removeValue(forKey: "resetTime")
        XCTAssertNil(try Self.result(Self.payload(buckets)).bars.first?.resetsAt)
        buckets[0]["resetTime"] = "not a date"
        XCTAssertEqual(try Self.result(Self.payload(buckets)).bars.count, 3)
        XCTAssertNotNil(AntigravityQuotaParser.date("2030-09-11T16:22:20.123Z"))
    }

    func testCredentialImportNormalizesFlatAndCLIProfiles() throws {
        let flat = try AntigravityCredentials.parse(#"{"access_token":"token","refresh_token":"refresh","client_id":"client","client_secret":"secret","expiry_date":1900000000000,"email":"discard"}"#)
        XCTAssertTrue(flat.canRefresh)
        XCTAssertEqual(try AntigravityCredentials.parse(flat.encoded()), flat)
        XCTAssertFalse(try flat.encoded().contains("discard"))
        let nested = try AntigravityCredentials.parse(#"{"token":{"access_token":"token","expiry":"2030-01-01T00:00:00Z"},"auth_method":"discard"}"#)
        XCTAssertEqual(nested.accessToken, "token")
        XCTAssertFalse(nested.canRefresh)
        XCTAssertNotNil(nested.expiry)
    }

    func testInvalidCredentialFieldsAreRejected() {
        for json in [
            "[]", "{}", #"{"access_token":true}"#, #"{"access_token":""}"#,
            #"{"access_token":"a\nb"}"#, #"{"access_token":"token","expiry":"bad"}"#,
            #"{"access_token":"token","expiry_date":true}"#,
            #"{"access_token":"token","expiry_date":-1}"#,
            #"{"access_token":"token","client_id":12}"#,
        ] {
            XCTAssertThrowsError(try AntigravityCredentials.parse(json))
        }
        XCTAssertNil(try? AntigravityCredentials.parse("not JSON"))
    }

    func testNullExpiryFallsBackToMillisecondsOrRemainsAbsent() throws {
        let fallback = try AntigravityCredentials.parse(#"{"access_token":"token","expiry":null,"expiry_date":1900000000000}"#)
        XCTAssertEqual(fallback.expiry, Date(timeIntervalSince1970: 1_900_000_000))
        let missing = try AntigravityCredentials.parse(#"{"access_token":"token","expiry":null,"expiry_date":null}"#)
        XCTAssertNil(missing.expiry)
    }

    func testRejectedTokenWithoutExpiryRenewsOnce() async throws {
        let secrets = MemorySecretStore()
        let account = ProviderConfigurationStore.keychainAccount(for: Self.configuration)
        var imported = try AntigravityCredentials.parse(Self.expiredCredential)
        imported.expiry = nil
        let original = try imported.encoded()
        try secrets.saveSecret(original, account: account)
        let rejected = LockedFlag()
        let fixture = IsolatedTestURLSession { request in
            if request.url == AntigravityUsageProvider.tokenURL {
                XCTAssertTrue(rejected.currentValue())
                return (try Self.response(request, status: 200), Data(#"{"access_token":"renewed","expires_in":3600}"#.utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                rejected.set()
                return (try Self.response(request, status: 401), Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(rejected.currentValue())
    }

    func testRequestUsesVerifiedBackendAndOnlyThisAccountsToken() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"account-one"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url, AntigravityUsageProvider.quotaURL)
            XCTAssertEqual(request.url?.host, "daily-cloudcode-pa.googleapis.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-one")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertEqual(result.bars.count, 4)
        XCTAssertEqual(result.accountID, Self.configuration.id)
        let other = ProviderAccountConfiguration(id: "other", providerID: .antigravity, authMethod: .cliToken)
        let missing = try await provider.fetchUsage(for: other)
        XCTAssertNotNil(missing.failureMessage)
        XCTAssertTrue(missing.bars.isEmpty)
    }

    func testExpiredCredentialRenewsAndPersistsOnlyItsOwnAccount() async throws {
        let secrets = MemorySecretStore()
        let account = ProviderConfigurationStore.keychainAccount(for: Self.configuration)
        try secrets.saveSecret(Self.expiredCredential, account: account)
        let fixture = IsolatedTestURLSession { request in
            if request.url == AntigravityUsageProvider.tokenURL {
                let body = String(bytes: requestBodyData(from: request) ?? Data(), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("client_secret=secret%2Bvalue"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (try Self.response(request, status: 200), Data(#"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
            return (try Self.response(request, status: 200), try Self.payload())
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertNil(result.failureMessage)
        let saved = try AntigravityCredentials.parse(XCTUnwrap(secrets.readSecret(account: account)))
        XCTAssertEqual(saved.accessToken, "renewed")
        XCTAssertEqual(saved.refreshToken, "rotated")
        XCTAssertGreaterThan(try XCTUnwrap(saved.expiry), Date())
    }

    func testRenewalCannotRestoreDisconnectedCredential() async throws {
        let secrets = MemorySecretStore()
        let account = ProviderConfigurationStore.keychainAccount(for: Self.configuration)
        try secrets.saveSecret(Self.expiredCredential, account: account)
        let fixture = IsolatedTestURLSession { request in
            XCTAssertEqual(request.url, AntigravityUsageProvider.tokenURL)
            try secrets.deleteSecret(account: account)
            return (try Self.response(request, status: 200), Data(#"{"access_token":"late","expires_in":3600}"#.utf8))
        }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        let result = try await provider.fetchUsage(for: Self.configuration)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertNil(try secrets.readSecret(account: account))
    }

    func testHTTPAndMalformedFailuresNeverInventUsageOrLeakResponse() async throws {
        for status in [302, 400, 401, 403, 429, 500, 200] {
            let secrets = MemorySecretStore()
            try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
            let fixture = IsolatedTestURLSession { request in
                (try Self.response(request, status: status), Data("secret-response-body".utf8))
            }
            defer { fixture.invalidate() }
            let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
            let result = try await provider.fetchUsage(for: Self.configuration)
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertNotNil(result.failureMessage)
            XCTAssertFalse(result.failureMessage?.contains("secret-response-body") == true)
        }
    }

    func testCancellationPropagates() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let fixture = IsolatedTestURLSession { _ in throw URLError(.cancelled) }
        defer { fixture.invalidate() }
        let provider = AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)
        do {
            _ = try await provider.fetchUsage(for: Self.configuration)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    @MainActor
    func testAccountSettingsHistoryWidgetsAndWatchKeepMetricIdentity() throws {
        let suite = "AntigravityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let gemini = store.addAccount(for: .gemini)
        let account = store.addAccount(for: .antigravity)
        let other = store.addAccount(for: .antigravity)
        XCTAssertEqual(account.authMethod, .cliToken)
        XCTAssertTrue(account.requiresSecret)
        XCTAssertFalse(store.shouldDisplayOnDashboard(account))
        XCTAssertTrue(store.saveSecret(#"{"access_token":"test"}"#, for: account))
        XCTAssertTrue(store.shouldDisplayOnDashboard(account))
        XCTAssertFalse(store.hasSecret(for: other))
        XCTAssertFalse(store.hasSecret(for: gemini))
        let result = try AntigravityQuotaParser.result(from: Self.payload(), configuration: account, fetchedAt: Self.now)
        let expected = AntigravityQuotaParser.metrics.map { "antigravity.\($0.key)" }
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, snapshotDefaults: defaults)
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(snapshot.results.first?.bars.map(\.metricID), expected)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: Self.now)
        XCTAssertEqual(watch.accounts.first?.metrics.map(\.id), expected)
        let history = UsageHistoryStore(defaults: defaults)
        history.record(results: [result], now: Self.now)
        XCTAssertEqual(history.snapshots(for: account.id).count, 1)
        XCTAssertTrue(history.snapshots(for: gemini.id).isEmpty)
        let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
        XCTAssertEqual(model.availableAuthMethods, [.cliToken])
        XCTAssertEqual(model.credentialPresentation.sectionTitle, "Antigravity Session Import")
        model.secret = "not JSON"
        model.saveGenericCredential()
        XCTAssertNotNil(model.credentialError)
        model.secret = #"{"access_token":"replacement"}"#
        model.saveGenericCredential()
        XCTAssertNil(model.credentialError)
        XCTAssertEqual(model.secret, "")
    }

    @MainActor
    func testScreenshotFixtureIncludesAllAntigravityBuckets() {
        let store = ProviderConfigurationStore.appStoreScreenshotDemo()
        let results = AppStoreScreenshotFixtures.results(for: store)
        XCTAssertEqual(
            results.first { $0.providerID == .antigravity }?.bars.map(\.stableKey),
            ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
        )
    }

    @MainActor
    func testAllSixMetricChoicesExistBeforeCredentialsOrResults() throws {
        let suite = "GoogleMetricChoices.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let apps = store.addAccount(for: .gemini)
        let coding = store.addAccount(for: .antigravity)
        let appsModel = ProviderSettingsViewModel(configurationStore: store, accountID: apps.id)
        let codingModel = ProviderSettingsViewModel(configurationStore: store, accountID: coding.id)
        let metrics = appsModel.availableMetrics + codingModel.availableMetrics
        XCTAssertEqual(metrics.map(\.id), [
            "gemini.five-hour", "gemini.weekly", "antigravity.gemini-5h",
            "antigravity.gemini-weekly", "antigravity.3p-5h", "antigravity.3p-weekly",
        ])
        XCTAssertTrue(metrics.allSatisfy { $0.kind == .unavailableUsage("Setup required") })
        XCTAssertNotNil(GoogleUsageMetricCatalog.setupDescription(for: .gemini))
        XCTAssertNotNil(GoogleUsageMetricCatalog.setupDescription(for: .antigravity))
        XCTAssertNil(GoogleUsageMetricCatalog.setupDescription(for: .codex))
    }

    func testMissingDisabledAndZeroHaveDistinctConfigurableStates() throws {
        var buckets = Self.buckets()
        buckets[0]["remainingFraction"] = 1.0
        buckets[1].removeValue(forKey: "remainingFraction")
        buckets[2]["disabled"] = true
        let result = try Self.result(Self.payload(buckets))
        XCTAssertEqual(result.availableMetrics.count, 2)
        XCTAssertEqual(result.configurableMetrics.count, 4)
        XCTAssertEqual(result.bars.first?.usageText, "0%")
        XCTAssertEqual(result.configurableMetrics[0].kind, .usageBar(index: 0))
        XCTAssertEqual(result.configurableMetrics[1].kind, .unavailableUsage("Unavailable"))
        XCTAssertEqual(result.configurableMetrics[2].kind, .unavailableUsage("Disabled"))
        XCTAssertEqual(result.configurableMetrics[3].kind, .usageBar(index: 1))
        XCTAssertEqual(result.bars[1].usageText, "60%")
        XCTAssertEqual(ProviderUsageCard.menuActions(for: try Self.result(Self.payload([]))), [
            .configureAccount, .customizeMetrics,
        ])
    }

    @MainActor
    func testGoogleChoicesPreserveIndependentLayoutThroughMissingResultsAndRelaunch() throws {
        let suite = "GoogleMetricPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let apps = store.addAccount(for: .gemini)
        let account = store.addAccount(for: .antigravity)
        let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
        let ids = model.availableMetrics.map(\.id)
        store.reconcileMetricLayout(accountID: account.id, availableMetricIDs: ids)
        model.setMetricVisibility(false, metricID: ids[1])
        store.updateMetricWidth(.half, accountID: account.id, metricID: ids[1])
        store.updateVisualizationStyle(.circularRing, accountID: account.id, metricID: ids[1])
        store.updateMetricOrder(Array(ids.reversed()), accountID: account.id)
        let layout = store.metricLayouts[account.id]
        let missing = try AntigravityQuotaParser.result(from: Self.payload([]), configuration: account, fetchedAt: Self.now)
        model.synchronizeUsageResult(missing)
        XCTAssertEqual(model.availableMetrics.map(\.id), ids)
        XCTAssertEqual(store.metricLayouts[account.id], layout)
        model.synchronizeUsageResult(nil)
        XCTAssertEqual(model.availableMetrics.count, 4)
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.metricLayouts[account.id], layout)
        XCTAssertFalse(restored.isMetricVisible(accountID: account.id, metricID: ids[1]))
        XCTAssertTrue(restored.isMetricVisible(accountID: account.id, metricID: ids[0]))
        XCTAssertTrue(restored.isMetricVisible(accountID: apps.id, metricID: "gemini.weekly"))
        XCTAssertEqual(restored.metricWidth(accountID: account.id, metricID: ids[1]), .half)
        XCTAssertEqual(restored.visualizationStyle(accountID: account.id, metricID: ids[1]), .circularRing)
        XCTAssertEqual(restored.visualizationStyle(accountID: account.id, metricID: ids[0]), .linearBar)
        let recovered = try AntigravityQuotaParser.result(from: Self.payload(), configuration: account, fetchedAt: Self.now)
        model.synchronizeUsageResult(recovered)
        XCTAssertEqual(model.availableMetrics.map(\.id), ids)
        XCTAssertEqual(store.metricLayouts[account.id], layout)
    }

    @MainActor
    func testUnavailableResponseKeepsObservedQuotasAsLastKnownData() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let fixture = IsolatedTestURLSession { request in
            (try Self.response(request, status: 200), try Self.payload([]))
        }
        defer { fixture.invalidate() }
        var buckets = Array(Self.buckets().prefix(2))
        buckets[0]["remainingFraction"] = 1.0
        let initial = try Self.result(Self.payload(buckets))
        let service = UsageRefreshService(
            providers: [AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)],
            initialResults: [initial]
        )
        await service.refresh(configurations: [Self.configuration])
        let result = try XCTUnwrap(service.results.first)
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.subtitle.contains("Showing last known data"))
        XCTAssertEqual(result.bars, initial.bars)
        XCTAssertEqual(result.barsFetchedAt, initial.barsFetchedAt)
        XCTAssertEqual(result.bars.map(\.usageText), ["0%", "31%"])
        XCTAssertEqual(result.configurableMetrics.map(\.kind), [
            .usageBar(index: 0), .usageBar(index: 1),
            .unavailableUsage("Unavailable"), .unavailableUsage("Unavailable"),
        ])
    }

    @MainActor
    func testExplicitlyDisabledBucketsOverrideCachedValuesWithoutLosingHistory() async throws {
        let suite = "DisabledQuotaConsumers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let account = store.addAccount(for: .antigravity)
        XCTAssertTrue(store.saveSecret(#"{"access_token":"test"}"#, for: account))
        let fixture = IsolatedTestURLSession { request in
            let disabled = Self.buckets().map { bucket in
                var bucket = bucket
                bucket["disabled"] = true
                return bucket
            }
            return (try Self.response(request, status: 200), try Self.payload(disabled))
        }
        defer { fixture.invalidate() }
        let initial = try AntigravityQuotaParser.result(from: Self.payload(), configuration: account, fetchedAt: Self.now)
        let history = UsageHistoryStore(defaults: defaults)
        history.record(results: [initial], now: Self.now)
        let savedHistory = history.snapshots(for: account.id)
        let expectedIDs = initial.availableMetrics.map(\.id)
        assertQuotaConsumers(initial, store: store, defaults: defaults, expectedIDs: expectedIDs, severity: .critical)
        let service = UsageRefreshService(
            providers: [AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)],
            initialResults: [initial]
        )
        await service.refresh(configurations: [account])
        let result = try XCTUnwrap(service.results.first)
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertEqual(result.bars, initial.bars)
        XCTAssertEqual(result.barsFetchedAt, initial.barsFetchedAt)
        XCTAssertEqual(result.configurableMetrics.map(\.id), initial.configurableMetrics.map(\.id))
        XCTAssertTrue(result.configurableMetrics.allSatisfy { $0.kind == .unavailableUsage("Disabled") })
        XCTAssertTrue(result.hasSuccessfulRefreshHistory)
        XCTAssertTrue(result.freshBars.isEmpty)
        assertQuotaConsumers(result, store: store, defaults: defaults, expectedIDs: [], severity: .normal)
        history.record(results: [result], now: Self.now.addingTimeInterval(600))
        XCTAssertEqual(history.snapshots(for: account.id).map(\.bars), savedHistory.map(\.bars))
        XCTAssertEqual(history.snapshots(for: account.id).map(\.capturedAt), savedHistory.map(\.capturedAt))
        assertQuotaConsumers(initial, store: store, defaults: defaults, expectedIDs: expectedIDs, severity: .critical)
    }

    @MainActor
    func testDisabledCachedBucketKeepsOtherMetricIndicesAndUnavailableObservations() throws {
        let suite = "MixedQuotaConsumers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let account = store.addAccount(for: .antigravity)
        XCTAssertTrue(store.saveSecret(#"{"access_token":"test"}"#, for: account))
        let initial = try AntigravityQuotaParser.result(from: Self.payload(), configuration: account, fetchedAt: Self.now)
        let result = ProviderUsageResult(
            accountID: account.id, providerID: .antigravity, title: initial.title, subtitle: "",
            bars: initial.bars,
            unavailableUsageMetrics: ["antigravity.gemini-5h": "Disabled", "antigravity.gemini-weekly": "Unavailable"],
            fetchedAt: Self.now
        )
        let expectedIDs = Array(initial.availableMetrics.map(\.id).dropFirst())
        XCTAssertEqual(result.enabledBarIndices, [1, 2, 3])
        XCTAssertEqual(result.availableMetrics.map(\.id), expectedIDs)
        XCTAssertEqual(result.freshBars.map(\.stableKey), ["gemini-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(result.configurableMetrics.map(\.kind), [
            .unavailableUsage("Disabled"), .usageBar(index: 1), .usageBar(index: 2), .usageBar(index: 3),
        ])
        assertQuotaConsumers(result, store: store, defaults: defaults, expectedIDs: expectedIDs, severity: .normal)
    }

    @MainActor
    private func assertQuotaConsumers(
        _ result: ProviderUsageResult,
        store: ProviderConfigurationStore,
        defaults: UserDefaults,
        expectedIDs: [String],
        severity: UsageSeverity
    ) {
        XCTAssertEqual(result.highestSeverity(at: Self.now), severity)
        let alerts = UsageAlertEvaluator.evaluate(
            results: [result], settings: UsageAlertSettings(isEnabled: true), activeAlertIDs: [], now: Self.now
        )
        XCTAssertEqual(alerts.notifications.isEmpty, severity == .normal)
        XCTAssertEqual(alerts.activeAlerts.isEmpty, severity == .normal)
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, snapshotDefaults: defaults, now: Self.now)
        XCTAssertEqual(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.map(\.metricID), expectedIDs)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: Self.now)
        XCTAssertEqual(watch.accounts.first?.metrics.map(\.id), expectedIDs)
    }

    @MainActor
    func testCopyLayoutIncludesMissingDisabledAndUnfetchedGoogleQuotas() throws {
        let suite = "GoogleCopyLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let source = store.addAccount(for: .antigravity)
        let destination = store.addAccount(for: .antigravity)
        let result = try AntigravityQuotaParser.result(from: Self.payload(), configuration: source, fetchedAt: Self.now)
        let ids = result.configurableMetrics.map(\.id)
        store.reconcileMetricLayout(accountID: source.id, availableMetricIDs: ids)
        store.updateMetricVisibility(false, accountID: source.id, metricID: ids[1])
        store.updateMetricWidth(.half, accountID: source.id, metricID: ids[1])
        store.updateVisualizationStyle(.circularRing, accountID: source.id, metricID: ids[1])
        store.updateMetricOrder(Array(ids.reversed()), accountID: source.id)
        var partial = Self.buckets()
        partial[1]["disabled"] = true
        for payload in [nil, try Self.payload([]), try Self.payload(partial)] {
            let observed = try payload.map { try AntigravityQuotaParser.result(from: $0, configuration: destination, fetchedAt: Self.now) }
            let item = DashboardProviderCardItem(configuration: destination, result: observed, isRefreshing: false, errorMessage: nil)
            let copy = try XCTUnwrap(ContentView.metricLayoutCopyDestination(item, from: result, configurationStore: store))
            XCTAssertEqual(copy.availableMetricIDs, ids)
            store.copyMetricLayout(from: source.id, to: copy.id, destinationAvailableMetricIDs: copy.availableMetricIDs)
            XCTAssertEqual(store.metricLayouts[destination.id]?.orderedMetricIDs, Array(ids.reversed()))
            XCTAssertFalse(store.isMetricVisible(accountID: destination.id, metricID: ids[1]))
            XCTAssertEqual(store.metricWidth(accountID: destination.id, metricID: ids[1]), .half)
            XCTAssertEqual(store.visualizationStyle(accountID: destination.id, metricID: ids[1]), .circularRing)
        }
        let sameAccount = DashboardProviderCardItem(configuration: source, result: result, isRefreshing: false, errorMessage: nil)
        XCTAssertNil(ContentView.metricLayoutCopyDestination(sameAccount, from: result, configurationStore: store))
        let apps = DashboardProviderCardItem(configuration: store.addAccount(for: .gemini), result: nil, isRefreshing: false, errorMessage: nil)
        XCTAssertNil(ContentView.metricLayoutCopyDestination(apps, from: result, configurationStore: store))
    }

    func testCatalogKeepsOtherProvidersAndRejectsWrongSourceResults() {
        let other = ProviderUsageResult(providerID: .openRouter, title: "Other", subtitle: "", bars: [], creditsRemaining: 12, fetchedAt: Self.now)
        XCTAssertEqual(other.configurableMetrics, other.availableMetrics)
        XCTAssertTrue(GoogleUsageMetricCatalog.metrics(for: .gemini, result: other).allSatisfy {
            $0.kind == .unavailableUsage("Setup required")
        })
    }

    @MainActor
    func testGeminiOnlyDashboardIncludesCodingSetupWithoutChangingAccounts() async throws {
        let suite = "GoogleDashboard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let apps = store.addAccount(for: .gemini)
        XCTAssertTrue(store.saveSecret("apps-session", for: apps))
        let observed = ProviderUsageResult(
            accountID: apps.id, providerID: .gemini, title: apps.displayName, subtitle: "Gemini Apps usage",
            bars: [
                UsageBar(stableKey: "five-hour", label: "Five-hour", used: 12, limit: 100),
                UsageBar(stableKey: "weekly", label: "Weekly", used: 45, limit: 100, resetsAt: Self.now.addingTimeInterval(3600)),
            ], fetchedAt: Self.now
        )
        let service = UsageRefreshService(providers: [], initialResults: [observed])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        let coding = try XCTUnwrap(dashboard.dashboardCardItems.first { $0.configuration.providerID == .antigravity })
        let result = try XCTUnwrap(coding.result)
        let ids = AntigravityQuotaParser.metrics.map { "antigravity.\($0.key)" }

        XCTAssertEqual(dashboard.dashboardCardItems.flatMap { $0.result?.configurableMetrics ?? [] }.count, 6)
        XCTAssertEqual(result.configurableMetrics.map(\.id), ids)
        XCTAssertTrue(result.configurableMetrics.allSatisfy { $0.kind == .unavailableUsage("Setup required") })
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertFalse(result.hasSuccessfulRefreshHistory)
        XCTAssertEqual(coding.recoveryAction, .signIn)
        XCTAssertEqual(store.configurations, [apps])
        XCTAssertEqual(service.results, [observed])
        XCTAssertEqual(dashboard.dashboardCardItems.first { $0.id == apps.id }?.result, observed)

        store.reconcileMetricLayout(accountID: coding.id, availableMetricIDs: ids)
        store.updateMetricVisibility(false, accountID: coding.id, metricID: ids[1])
        store.updateMetricWidth(.half, accountID: coding.id, metricID: ids[1])
        store.updateVisualizationStyle(.circularRing, accountID: coding.id, metricID: ids[1])
        store.updateMetricOrder(Array(ids.reversed()), accountID: coding.id)
        let layout = store.metricLayouts[coding.id]
        await service.refresh(configurations: store.configurations)
        XCTAssertEqual(dashboard.dashboardCardItems.first { $0.id == coding.id }?.result, result)
        XCTAssertEqual(store.metricLayouts[coding.id], layout)

        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let relaunched = googleDashboard(store: restored, service: service, defaults: defaults)
        XCTAssertEqual(restored.configurations, [apps])
        XCTAssertEqual(relaunched.dashboardCardItems.first { $0.id == coding.id }?.result, result)
        XCTAssertEqual(restored.metricLayouts[coding.id], layout)
        XCTAssertFalse(restored.isMetricVisible(accountID: coding.id, metricID: ids[1]))
        restored.updateMetricVisibility(true, accountID: coding.id, metricID: ids[1])
        XCTAssertTrue(ids.allSatisfy { restored.isMetricVisible(accountID: coding.id, metricID: $0) })

        let promoted = try XCTUnwrap(restored.prepareDashboardAccountForSetup(coding.configuration))
        XCTAssertEqual(promoted.id, coding.id)
        XCTAssertEqual(restored.configurations.count, 2)
        XCTAssertFalse(restored.hasSecret(for: promoted))
        XCTAssertEqual(restored.metricWidth(accountID: coding.id, metricID: ids[1]), .half)
        XCTAssertEqual(restored.metricOrder(accountID: coding.id, availableMetricIDs: ids), Array(ids.reversed()))
        XCTAssertEqual(restored.visualizationStyle(accountID: coding.id, metricID: ids[1]), .circularRing)
        XCTAssertEqual(relaunched.dashboardCardItems.filter { $0.configuration.providerID == .antigravity }.count, 1)
    }

    @MainActor
    func testIncompleteAndDisabledGoogleAccountsKeepExplicitDashboardChoices() throws {
        let suite = "GoogleDashboard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore(), widgetSnapshotDefaults: defaults)
        let apps = store.addAccount(for: .gemini)
        var coding = store.addAccount(for: .antigravity)
        let service = UsageRefreshService(providers: [])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        XCTAssertEqual(Set(dashboard.dashboardCardItems.map(\.id)), [apps.id, coding.id])
        XCTAssertEqual(dashboard.dashboardCardItems.flatMap { $0.result?.configurableMetrics ?? [] }.count, 6)
        XCTAssertTrue(dashboard.dashboardCardItems.allSatisfy {
            $0.result?.configurableMetrics.allSatisfy { $0.kind == .unavailableUsage("Setup required") } == true
        })
        coding.isEnabled = false
        XCTAssertTrue(store.update(coding))
        XCTAssertEqual(dashboard.dashboardCardItems.map(\.id), [apps.id])
        XCTAssertTrue(GoogleUsageMetricCatalog.missingSourceConfigurations(in: store.configurations).isEmpty)
        let secondApps = store.addAccount(for: .gemini)
        XCTAssertEqual(Set(dashboard.dashboardCardItems.map(\.id)), [apps.id, secondApps.id])
    }

    @MainActor
    func testUnconfiguredGoogleCachedValuesStayOutOfWidgetAndWatchSnapshots() throws {
        let suite = "GoogleSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore(), widgetSnapshotDefaults: defaults)
        let apps = store.addAccount(for: .gemini)
        let coding = store.addAccount(for: .antigravity)
        let cached = [
            ProviderUsageResult(
                accountID: apps.id, providerID: .gemini, title: apps.displayName, subtitle: "Cached Apps usage",
                bars: [UsageBar(stableKey: "weekly", label: "Weekly", used: 45, limit: 100)], fetchedAt: Self.now
            ),
            try AntigravityQuotaParser.result(from: Self.payload(), configuration: coding, fetchedAt: Self.now),
        ]
        let service = UsageRefreshService(providers: [], initialResults: cached)
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)

        XCTAssertEqual(dashboard.dashboardCardItems.flatMap { $0.result?.configurableMetrics ?? [] }.count, 6)
        XCTAssertTrue(dashboard.dashboardCardItems.allSatisfy {
            $0.result?.bars.isEmpty == true
                && $0.result?.configurableMetrics.allSatisfy { $0.kind == .unavailableUsage("Setup required") } == true
        })
        WidgetSnapshotPublisher.publish(results: cached, configurationStore: store, snapshotDefaults: defaults)
        XCTAssertTrue(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.isEmpty)
        XCTAssertTrue(WatchSnapshotPublisher.makeSnapshot(results: cached, configurationStore: store, now: Self.now).accounts.isEmpty)
    }

    @MainActor
    func testGoogleSetupPromotionAvoidsGlobalNameCollisionsAndRetainsLayout() throws {
        for source in [ProviderID.gemini, .antigravity] {
            let suite = "GoogleSetup.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore(), widgetSnapshotDefaults: defaults)
            store.addAccount(for: source == .gemini ? .antigravity : .gemini)
            for name in [source.displayName, "\(source.displayName) 1"] {
                var other = store.addAccount(for: .codex)
                other.accountLabel = name
                XCTAssertTrue(store.update(other))
            }
            let placeholder = try XCTUnwrap(GoogleUsageMetricCatalog.missingSourceConfigurations(in: store.configurations).first)
            let metricID = "\(source.rawValue).\(try XCTUnwrap(GoogleUsageMetricCatalog.definitions(for: source).first).key)"
            store.updateMetricVisibility(false, accountID: placeholder.id, metricID: metricID)
            store.updateMetricWidth(.half, accountID: placeholder.id, metricID: metricID)
            let layout = store.metricLayouts[placeholder.id]

            let promoted = try XCTUnwrap(store.prepareDashboardAccountForSetup(placeholder))

            XCTAssertEqual(promoted.id, placeholder.id)
            XCTAssertEqual(promoted.providerID, source)
            XCTAssertEqual(promoted.accountLabel, "\(source.displayName) 2")
            XCTAssertEqual(store.metricLayouts[promoted.id], layout)
            XCTAssertEqual(store.configuration(accountID: promoted.id), promoted)
            XCTAssertFalse(store.hasSecret(for: promoted))
            XCTAssertNil(store.lastError)
        }
    }

    func testGoogleDashboardLoadingFailureAndObservedResultsRetainSourceIdentity() throws {
        let apps = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let coding = Self.configuration
        let observed = try Self.result(Self.payload())
        let states: [(Bool, String?, String)] = [(true, nil, "Loading"), (false, "Refresh failed", "Unavailable")]
        for (isRefreshing, error, expected) in states {
            let items = DashboardProviderCardItem.items(
                configurations: [apps, coding], results: [observed],
                refreshingAccountIDs: isRefreshing ? [apps.id] : [],
                errorsByAccountID: error.map { [apps.id: $0] } ?? [:],
                orderingMode: .manual, manualOrder: []
            )
            let appsResult = try XCTUnwrap(items.first { $0.id == apps.id }?.result)
            XCTAssertTrue(appsResult.bars.isEmpty)
            XCTAssertEqual(appsResult.configurableMetrics.map(\.id), ["gemini.five-hour", "gemini.weekly"])
            XCTAssertTrue(appsResult.configurableMetrics.allSatisfy { $0.kind == .unavailableUsage(expected) })
            XCTAssertEqual(items.first { $0.id == coding.id }?.result, observed)
        }
        XCTAssertTrue(GoogleUsageMetricCatalog.missingSourceConfigurations(in: []).isEmpty)
        XCTAssertEqual(GoogleUsageMetricCatalog.missingSourceConfigurations(in: [apps, apps.withNewAccountID()]).count, 1)
        XCTAssertEqual(GoogleUsageMetricCatalog.missingSourceConfigurations(in: [coding]).map(\.providerID), [.gemini])
    }

    @MainActor
    private func googleDashboard(
        store: ProviderConfigurationStore,
        service: UsageRefreshService,
        defaults: UserDefaults
    ) -> DashboardOrchestrator {
        DashboardOrchestrator(
            refreshService: service, configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(), appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service, configurationStore: store, publishSnapshot: { _, _ in }, publishSettings: { _ in }
            ),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(
                refreshService: service, configurationStore: store, publishSnapshot: { _, _, _ in }
            )
        )
    }

    private static let expiredCredential = #"{"access_token":"old","refresh_token":"refresh","client_id":"client","client_secret":"secret+value","expiry":"2020-01-01T00:00:00Z"}"#

    private static func response(_ request: URLRequest, status: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil))
    }

    private static func buckets() -> [[String: Any]] {
        zip(AntigravityQuotaParser.metrics, [0.0, 0.69, 0.8, 0.4]).map { metric, remaining in
            ["bucketId": metric.key, "window": metric.window, "remainingFraction": remaining, "resetTime": "2030-09-11T16:22:20Z"]
        }
    }

    private static func payload(_ buckets: [[String: Any]] = buckets()) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["groups": [["buckets": Array(buckets.prefix(2))], ["buckets": Array(buckets.dropFirst(2))]]])
    }

    private static func result(_ data: Data) throws -> ProviderUsageResult {
        try AntigravityQuotaParser.result(from: data, configuration: configuration, fetchedAt: now)
    }
}
