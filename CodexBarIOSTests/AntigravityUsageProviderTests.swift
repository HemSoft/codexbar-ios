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
    func testAllSixMetricChoicesExistOnOneAccountBeforeCredentials() throws {
        let suite = "GoogleChoices.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let account = store.addAccount(for: .gemini)
        let legacy = store.addAccount(for: .antigravity)
        let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
        XCTAssertEqual(model.availableMetrics.map(\.id), Self.googleIDs)
        XCTAssertTrue(model.availableMetrics.allSatisfy { $0.kind == .unavailableUsage("Setup required") })
        XCTAssertEqual(store.visibleConfigurations, [account])
        XCTAssertEqual(store.unlinkedGeminiCodingAccounts, [legacy])
        XCTAssertFalse(store.shouldDisplayOnDashboard(legacy))
        XCTAssertFalse(AddAccountFlowState.providerOptions.contains(.antigravity))
        let service = UsageRefreshService(providers: [])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        XCTAssertEqual(dashboard.dashboardCardItems.map(\.id), [account.id])
        XCTAssertEqual(dashboard.dashboardCardItems.first?.result?.configurableMetrics.map(\.id), Self.googleIDs)
        XCTAssertTrue(GoogleUsageMetricCatalog.missingSourceConfigurations(in: store.configurations).isEmpty)
    }

    @MainActor
    func testAllSixPreferencesSurviveMissingResultsRefreshAndRelaunch() async throws {
        let suite = "GoogleLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let account = store.addAccount(for: .gemini)
        XCTAssertTrue(store.saveSecret("apps-session", for: account))
        let result = try Self.unifiedResult(account)
        let model = ProviderSettingsViewModel(configurationStore: store, accountID: account.id)
        store.reconcileMetricLayout(accountID: account.id, availableMetricIDs: Self.googleIDs)
        for (index, id) in Self.googleIDs.enumerated() {
            store.updateMetricVisibility(index.isMultiple(of: 2), accountID: account.id, metricID: id)
            store.updateMetricWidth(index.isMultiple(of: 2) ? .half : .full, accountID: account.id, metricID: id)
            store.updateVisualizationStyle(index.isMultiple(of: 2) ? .circularRing : .largeNumeric, accountID: account.id, metricID: id)
        }
        store.updateMetricOrder(Array(Self.googleIDs.reversed()), accountID: account.id)
        let layout = store.metricLayouts[account.id]
        model.synchronizeUsageResult(result)
        model.synchronizeUsageResult(nil)
        let service = UsageRefreshService(providers: [ReturningFailureUsageProvider(providerID: .gemini)], initialResults: [result])
        await service.refresh(configurations: [account])
        XCTAssertFalse(try XCTUnwrap(service.results.first).hasCurrentBars)
        XCTAssertEqual(store.metricLayouts[account.id], layout)
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.metricLayouts[account.id], layout)
        XCTAssertEqual(model.availableMetrics.map(\.id), Self.googleIDs)
    }

    @MainActor
    func testConfirmedLegacyLinkPreservesHistoryCredentialsAndOverridesSeededCodingLayout() throws {
        let suite = "GoogleMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let apps = store.addAccount(for: .gemini)
        let coding = store.addAccount(for: .antigravity)
        let unrelated = store.addAccount(for: .gemini)
        XCTAssertTrue(store.saveSecret("apps-secret", for: apps))
        XCTAssertTrue(store.saveSecret(#"{"access_token":"coding-token"}"#, for: coding))
        store.reconcileMetricLayout(accountID: apps.id, availableMetricIDs: Self.googleIDs)
        store.updateMetricVisibility(false, accountID: apps.id, metricID: "gemini.weekly")
        let codingIDs = Array(Self.googleIDs.dropFirst(2))
        store.reconcileMetricLayout(accountID: coding.id, availableMetricIDs: codingIDs)
        store.updateMetricVisibility(false, accountID: coding.id, metricID: codingIDs[1])
        store.updateMetricWidth(.half, accountID: coding.id, metricID: codingIDs[1])
        store.updateVisualizationStyle(.circularRing, accountID: coding.id, metricID: codingIDs[1])
        store.updateWatchMetricVisibility(.hide, accountID: coding.id, metricID: codingIDs[1])
        store.updateMetricOrder(Array(codingIDs.reversed()), accountID: coding.id)
        let history = UsageHistoryStore(defaults: defaults)
        let legacyResult = try AntigravityQuotaParser.result(from: Self.payload(), configuration: coding, fetchedAt: Self.now)
        let appsResult = ProviderUsageResult(
            accountID: apps.id, providerID: .gemini, title: apps.displayName, subtitle: "Apps",
            bars: [UsageBar(stableKey: "weekly", label: "Gemini Apps weekly", used: 25, limit: 100)], fetchedAt: Self.now
        )
        history.record(results: [appsResult, legacyResult], now: Self.now)
        let originalIDs = Set(history.snapshots.map(\.id))
        XCTAssertFalse(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: false))
        XCTAssertEqual(history.snapshots.count, 2)
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertTrue(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: true))
        history.migrateGoogleAccounts(links: store.confirmedGoogleAccountLinks, configurations: store.visibleConfigurations)
        XCTAssertEqual(history.snapshots(for: apps.id).count, 2)
        XCTAssertEqual(Set(history.snapshots.map(\.id)), originalIDs)
        XCTAssertTrue(history.snapshots.allSatisfy { $0.providerID == .gemini })
        XCTAssertEqual(history.snapshots(for: apps.id).flatMap(\.bars).count, 5)
        XCTAssertFalse(store.isMetricVisible(accountID: apps.id, metricID: codingIDs[1]))
        XCTAssertFalse(store.isMetricVisible(accountID: apps.id, metricID: "gemini.weekly"))
        XCTAssertFalse(store.isMetricVisibleOnWatch(accountID: apps.id, metricID: codingIDs[1]))
        XCTAssertEqual(store.metricWidth(accountID: apps.id, metricID: codingIDs[1]), .half)
        XCTAssertEqual(store.visualizationStyle(accountID: apps.id, metricID: codingIDs[1]), .circularRing)
        XCTAssertEqual(Array(try XCTUnwrap(store.metricLayouts[apps.id]).orderedMetricIDs.suffix(4)), Array(codingIDs.reversed()))
        XCTAssertTrue(store.isMetricVisible(accountID: unrelated.id, metricID: codingIDs[1]))
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: apps)), "apps-secret")
        XCTAssertNotNil(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: coding)))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: unrelated))
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let restoredHistory = UsageHistoryStore(defaults: defaults)
        restoredHistory.migrateGoogleAccounts(links: restored.confirmedGoogleAccountLinks, configurations: restored.visibleConfigurations)
        restoredHistory.record(results: [try Self.unifiedResult(apps)], now: Self.now)
        XCTAssertEqual(Set(restoredHistory.snapshots.map(\.id)).count, restoredHistory.snapshots.count)
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
        XCTAssertEqual(restored.metricLayouts[apps.id], store.metricLayouts[apps.id])
    }

    @MainActor
    func testUnlinkedAccountsRemainIsolatedAndVerifiedDifferentIdentitiesCannotLink() throws {
        let suite = "GoogleAssociation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        var apps = store.addAccount(for: .gemini)
        var coding = store.addAccount(for: .antigravity)
        let other = store.addAccount(for: .antigravity)
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: coding))
        XCTAssertFalse(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: false))
        apps.verifiedGoogleSubject = "google-a"
        coding.verifiedGoogleSubject = "google-b"
        XCTAssertTrue(store.update(apps))
        XCTAssertTrue(store.update(coding))
        XCTAssertFalse(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: true))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(Set(store.unlinkedGeminiCodingAccounts.map(\.id)), [coding.id, other.id])
        coding.verifiedGoogleSubject = "google-a"
        XCTAssertTrue(store.update(coding))
        XCTAssertTrue(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: false))
        XCTAssertEqual(store.unlinkedGeminiCodingAccounts, [other])
        XCTAssertFalse(store.linkGeminiCodingAccount(other, to: apps, confirmedSameAccount: true))
        XCTAssertNotNil(ProviderConfigurationStore(defaults: defaults, secretStore: secrets).configuration(accountID: other.id))
    }

    @MainActor
    func testConfirmedArchiveNameCanBeReusedWithoutLosingUnlinkedNameReservations() throws {
        let suite = "GoogleArchiveNames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        var apps = store.addAccount(for: .gemini)
        var coding = store.addAccount(for: .antigravity)
        var other = store.addAccount(for: .gemini)
        coding.accountLabel = "Personal Google"
        XCTAssertTrue(store.update(coding))
        let token = #"{"access_token":"coding-token"}"#
        XCTAssertTrue(store.saveSecret(token, for: coding))
        apps.accountLabel = "PERSONAL GOOGLE"
        XCTAssertFalse(store.update(apps), "Unlinked legacy sessions still reserve their names for association.")
        XCTAssertEqual(store.unlinkedGeminiCodingAccounts, [coding])
        XCTAssertTrue(store.linkGeminiCodingAccount(coding, to: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.update(apps), "A confirmed archival record must not block the visible account name.")
        other.accountLabel = "personal google"
        XCTAssertFalse(store.update(other), "Visible names remain case-insensitively unique.")
        XCTAssertEqual(store.configuration(accountID: coding.id), coding)
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: coding)), token)
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.configuration(accountID: apps.id)?.displayName, "PERSONAL GOOGLE")
        XCTAssertEqual(restored.configuration(accountID: coding.id), coding)
        XCTAssertEqual(restored.confirmedGoogleAccountLinks, [coding.id: apps.id])
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
        XCTAssertFalse(restored.update(other))
    }

    @MainActor
    func testPendingConfirmedLinkResumesAfterCredentialCopyWithoutGuessing() throws {
        let suite = "GoogleLinkRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let apps = store.addAccount(for: .gemini)
        let coding = store.addAccount(for: .antigravity)
        let token = try AntigravityCredentials.parse(#"{"access_token":"token"}"#).encoded()
        XCTAssertTrue(store.saveSecret(token, for: coding))
        try secrets.saveSecret(token, account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id))
        defaults.set([coding.id: apps.id], forKey: "pendingGoogleAccountLinks")
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.confirmedGoogleAccountLinks, [coding.id: apps.id])
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
        XCTAssertTrue(restored.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(defaults.dictionary(forKey: "pendingGoogleAccountLinks")?.count, 0)
    }

    @MainActor
    func testSyntheticSetupLayoutMovesToGeminiWithoutCreatingCodingAccount() throws {
        let suite = "GoogleSetupLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let old = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let metricID = "antigravity.gemini-weekly"
        old.updateMetricVisibility(false, accountID: "dashboard.setup.antigravity", metricID: metricID)
        old.updateMetricWidth(.half, accountID: "dashboard.setup.antigravity", metricID: metricID)
        let apps = old.addAccount(for: .gemini)
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        XCTAssertEqual(restored.visibleConfigurations, [apps])
        XCTAssertFalse(restored.isMetricVisible(accountID: apps.id, metricID: metricID))
        XCTAssertEqual(restored.metricWidth(accountID: apps.id, metricID: metricID), .half)
        XCTAssertTrue(GoogleUsageMetricCatalog.missingSourceConfigurations(in: restored.configurations).isEmpty)
    }

    @MainActor
    func testLegacyWidgetAndWatchSelectionsResolveOnlyConfirmedCodingIdentity() throws {
        let suite = "GoogleSelections.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let apps = store.addAccount(for: .gemini)
        let legacy = store.addAccount(for: .antigravity)
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: legacy))
        XCTAssertTrue(store.linkGeminiCodingAccount(legacy, to: apps, confirmedSameAccount: true))
        let result = try Self.unifiedResult(apps)
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, snapshotDefaults: defaults, now: Self.now)
        let widget = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(widget.results.count, 1)
        XCTAssertEqual(widget.results.first?.bars.map(\.metricID), Self.googleIDs)
        XCTAssertEqual(widget.builderTile(resolvingSavedID: "provider.\(legacy.id)")?.id, "provider.\(apps.id)")
        let savedID = "bar.\(legacy.id).antigravity.gemini-5h"
        XCTAssertEqual(widget.builderTile(resolvingSavedID: savedID)?.id, "bar.\(apps.id).antigravity.gemini-5h")
        XCTAssertNil(widget.builderTile(resolvingSavedID: "bar.unlinked.antigravity.gemini-5h"))
        let watch = WatchSnapshotPublisher.makeSnapshot(results: [result], configurationStore: store, now: Self.now)
        XCTAssertEqual(watch.accounts.count, 1)
        XCTAssertEqual(watch.accounts.first?.metrics.map(\.id), Self.googleIDs)
        XCTAssertEqual(watch.accounts.first?.legacyAccountIDs, [WatchSnapshotPublisher.snapshotAccountID(providerID: .antigravity, configurationID: legacy.id)])
        let partial = ProviderUsageResult(
            accountID: apps.id, providerID: .gemini, title: apps.displayName, subtitle: "Coding unavailable",
            bars: Array(result.bars.prefix(2)), fetchedAt: Self.now
        )
        WidgetSnapshotPublisher.publish(results: [partial], configurationStore: store, snapshotDefaults: defaults, now: Self.now)
        let missing = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertNil(missing.builderTile(resolvingSavedID: savedID))
        XCTAssertNil(missing.builderTile(resolvingSavedID: "bar.\(legacy.id).0.Gemini-Apps-five-hour"))
    }

    @MainActor
    func testCodingCredentialReplacementAndDisconnectStaySourceAndAccountScoped() throws {
        let suite = "GoogleCredentials.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let apps = store.addAccount(for: .gemini)
        let other = store.addAccount(for: .gemini)
        XCTAssertTrue(store.saveSecret("apps-cookie", for: apps))
        XCTAssertFalse(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: false))
        XCTAssertFalse(store.saveGeminiCodingSecret("apps-cookie", for: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"replacement"}"#, for: apps, confirmedSameAccount: true))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: other))
        XCTAssertTrue(store.disconnectGeminiCoding(for: apps))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: apps)), "apps-cookie")
    }

    @MainActor
    func testCodingDisconnectDeletesLinkedAuthorizationAndCannotReplayAfterRelaunch() throws {
        let suite = "GoogleDisconnect.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let apps = store.addAccount(for: .gemini)
        let legacy = store.addAccount(for: .antigravity)
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: legacy))
        XCTAssertTrue(store.linkGeminiCodingAccount(legacy, to: apps, confirmedSameAccount: true))
        XCTAssertTrue(store.disconnectGeminiCoding(for: apps))
        XCTAssertNil(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: legacy)))
        let restored = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        XCTAssertFalse(restored.hasGeminiCodingSecret(for: apps))
        XCTAssertEqual(restored.confirmedGoogleAccountLinks, [legacy.id: apps.id])
        XCTAssertTrue(restored.unlinkedGeminiCodingAccounts.isEmpty)
    }

    @MainActor
    func testCodingKeyDeletionFailureKeepsResetAccountAvailableForRetry() throws {
        let suite = "GoogleResetRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = RetriableDeleteSecretStore()
        secrets.shouldFailDelete = false
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let apps = store.addAccount(for: .gemini)
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        secrets.failingAccount = ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id)
        XCTAssertFalse(store.resetAccounts())
        XCTAssertNotNil(store.configuration(accountID: apps.id))
        XCTAssertTrue(store.hasGeminiCodingSecret(for: apps))
        secrets.failingAccount = nil
        XCTAssertTrue(store.resetAccounts())
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertNil(try secrets.readSecret(account: ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id)))
    }

    @MainActor
    func testPartialAccountRemovalInvalidatesDeletedCodingSourceAndRetainsLinkedRecords() throws {
        let suite = "GoogleRemovalRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = RetriableDeleteSecretStore()
        secrets.shouldFailDelete = false
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let apps = store.addAccount(for: .gemini)
        let legacy = store.addAccount(for: .antigravity)
        XCTAssertTrue(store.saveSecret(#"{"access_token":"token"}"#, for: legacy))
        XCTAssertTrue(store.saveSecret("apps-cookie", for: apps))
        XCTAssertTrue(store.linkGeminiCodingAccount(legacy, to: apps, confirmedSameAccount: true))
        let service = UsageRefreshService(providers: [], initialResults: [try Self.unifiedResult(apps)])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        secrets.failingAccount = ProviderConfigurationStore.keychainAccount(for: apps)
        XCTAssertFalse(store.removeAccount(apps))
        XCTAssertTrue(service.results.isEmpty)
        XCTAssertEqual(store.confirmedGoogleAccountLinks, [legacy.id: apps.id])
        XCTAssertNotNil(store.configuration(accountID: legacy.id))
        XCTAssertEqual(dashboard.dashboardCardItems.count, 1)
        secrets.failingAccount = nil
        XCTAssertTrue(store.removeAccount(apps))
        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertTrue(store.confirmedGoogleAccountLinks.isEmpty)
    }

    @MainActor
    func testStoreCodingDisconnectInvalidatesSuspendedDashboardRefresh() async throws {
        let suite = "GoogleRefreshIdentity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let apps = store.addAccount(for: .gemini)
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        let gate = UsageProviderGate()
        let provider = StaleCompletionTestUsageProvider(providerID: .gemini, gate: gate, fails: false)
        let service = UsageRefreshService(providers: [provider], initialResults: [try Self.unifiedResult(apps)])
        let dashboard = googleDashboard(store: store, service: service, defaults: defaults)
        let refresh = Task { await dashboard.refreshNow() }
        await gate.waitUntilBlocked()
        XCTAssertTrue(store.disconnectGeminiCoding(for: apps))
        XCTAssertTrue(service.results.isEmpty)
        await gate.release()
        _ = await refresh.value
        XCTAssertTrue(service.results.isEmpty)
        XCTAssertTrue(UsageHistoryStore(defaults: defaults).snapshots.isEmpty)
    }

    @MainActor
    func testOneUnreadableSourceDoesNotHideTheOtherGeminiCredential() throws {
        let suite = "GoogleAvailability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = SelectiveReadFailureSecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        let apps = store.addAccount(for: .gemini)
        XCTAssertTrue(store.saveSecret("apps-cookie", for: apps))
        XCTAssertTrue(store.saveGeminiCodingSecret(#"{"access_token":"token"}"#, for: apps, confirmedSameAccount: true))
        secrets.failingAccount = ProviderConfigurationStore.keychainAccount(for: apps)
        store.refreshSecretAvailability()
        XCTAssertFalse(store.hasSecret(for: apps))
        XCTAssertTrue(store.hasGeminiCodingSecret(for: apps))
        XCTAssertTrue(store.shouldDisplayOnDashboard(apps))
        secrets.failingAccount = ProviderConfigurationStore.geminiCodingKeychainAccount(accountID: apps.id)
        store.refreshSecretAvailability()
        XCTAssertTrue(store.hasSecret(for: apps))
        XCTAssertFalse(store.hasGeminiCodingSecret(for: apps))
        XCTAssertTrue(store.shouldDisplayOnDashboard(apps))
    }

    @MainActor
    func testScreenshotFixtureContainsOneGeminiAccountAndSixBuckets() {
        let store = ProviderConfigurationStore.appStoreScreenshotDemo()
        let results = AppStoreScreenshotFixtures.results(for: store)
        XCTAssertFalse(results.contains { $0.providerID == .antigravity })
        XCTAssertEqual(results.first { $0.providerID == .gemini }?.configurableMetrics.map(\.id), Self.googleIDs)
    }

    private static let googleIDs = [
        "gemini.five-hour", "gemini.weekly", "antigravity.gemini-5h",
        "antigravity.gemini-weekly", "antigravity.3p-5h", "antigravity.3p-weekly",
    ]

    private static func unifiedResult(_ account: ProviderAccountConfiguration) throws -> ProviderUsageResult {
        let coding = try result(payload())
        return ProviderUsageResult(
            accountID: account.id, providerID: .gemini, title: account.displayName, subtitle: "Google usage",
            bars: [
                UsageBar(stableKey: "five-hour", label: "Gemini Apps five-hour", used: 12, limit: 100),
                UsageBar(stableKey: "weekly", label: "Gemini Apps weekly", used: 45, limit: 100),
            ] + coding.bars,
            fetchedAt: now
        )
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
