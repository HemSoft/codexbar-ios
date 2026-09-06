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
    func testExplicitlyDisabledBucketsOverrideCachedValuesWithoutLosingHistory() async throws {
        let secrets = MemorySecretStore()
        try secrets.saveSecret(#"{"access_token":"test"}"#, account: ProviderConfigurationStore.keychainAccount(for: Self.configuration))
        let fixture = IsolatedTestURLSession { request in
            let disabled = Self.buckets().map { bucket in
                var bucket = bucket
                bucket["disabled"] = true
                return bucket
            }
            return (try Self.response(request, status: 200), try Self.payload(disabled))
        }
        defer { fixture.invalidate() }
        let initial = try Self.result(Self.payload())
        let service = UsageRefreshService(
            providers: [AntigravityUsageProvider(secretStore: secrets, sessionConfiguration: fixture.session.configuration)],
            initialResults: [initial]
        )
        await service.refresh(configurations: [Self.configuration])
        let result = try XCTUnwrap(service.results.first)
        XCTAssertFalse(result.hasCurrentBars)
        XCTAssertEqual(result.bars, initial.bars)
        XCTAssertEqual(result.barsFetchedAt, initial.barsFetchedAt)
        XCTAssertEqual(result.configurableMetrics.map(\.id), initial.configurableMetrics.map(\.id))
        XCTAssertTrue(result.configurableMetrics.allSatisfy { $0.kind == .unavailableUsage("Disabled") })
        XCTAssertTrue(result.hasSuccessfulRefreshHistory)
    }

    func testCatalogKeepsOtherProvidersAndRejectsWrongSourceResults() throws {
        let other = ProviderUsageResult(providerID: .openRouter, title: "Other", subtitle: "", bars: [], creditsRemaining: 12, fetchedAt: Self.now)
        XCTAssertEqual(other.configurableMetrics, other.availableMetrics)
        XCTAssertTrue(GoogleUsageMetricCatalog.metrics(for: .gemini, result: other).allSatisfy {
            $0.kind == .unavailableUsage("Setup required")
        })
        let result = try Self.result(Self.payload([]))
        XCTAssertEqual(ProviderMetricTileGridResolver.resolvedWidth(
            preference: .automatic, kind: result.configurableMetrics[0].kind,
            visualizationStyle: .circularRing, usesRegularHorizontalSizeClass: false,
            collapsesToSingleColumn: false
        ), .half)
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
