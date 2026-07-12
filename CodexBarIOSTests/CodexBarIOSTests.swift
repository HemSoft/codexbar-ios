import XCTest
@testable import CodexBarIOS
#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
#endif

final class CodexBarIOSTests: XCTestCase {
    func testUsageSeverityThresholds() {
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.74), .normal)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.75), .warning)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.90), .critical)
    }

    func testProviderConfigurationDefaults() {
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .openRouter).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .copilot).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .codex).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .claude).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .cursor).authMethod,
            .browserSession
        )
    }

    func testAppStoreScreenshotConfigurationParsesSceneAndAppearance() {
        XCTAssertNil(AppStoreScreenshotConfiguration.parse(arguments: []))

        let configuration = AppStoreScreenshotConfiguration.parse(
            arguments: [
                "CodexBarIOS",
                "--app-store-screenshots",
                "--app-store-scene",
                "history",
                "--app-store-appearance",
                "dark",
                "--app-store-settle-seconds",
                "3.5",
            ]
        )

        XCTAssertEqual(configuration?.scene, .history)
        XCTAssertEqual(configuration?.appearance, .dark)
        XCTAssertEqual(configuration?.settleDelay, 3.5)

        let fallback = AppStoreScreenshotConfiguration.parse(
            arguments: ["CodexBarIOS"],
            environment: ["CODEXBAR_APP_STORE_SCREENSHOTS": "1"]
        )
        XCTAssertEqual(fallback?.scene, .dashboardOverview)
        XCTAssertEqual(fallback?.appearance, .light)
        XCTAssertEqual(fallback?.settleDelay, 2)
    }

    @MainActor
    func testAppStoreScreenshotFixturesCoverEveryProviderAndSeedHistory() {
        let configurationStore = ProviderConfigurationStore.appStoreScreenshotDemo()
        let results = AppStoreScreenshotFixtures.results(for: configurationStore)

        XCTAssertEqual(Set(results.map(\.providerID)), Set(ProviderID.allCases))
        XCTAssertTrue(results.allSatisfy { $0.accountID.hasPrefix("app-store-screenshots.") })
        XCTAssertEqual(Set(results.map(\.fetchedAt)).count, 1)
        let claudeResult = results.first(where: { $0.providerID == .claude })
        XCTAssertEqual(claudeResult?.monetaryMetrics.count, 2)
        XCTAssertFalse(claudeResult?.usageMessages.isEmpty ?? true)

        let historyStore = AppStoreScreenshotFixtures.historyStore(for: results)
        guard let codexResult = results.first(where: { $0.providerID == .codex }) else {
            return XCTFail("Expected a Codex screenshot fixture")
        }
        let series = historyStore.historySeries(for: codexResult)
        XCTAssertEqual(series.points.count, 8)
        XCTAssertEqual(series.direction, .up)
    }

    func testInstalledAppVersionFormatsBundleValues() {
        let version = InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2")

        XCTAssertEqual(version.displayText, "Version 1.1 (2)")
    }

    func testAppVersionComparesDottedComponentsNumerically() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9")), try XCTUnwrap(AppVersion("1.10")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.2")), try XCTUnwrap(AppVersion("1.2.0")))
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("2.0")), try XCTUnwrap(AppVersion("1.99.99")))
        XCTAssertNil(AppVersion("1.2-beta"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion(""))
    }

    func testAppStoreReleaseLookupDecodesReturnedURLAndUsesFallback() throws {
        let returnedURL = "https://apps.apple.com/de/app/codexbar/id6787769891?uo=4"
        let returnedRelease = try AppStoreReleaseService.decodeRelease(
            from: Data(
                """
                {"resultCount":1,"results":[{"version":"1.2","trackViewUrl":"\(returnedURL)"}]}
                """.utf8
            )
        )
        XCTAssertEqual(returnedRelease.version, "1.2")
        XCTAssertEqual(returnedRelease.productURL.absoluteString, returnedURL)

        let fallbackRelease = try AppStoreReleaseService.decodeRelease(
            from: Data(#"{"resultCount":1,"results":[{"version":"1.2","trackViewUrl":"invalid"}]}"#.utf8)
        )
        XCTAssertEqual(fallbackRelease.productURL, AppStoreReleaseService.fallbackProductURL)

        XCTAssertThrowsError(
            try AppStoreReleaseService.decodeRelease(
                from: Data(#"{"resultCount":0,"results":[]}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? AppStoreReleaseError, .missingRelease)
        }

        XCTAssertThrowsError(
            try AppStoreReleaseService.decodeRelease(from: Data("not-json".utf8))
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testAppStoreReleaseServiceUsesIDLookupAndRejectsHTTPFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = AppStoreReleaseService(session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "itunes.apple.com")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItemValue(named: "id"),
                "6787769891"
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"resultCount":1,"results":[{"version":"1.2","trackViewUrl":"https://apps.apple.com/us/app/id6787769891"}]}"#.utf8
                )
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let fetchedRelease = try await service.fetchRelease()
        XCTAssertEqual(fetchedRelease.version, "1.2")

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        do {
            _ = try await service.fetchRelease()
            XCTFail("Expected an HTTP status error")
        } catch {
            XCTAssertEqual(error as? AppStoreReleaseError, .httpStatus(503))
        }
    }

    func testAppUpdateComparisonNeverOffersCurrentReleaseOrDowngrade() {
        let productURL = AppStoreReleaseService.fallbackProductURL

        XCTAssertNil(
            AppUpdateController.newerRelease(
                AppStoreRelease(version: "1.1", productURL: productURL),
                than: "1.1"
            )
        )
        XCTAssertNil(
            AppUpdateController.newerRelease(
                AppStoreRelease(version: "1.0", productURL: productURL),
                than: "1.1"
            )
        )
        XCTAssertEqual(
            AppUpdateController.newerRelease(
                AppStoreRelease(version: "1.10", productURL: productURL),
                than: "1.9"
            )?.version,
            "1.10"
        )
    }

    @MainActor
    func testAppUpdateControllerCachesAndRateLimitsSuccessfulChecks() async {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let release = AppStoreRelease(version: "1.2", productURL: AppStoreReleaseService.fallbackProductURL)
        let fetcher = StubAppStoreReleaseFetcher(result: .success(release))
        let installedVersion = InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2")
        let checkInterval: TimeInterval = 2 * 60 * 60
        let controller = AppUpdateController(
            installedVersion: installedVersion,
            defaults: defaults,
            releaseFetcher: fetcher,
            checkInterval: checkInterval
        )

        await controller.checkForUpdates(at: now)

        XCTAssertEqual(controller.availableRelease, release)
        let initialFetchCount = await fetcher.currentFetchCount()
        XCTAssertEqual(initialFetchCount, 1)

        let reloadedController = AppUpdateController(
            installedVersion: installedVersion,
            defaults: defaults,
            releaseFetcher: fetcher,
            checkInterval: checkInterval
        )
        XCTAssertEqual(reloadedController.availableRelease, release)

        await reloadedController.checkForUpdates(at: now.addingTimeInterval(60 * 60))
        let rateLimitedFetchCount = await fetcher.currentFetchCount()
        XCTAssertEqual(rateLimitedFetchCount, 1)

        await reloadedController.checkForUpdates(force: true, at: now.addingTimeInterval(60 * 60))
        let forcedFetchCount = await fetcher.currentFetchCount()
        XCTAssertEqual(forcedFetchCount, 2)
    }

    @MainActor
    func testAppUpdateControllerFailsQuietlyAndDismissesOnlyDetectedVersion() async {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let firstRelease = AppStoreRelease(
            version: "1.2",
            productURL: AppStoreReleaseService.fallbackProductURL
        )
        let fetcher = StubAppStoreReleaseFetcher(result: .success(firstRelease))
        let controller = AppUpdateController(
            installedVersion: InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2"),
            defaults: defaults,
            releaseFetcher: fetcher
        )

        await controller.checkForUpdates(at: now)
        controller.dismissDashboardNotice()

        XCTAssertEqual(controller.availableRelease, firstRelease)
        XCTAssertNil(controller.dashboardRelease)

        let reloadedController = AppUpdateController(
            installedVersion: InstalledAppVersion(marketingVersion: "1.1", buildNumber: "2"),
            defaults: defaults,
            releaseFetcher: fetcher
        )
        XCTAssertEqual(reloadedController.availableRelease, firstRelease)
        XCTAssertNil(reloadedController.dashboardRelease)

        await fetcher.setResult(.failure(.invalidResponse))
        await controller.checkForUpdates(force: true, at: now.addingTimeInterval(1))
        XCTAssertEqual(controller.availableRelease, firstRelease)
        XCTAssertNil(controller.dashboardRelease)

        let nextRelease = AppStoreRelease(
            version: "1.3",
            productURL: AppStoreReleaseService.fallbackProductURL
        )
        await fetcher.setResult(.success(nextRelease))
        await controller.checkForUpdates(force: true, at: now.addingTimeInterval(2))

        XCTAssertEqual(controller.availableRelease, nextRelease)
        XCTAssertEqual(controller.dashboardRelease, nextRelease)
    }

    func testAppReviewLinksTargetProductionListingAndSupport() {
        XCTAssertEqual(AppReviewLinks.writeReviewURL.host, "apps.apple.com")
        XCTAssertTrue(AppReviewLinks.writeReviewURL.path.hasSuffix("/id6787769891"))
        XCTAssertEqual(
            URLComponents(url: AppReviewLinks.writeReviewURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "action" })?.value,
            "write-review"
        )
        XCTAssertEqual(
            AppReviewLinks.supportURL.absoluteString,
            "https://github.com/HemSoft/codexbar-ios/blob/main/SUPPORT.md"
        )
    }

    func testAppReviewPromptPolicyRequiresSustainedSuccessfulRefreshes() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let policy = AppReviewPromptPolicy(defaults: defaults, appVersion: "1.1")

        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(24 * 60 * 60)))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(3 * 24 * 60 * 60)))
        XCTAssertFalse(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(6 * 24 * 60 * 60)))
        XCTAssertTrue(policy.registerSuccessfulRefresh(at: start.addingTimeInterval(7 * 24 * 60 * 60)))

        let reloadedPolicy = AppReviewPromptPolicy(defaults: defaults, appVersion: "1.1")
        XCTAssertFalse(reloadedPolicy.registerSuccessfulRefresh(at: start.addingTimeInterval(365 * 24 * 60 * 60)))
    }

    func testAppReviewPromptPolicyPersistsCooldownAcrossVersions() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let start = Date(timeIntervalSince1970: 1_788_475_200)
        let firstVersion = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.1",
            minimumSuccessfulRefreshes: 1,
            minimumEngagementDuration: 0
        )
        XCTAssertTrue(firstVersion.registerSuccessfulRefresh(at: start))

        let nextVersion = AppReviewPromptPolicy(
            defaults: defaults,
            appVersion: "1.2",
            minimumSuccessfulRefreshes: 1,
            minimumEngagementDuration: 0
        )
        XCTAssertFalse(nextVersion.registerSuccessfulRefresh(at: start.addingTimeInterval(119 * 24 * 60 * 60)))
        XCTAssertTrue(nextVersion.registerSuccessfulRefresh(at: start.addingTimeInterval(120 * 24 * 60 * 60)))
    }

    func testAppReviewPromptEligibilityRequiresSuccessfulRefreshWithUsableData() {
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let emptyResult = ProviderUsageResult(
            providerID: .codex,
            title: "Codex",
            subtitle: "Usage",
            bars: [],
            fetchedAt: fetchedAt
        )
        let barsResult = ProviderUsageResult(
            providerID: .codex,
            title: "Codex",
            subtitle: "Usage",
            bars: [UsageBar(label: "Weekly", used: 1, limit: 10)],
            fetchedAt: fetchedAt
        )
        let creditsResult = ProviderUsageResult(
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Balance",
            bars: [],
            creditsRemaining: 5,
            fetchedAt: fetchedAt
        )

        XCTAssertFalse(
            AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: "Offline", results: [barsResult])
        )
        XCTAssertFalse(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: []))
        XCTAssertFalse(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: [emptyResult]))
        XCTAssertTrue(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: [barsResult]))
        XCTAssertTrue(AppReviewPromptEligibility.hasSuccessfulUsage(lastRefreshError: nil, results: [creditsResult]))
    }

    @MainActor
    func testAutoRefreshIntervalDefaultsToOffAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.autoRefreshInterval, .off)

        store.updateAutoRefreshInterval(.fiveMinutes)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.autoRefreshInterval, .fiveMinutes)
    }

    @MainActor
    func testWidgetRefreshIntervalDefaultsToThirtyMinutesAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.widgetRefreshInterval, .thirtyMinutes)

        store.updateWidgetRefreshInterval(.oneHour)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.widgetRefreshInterval, .oneHour)
    }

    func testWidgetSnapshotStoreRoundTripsSnapshotAndRefreshInterval() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let generatedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: generatedAt,
            results: [
                CodexBarWidgetProviderSnapshot(
                    accountID: "openCodeZen",
                    providerID: "openCodeZen",
                    title: "OpenCode ZEN",
                    subtitle: "Balance",
                    groupID: "work",
                    groupName: "Work",
                    bars: [
                        CodexBarWidgetUsageBarSnapshot(
                            id: "codex.personal.0.five-hour",
                            label: "5 hour usage limit",
                            fractionUsed: 0.25,
                            usageText: "25%",
                            resetDescription: "Resets 4h",
                            severity: .normal,
                            projectedFraction: 1,
                            projectionDescription: "Projected 100% at current pace - Limit hit Wed 11:00 PM local time - 1h early",
                            projectedSeverity: .critical
                        ),
                    ],
                    creditsRemaining: 42.25,
                    fetchedAt: generatedAt,
                    severity: .critical
                ),
            ]
        )

        WidgetSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        WidgetSnapshotStore.saveRefreshInterval(.threeHours, defaults: defaults)

        XCTAssertEqual(WidgetSnapshotStore.loadSnapshot(defaults: defaults), snapshot)
        XCTAssertEqual(WidgetSnapshotStore.loadRefreshInterval(defaults: defaults), .threeHours)
    }

    func testWidgetSnapshotStoreRoundTripsBuilderConfiguration() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let configuration = CodexBarWidgetBuilderConfiguration(
            layout: .fourTiles,
            selectedTileIDs: [
                "bar.codex.personal.0.five-hour",
                "bar.codex.personal.1.weekly",
                nil,
                "provider.openRouter.work",
            ],
            displayModes: [.fullBar, .compactPercent, .automatic, .balanceOnly]
        )

        WidgetSnapshotStore.saveBuilderConfiguration(configuration, defaults: defaults)

        XCTAssertEqual(WidgetSnapshotStore.loadBuilderConfiguration(defaults: defaults), configuration)
    }

    func testWidgetBuilderConfigurationTreatsLayoutAndDisplayAsCustomizations() {
        XCTAssertFalse(CodexBarWidgetBuilderConfiguration.default.hasCustomizations)

        XCTAssertTrue(
            CodexBarWidgetBuilderConfiguration(layout: .twoTiles).hasCustomizations
        )
        XCTAssertTrue(
            CodexBarWidgetBuilderConfiguration(displayModes: [.fullBar]).hasCustomizations
        )
        XCTAssertTrue(
            CodexBarWidgetBuilderConfiguration(selectedTileIDs: [nil, "bar.codex.personal.0.five-hour"])
                .hasCustomizations
        )
    }

    func testWidgetSnapshotBuilderTilesIncludeProviderSummaryAndGranularBars() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: generatedAt,
            results: [
                CodexBarWidgetProviderSnapshot(
                    accountID: "codex.personal",
                    providerID: "codex",
                    title: "ChatGPT / Codex",
                    subtitle: "Personal",
                    bars: [
                        CodexBarWidgetUsageBarSnapshot(
                            id: "codex.personal.0.five-hour",
                            label: "5-hour",
                            fractionUsed: 0.42,
                            usageText: "42%",
                            resetDescription: "Resets 2h",
                            severity: .normal
                        ),
                        CodexBarWidgetUsageBarSnapshot(
                            id: "codex.personal.1.weekly",
                            label: "Weekly",
                            fractionUsed: 0.81,
                            usageText: "81%",
                            resetDescription: "Resets Sun",
                            severity: .warning
                        ),
                    ],
                    creditsRemaining: nil,
                    fetchedAt: generatedAt,
                    severity: .warning
                ),
                CodexBarWidgetProviderSnapshot(
                    accountID: "openRouter.work",
                    providerID: "openRouter",
                    title: "OpenRouter",
                    subtitle: "API Key",
                    bars: [],
                    creditsRemaining: 9.75,
                    fetchedAt: generatedAt,
                    severity: .normal
                ),
            ]
        )

        let tiles = snapshot.builderTiles

        XCTAssertEqual(
            tiles.map(\.id),
            [
                "provider.codex.personal",
                "bar.codex.personal.0.five-hour",
                "bar.codex.personal.1.weekly",
                "provider.openRouter.work",
            ]
        )
        XCTAssertEqual(try XCTUnwrap(tiles.first { $0.id == "provider.codex.personal" }).value, "81%")
        XCTAssertEqual(try XCTUnwrap(tiles.first { $0.id == "provider.openRouter.work" }).value, "$9.75")
    }

    func testWidgetSnapshotBuilderIncludesCurrencyAwareMonetaryTiles() throws {
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_475_200),
            results: [
                CodexBarWidgetProviderSnapshot(
                    accountID: "claude.personal",
                    providerID: "claude",
                    title: "Claude",
                    subtitle: "Live Claude usage",
                    bars: [],
                    creditsRemaining: nil,
                    monetaryMetrics: [
                        CodexBarWidgetMonetaryMetricSnapshot(
                            kind: ProviderMonetaryMetricKind.spent.rawValue,
                            label: "Usage credits spent",
                            minorUnits: 1250,
                            currencyCode: "EUR",
                            decimalPlaces: 2,
                            detail: "Month to date"
                        ),
                    ],
                    fetchedAt: Date(timeIntervalSince1970: 1_788_475_200),
                    severity: .normal
                ),
            ]
        )

        let tile = try XCTUnwrap(snapshot.builderTiles.first { $0.id == "provider.claude.personal" })

        XCTAssertEqual(tile.title, "Usage credits spent")
        XCTAssertEqual(tile.subtitle, "Month to date")
        XCTAssertTrue(tile.value.contains("12"))
        XCTAssertTrue(tile.value.contains("50"))
        XCTAssertEqual(snapshot.results.first?.summaryMonetaryMetric?.label, "Usage credits spent")
        XCTAssertTrue(snapshot.results.first?.standaloneMonetaryMetrics.isEmpty ?? false)
        XCTAssertEqual(snapshot.builderTiles.count, 1)

        let malformedMetric = CodexBarWidgetMonetaryMetricSnapshot(
            kind: "spent",
            label: "Malformed persisted metric",
            minorUnits: 10,
            currencyCode: "USD",
            decimalPlaces: -1,
            detail: nil
        )
        XCTAssertFalse(malformedMetric.formattedAmount.isEmpty)
    }

    @MainActor
    func testWidgetSnapshotPublisherPropagatesProviderGroup() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let generatedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Work"))
        var configuration = store.addAccount(for: .openCodeZen)
        configuration.groupID = group.id
        configuration.openCodeWorkspaceId = "workspace"
        XCTAssertTrue(store.update(configuration))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode ZEN",
            subtitle: "Balance",
            bars: [
                UsageBar(label: "Balance", used: 1, limit: 4),
            ],
            creditsRemaining: 12.25,
            fetchedAt: generatedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults
        )

        let provider = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        XCTAssertEqual(provider.groupID, group.id)
        XCTAssertEqual(provider.groupName, "Work")
    }

    @MainActor
    func testWidgetSnapshotPublisherUsesSmartDashboardOrdering() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var highBalanceConfiguration = store.addAccount(for: .openRouter)
        highBalanceConfiguration.accountLabel = "High Balance"
        XCTAssertTrue(store.update(highBalanceConfiguration))
        store.saveSecret("openrouter-high", for: highBalanceConfiguration)

        var lowBalanceConfiguration = store.addAccount(for: .openRouter)
        lowBalanceConfiguration.accountLabel = "Low Balance"
        XCTAssertTrue(store.update(lowBalanceConfiguration))
        store.saveSecret("openrouter-low", for: lowBalanceConfiguration)
        store.updateDashboardOrderingMode(.smart)

        let highBalance = ProviderUsageResult(
            accountID: highBalanceConfiguration.id,
            providerID: .openRouter,
            title: highBalanceConfiguration.displayName,
            subtitle: "Balance",
            bars: [],
            creditsRemaining: 50,
            fetchedAt: fetchedAt
        )
        let lowBalance = ProviderUsageResult(
            accountID: lowBalanceConfiguration.id,
            providerID: .openRouter,
            title: lowBalanceConfiguration.displayName,
            subtitle: "Balance",
            bars: [],
            creditsRemaining: 2,
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [highBalance, lowBalance],
            configurationStore: store,
            snapshotDefaults: defaults
        )

        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(snapshot.results.map(\.accountID), [lowBalanceConfiguration.id, highBalanceConfiguration.id])
    }

    func testProviderAccountConfigurationDecodesLegacyAccountWithoutGroup() throws {
        let json = """
        {
          "id": "codex.personal",
          "providerID": "codex",
          "isEnabled": true,
          "accountLabel": "Personal",
          "authMethod": "browserSession"
        }
        """

        let configuration = try JSONDecoder().decode(
            ProviderAccountConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(configuration.groupID)
    }

    func testWidgetSnapshotStoreDecodesLegacyUsageBarsWithoutProjectionFields() throws {
        let json = """
        {
          "generatedAt": 1788475200,
          "results": [
            {
              "accountID": "codex.personal",
              "providerID": "codex",
              "title": "Codex",
              "subtitle": "Pro",
              "bars": [
                {
                  "id": "codex.personal.0.five-hour",
                  "label": "5 hour usage limit",
                  "fractionUsed": 0.25,
                  "usageText": "25%",
                  "resetDescription": "Resets 4h",
                  "severity": "normal"
                }
              ],
              "creditsRemaining": null,
              "fetchedAt": 1788475200,
              "severity": "normal"
            }
          ]
        }
        """

        let snapshot = try JSONDecoder().decode(CodexBarWidgetSnapshot.self, from: Data(json.utf8))
        let bar = try XCTUnwrap(snapshot.results.first?.bars.first)

        XCTAssertNil(bar.projectedFraction)
        XCTAssertNil(bar.projectionDescription)
        XCTAssertNil(bar.projectedSeverity)
        XCTAssertEqual(bar.effectiveSeverity, .normal)
        XCTAssertEqual(bar.effectiveFractionUsed, 0.25)
        XCTAssertNil(snapshot.results.first?.monetaryMetrics)
        XCTAssertNil(snapshot.results.first?.usageMessages)
    }

    @MainActor
    func testAppAppearanceDefaultsToSystemAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.appAppearance, .system)

        store.updateAppAppearance(.dark)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.appAppearance, .dark)
    }

    @MainActor
    func testDashboardCardOrderPersistsAndRemovesDuplicates() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        store.updateDashboardCardOrder(["claude", "codex", "claude", "copilot"])

        XCTAssertEqual(store.dashboardCardOrder, ["claude", "codex", "copilot"])

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.dashboardCardOrder, ["claude", "codex", "copilot"])
    }

    @MainActor
    func testDashboardOrderingModeDefaultsToManualAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.dashboardOrderingMode, .manual)

        store.updateDashboardOrderingMode(.smart)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.dashboardOrderingMode, .smart)
    }

    func testDashboardUsageSorterOrdersSmartResultsByUrgency() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodStart = now.addingTimeInterval(-2 * 60 * 60)
        let periodEnd = now.addingTimeInterval(3 * 60 * 60)
        let criticalProjection = makeHistoryResult(
            accountID: "critical.projection",
            providerID: .codex,
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 20,
                    limit: 100,
                    projectionCurrent: 80,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )
        let warningUsage = makeHistoryResult(
            accountID: "warning.usage",
            providerID: .codex,
            fetchedAt: now,
            used: 80
        )
        let lowBalance = makeHistoryResult(
            accountID: "balance.low",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 2
        )
        let highBalance = makeHistoryResult(
            accountID: "balance.high",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 20
        )
        let manualSecond = makeHistoryResult(
            accountID: "manual.second",
            providerID: .claude,
            fetchedAt: now,
            used: 20
        )
        let manualFirst = makeHistoryResult(
            accountID: "manual.first",
            providerID: .cursor,
            fetchedAt: now,
            used: 20
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [manualSecond, highBalance, warningUsage, manualFirst, lowBalance, criticalProjection],
            mode: .smart,
            manualOrder: ["manual.first", "manual.second"],
            now: now
        )

        XCTAssertEqual(
            ordered.map(\.accountID),
            ["critical.projection", "warning.usage", "balance.low", "balance.high", "manual.first", "manual.second"]
        )
    }

    func testDashboardUsageSorterKeepsManualOrderingWhenManualModeIsSelected() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let critical = makeHistoryResult(
            accountID: "critical",
            providerID: .codex,
            fetchedAt: now,
            used: 95
        )
        let normal = makeHistoryResult(
            accountID: "normal",
            providerID: .cursor,
            fetchedAt: now,
            used: 10
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [critical, normal],
            mode: .manual,
            manualOrder: ["normal", "critical"],
            now: now
        )

        XCTAssertEqual(ordered.map(\.accountID), ["normal", "critical"])
    }

    func testDashboardUsageSorterKeepsExhaustedProjectionsAheadOfFutureHits() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodStart = now.addingTimeInterval(-60 * 60)
        let periodEnd = now.addingTimeInterval(4 * 60 * 60)
        let exhausted = makeHistoryResult(
            accountID: "projection.exhausted",
            providerID: .codex,
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 100,
                    limit: 100,
                    projectionCurrent: 120,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )
        let futureHit = makeHistoryResult(
            accountID: "projection.future",
            providerID: .codex,
            fetchedAt: now,
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 95,
                    limit: 100,
                    projectionCurrent: 80,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ]
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [futureHit, exhausted],
            mode: .smart,
            manualOrder: [],
            now: now
        )

        XCTAssertEqual(ordered.map(\.accountID), ["projection.exhausted", "projection.future"])
    }

    @MainActor
    func testProviderGroupsPersistAndAssignAccounts() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let group = store.addGroup(named: " Work ")
        var account = store.addAccount(for: .codex)
        account.groupID = group?.id

        XCTAssertTrue(store.update(account))

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.groups.map(\.name), ["Work"])
        XCTAssertEqual(reloadedStore.configuration(accountID: account.id)?.groupID, group?.id)
    }

    @MainActor
    func testRemovingProviderGroupUngroupsAssignedAccounts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Relias"))
        var account = store.addAccount(for: .copilot)
        account.groupID = group.id
        XCTAssertTrue(store.update(account))

        store.removeGroup(group)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: account.id)?.groupID)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertNil(reloadedStore.configuration(accountID: account.id)?.groupID)
    }

    @MainActor
    func testProviderGroupNamesMustBeUnique() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertNotNil(store.addGroup(named: "Engineering"))
        XCTAssertNil(store.addGroup(named: " engineering "))
        XCTAssertEqual(store.lastError, "Group names must be unique.")
    }

    @MainActor
    func testProviderConfigurationsSortByGroupName() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let beta = try XCTUnwrap(store.addGroup(named: "Beta"))
        let alpha = try XCTUnwrap(store.addGroup(named: "Alpha"))
        let ungrouped = store.addAccount(for: .openRouter)
        var betaAccount = store.addAccount(for: .codex)
        var alphaAccount = store.addAccount(for: .claude)
        betaAccount.groupID = beta.id
        alphaAccount.groupID = alpha.id

        XCTAssertTrue(store.update(betaAccount))
        XCTAssertTrue(store.update(alphaAccount))

        XCTAssertEqual(
            store.configurations.map(\.id),
            [ungrouped.id, alphaAccount.id, betaAccount.id]
        )

        var renamedBeta = beta
        renamedBeta.name = "Aardvark"
        XCTAssertTrue(store.updateGroup(renamedBeta))

        XCTAssertEqual(
            store.configurations.map(\.id),
            [ungrouped.id, betaAccount.id, alphaAccount.id]
        )
    }

    @MainActor
    func testUsageAlertSettingsPersistAndClamp() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertFalse(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.usageThreshold, 0.80)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 5.00)

        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertUsageThreshold(1.8)
        store.updateUsageAlertBalanceThreshold(-5)
        store.updateUsageAlertIncludesSeverityAlerts(false)
        store.updateUsageAlertActiveIDs(["usage.codex.weekly", "balance.openRouter"])

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertTrue(reloadedStore.usageAlertSettings.isEnabled)
        XCTAssertEqual(reloadedStore.usageAlertSettings.usageThreshold, 1.0)
        XCTAssertEqual(reloadedStore.usageAlertSettings.balanceThreshold, 0)
        XCTAssertFalse(reloadedStore.usageAlertSettings.includesSeverityAlerts)
        XCTAssertEqual(reloadedStore.usageAlertActiveIDs, ["usage.codex.weekly", "balance.openRouter"])
    }

    @MainActor
    func testUsageAlertSettingsChangeClearsActiveSuppressionState() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        store.updateUsageAlertActiveIDs(["usage.codex.weekly"])
        store.updateUsageAlertUsageThreshold(0.90)

        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)
    }

    func testUsageAlertEvaluatorSendsOnceUntilRecovery() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 81,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.notifications.first?.title, "Codex 5-hour alert")
        XCTAssertEqual(first.notifications.first?.accountID, "codex.personal")
        XCTAssertEqual(first.notifications.first?.kind, .usage)
        XCTAssertEqual(first.notifications.first?.body, "5-hour at 81%. 81 of 100 used. Alert threshold: 80%.")
        XCTAssertEqual(first.activeAlerts.count, 1)
        XCTAssertEqual(first.activeAlerts.first?.accountID, "codex.personal")
        XCTAssertEqual(first.activeAlerts.first?.title, "5-hour at 81%")

        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.activeAlerts, first.activeAlerts)

        let recoveredResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 40,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let recovered = UsageAlertEvaluator.evaluate(
            results: [recoveredResult],
            settings: settings,
            activeAlertIDs: repeated.activeAlertIDs
        )
        XCTAssertTrue(recovered.activeAlertIDs.isEmpty)

        let crossedAgain = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: recovered.activeAlertIDs
        )
        XCTAssertEqual(crossedAgain.notifications.count, 1)
    }

    func testUsageAlertEvaluatorUsesInjectedNowForResetDescription() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = now.addingTimeInterval(2 * 60 * 60)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "5-hour",
                    used: 81,
                    limit: 100,
                    resetDescription: "stale reset text",
                    resetsAt: resetAt,
                    resetDisplayStyle: .relativeWithLocalTime
                ),
            ],
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        let body = try XCTUnwrap(evaluation.notifications.first?.body)
        XCTAssertTrue(body.contains("Resets 2h 0m"))
        XCTAssertFalse(body.contains("stale reset text"))
    }

    func testUsageAlertEvaluatorUsesStableUsageKeysForMutableLabels() {
        let firstResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    label: "On-demand $12.00 / $20.00",
                    used: 12,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let secondResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    label: "On-demand $14.00 / $20.00",
                    used: 14,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let settings = UsageAlertSettings(isEnabled: true, usageThreshold: 0.50)

        let first = UsageAlertEvaluator.evaluate(results: [firstResult], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [secondResult],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.activeAlertIDs, ["usage.cursor.main.on-demand"])
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorDeduplicatesBarsWithSameStableKey() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "On-demand $12.00 / $20.00", used: 12, limit: 20),
                UsageBar(label: "On-demand $18.00 / $30.00", used: 18, limit: 30),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.50,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorReportsBalanceThreshold() {
        let result = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(isEnabled: true, balanceThreshold: 5)

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "OpenRouter balance alert")
        XCTAssertEqual(evaluation.notifications.first?.accountID, "openRouter.main")
        XCTAssertEqual(evaluation.notifications.first?.kind, .balance)
        XCTAssertTrue(evaluation.activeAlertIDs.contains("balance.openRouter.main"))
        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Balance below $5.00")
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "$4.50 remaining for OpenRouter.")
    }

    func testUsageAlertEvaluatorAlertsScopedClaudeBarsWithoutTreatingHeadroomAsBalance() {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Fable weekly limit", used: 85, limit: 100),
            ],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 250,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.usage])
        XCTAssertEqual(evaluation.notifications.first?.title, "Claude Fable weekly limit alert")
        XCTAssertFalse(evaluation.activeAlertIDs.contains("balance.claude.personal"))

        let cappedResult = ProviderUsageResult(
            accountID: "claude.capped",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 5000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 5000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let cappedEvaluation = UsageAlertEvaluator.evaluate(
            results: [cappedResult],
            settings: UsageAlertSettings(isEnabled: true, includesSeverityAlerts: true),
            activeAlertIDs: []
        )
        XCTAssertEqual(cappedResult.highestSeverity, .critical)
        XCTAssertEqual(cappedEvaluation.notifications.map(\.kind), [.severity])
        XCTAssertEqual(
            cappedEvaluation.activeAlerts.first?.message,
            "The monthly usage-credit spend limit has been reached."
        )

        let zeroCapResult = ProviderUsageResult(
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 0,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Monthly spend limit",
                    minorUnits: 0,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        XCTAssertEqual(zeroCapResult.highestSeverity, .normal)
    }

    func testUsageAlertEvaluatorReturnsCardScopedActiveAlerts() {
        let codex = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Weekly", used: 90, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let cursor = ProviderUsageResult(
            accountID: "cursor.work",
            providerID: .cursor,
            title: "Cursor Work",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Included", used: 40, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let openRouter = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 2,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [codex, cursor, openRouter],
            settings: settings,
            activeAlertIDs: []
        )
        let activeAlertsByAccountID = Dictionary(grouping: evaluation.activeAlerts, by: \.accountID)

        XCTAssertEqual(Set(activeAlertsByAccountID.keys), ["codex.personal", "openRouter.main"])
        XCTAssertEqual(activeAlertsByAccountID["codex.personal"]?.map(\.kind), [.usage])
        XCTAssertEqual(activeAlertsByAccountID["openRouter.main"]?.map(\.kind), [.balance])
        XCTAssertNil(activeAlertsByAccountID["cursor.work"])
    }

    func testUsageAlertEvaluatorUsesWarningPresentationBelowSeverityThreshold() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "5-hour", used: 55, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.50,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.activeAlerts.first?.severity, .warning)
    }

    func testUsageAlertEvaluatorUsesSeverityWhenSpecificThresholdsDoNotMatch() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Included usage - Total 76%",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    label: "Total",
                    used: 76,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "Cursor Warning alert")
        XCTAssertTrue(evaluation.activeAlertIDs.contains("severity.cursor.main"))
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "Total is currently at 76%.")
    }

    func testUsageAlertEvaluatorExplainsProjectedSeverity() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 40,
                    limit: 100,
                    projectionCurrent: 40,
                    projectionLimit: 100,
                    projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
                    projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60)
                ),
            ],
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            includesSeverityAlerts: true
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Critical status")
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "Weekly is projected to reach 100%.")
    }

    func testUsageAlertEvaluatorReportsSeverityAlongsideSpecificThresholds() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    label: "Weekly usage limit",
                    used: 95,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.map(\.title), ["Codex Weekly usage limit alert", "Codex Critical alert"])
        XCTAssertEqual(first.activeAlertIDs, ["usage.codex.personal.weekly-usage-limit", "severity.codex.personal"])
        XCTAssertEqual(first.activeAlerts.map(\.accountID), ["codex.personal", "codex.personal"])
        XCTAssertTrue(repeated.notifications.isEmpty)
    }

    @MainActor
    func testProviderConfigurationStoreStartsWithoutAccounts() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertTrue(store.configurations.isEmpty)
    }

    @MainActor
    func testProviderConfigurationStorePreservesCopilotBrowserSession() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let oldCopilotConfiguration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession
        )
        let data = try! JSONEncoder().encode([oldCopilotConfiguration])
        defaults.set(data, forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertEqual(store.configuration(for: .copilot).authMethod, .browserSession)
    }

    @MainActor
    func testProviderConfigurationStoreSupportsMultipleAccountsForProvider() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let original = store.addAccount(for: .copilot)
        let added = store.addAccount(for: .copilot)

        XCTAssertEqual(store.configurations(for: .copilot).count, 2)
        XCTAssertNotEqual(original.id, added.id)
        XCTAssertEqual(
            ProviderConfigurationStore.keychainAccount(for: original).hasPrefix("providerAccount.copilot."),
            true
        )
        XCTAssertTrue(
            ProviderConfigurationStore.keychainAccount(for: added)
                .hasPrefix("providerAccount.copilot.")
        )
    }

    @MainActor
    func testCursorIdentityChangeRemovesStaleEmailButPreservesCustomLabel() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        var cursor = store.addAccount(for: .cursor)
        cursor.accountLabel = "franz_hemmer@hotmail.com"
        XCTAssertTrue(store.update(cursor))

        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "")

        cursor.accountLabel = "Work Cursor"
        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "Work Cursor")

        cursor.accountLabel = "team@acme"
        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "team@acme")
    }

    @MainActor
    func testConnectingCursorAccountPersistsCredentialAndClearsStaleEmail() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var cursor = store.addAccount(for: .cursor)
        cursor.accountLabel = "old@example.com"
        XCTAssertTrue(store.update(cursor))

        let connected = try XCTUnwrap(
            store.connectCursorAccount(cursor, credential: "replacement-token")
        )

        XCTAssertEqual(connected.accountLabel, "")
        XCTAssertEqual(connected.displayName, "Cursor")
        XCTAssertEqual(store.configuration(accountID: cursor.id), connected)
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: cursor)),
            "replacement-token"
        )
        XCTAssertTrue(store.hasSecret(for: cursor))
    }

    @MainActor
    func testDisconnectingCursorAccountPreservesOtherCursorCredential() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var first = store.addAccount(for: .cursor)
        first.accountLabel = "first@example.com"
        XCTAssertTrue(store.update(first))
        let second = store.addAccount(for: .cursor)
        store.saveSecret("first-token", for: first)
        store.saveSecret("second-token", for: second)

        let disconnected = try XCTUnwrap(store.disconnectCursorAccount(first))

        XCTAssertFalse(store.hasSecret(for: first))
        XCTAssertEqual(disconnected.accountLabel, "")
        XCTAssertEqual(disconnected.displayName, "Cursor")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)),
            "second-token"
        )
        XCTAssertTrue(store.hasSecret(for: second))
    }

    @MainActor
    func testFailedCursorCredentialReplacementPreservesExistingIdentity() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = FailingSaveSecretStore(secret: "existing-token")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var cursor = store.addAccount(for: .cursor)
        cursor.accountLabel = "existing@example.com"
        XCTAssertTrue(store.update(cursor))

        XCTAssertNil(store.connectCursorAccount(cursor, credential: "replacement-token"))
        XCTAssertEqual(store.configuration(accountID: cursor.id)?.accountLabel, "existing@example.com")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: cursor)),
            "existing-token"
        )
    }

    @MainActor
    func testProviderConfigurationStoreRequiresClaudeSecretForBrowserSession() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let claude = store.addAccount(for: .claude)

        XCTAssertFalse(store.isConfigured(claude))
        XCTAssertEqual(store.statusText(for: claude), "Not configured - sign in with Claude")

        store.saveSecret("claude-token", for: claude)

        XCTAssertTrue(store.isConfigured(claude))
        XCTAssertEqual(store.statusText(for: claude), "Claude 1 - live usage enabled")
    }

    @MainActor
    func testOpenCodeZenDisplaysOnDashboardWhenKeyIsSavedBeforeWorkspace() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let openCodeZen = store.addAccount(for: .openCodeZen)

        XCTAssertFalse(store.isConfigured(openCodeZen))
        XCTAssertFalse(store.shouldDisplayOnDashboard(openCodeZen))

        store.saveSecret("oczen-test-key", for: openCodeZen)

        XCTAssertFalse(store.isConfigured(openCodeZen))
        XCTAssertTrue(store.shouldDisplayOnDashboard(openCodeZen))
        XCTAssertEqual(store.statusText(for: openCodeZen), "Not configured - enter OpenCode workspace ID")
    }

    @MainActor
    func testProviderConfigurationStoreRejectsDuplicateAccountNames() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        var first = store.addAccount(for: .copilot)
        first.accountLabel = "Work"
        store.update(first)

        var second = store.addAccount(for: .codex)
        second.accountLabel = "work"
        store.update(second)

        XCTAssertEqual(store.lastError, "Account names must be unique.")
        XCTAssertNotEqual(store.configuration(accountID: second.id)?.accountLabel, "work")
    }

    @MainActor
    func testProviderConfigurationStoreRejectsDuplicateFallbackDisplayNames() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        var first = store.addAccount(for: .copilot)
        first.accountLabel = "Work Copilot"
        store.update(first)
        var second = store.addAccount(for: .copilot)
        second.accountLabel = "work copilot"

        XCTAssertFalse(store.update(second))
        XCTAssertEqual(store.lastError, "Account names must be unique.")
        XCTAssertNotEqual(store.configuration(accountID: second.id)?.displayName, "work copilot")
    }

    @MainActor
    func testProviderConfigurationStoreResetRemovesAccountsAndSecrets() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let account = store.addAccount(for: .claude)
        store.saveSecret("token", for: account)
        XCTAssertTrue(store.hasSecret(for: account))

        store.resetAccounts()

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertFalse(store.hasSecret(for: account))
        XCTAssertNil(try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)))
    }

    func testCodexAuthURLUsesBrowserLoginFlow() throws {
        let url = CodexWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1455/auth/callback",
            state: "state",
            codeChallenge: "challenge"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1455/auth/callback")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "originator"), "codex_cli_rs")
        XCTAssertEqual(components.queryItemValue(named: "codex_cli_simplified_flow"), "true")
    }

    func testCodexTokenRequestBodyUsesPKCECodeExchange() {
        let body = String(
            data: CodexWebAuthService.makeTokenRequestBody(
                code: "code value",
                redirectURI: "http://localhost:1455/auth/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=authorization_code&code=code%20value&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=verifier%20value"
        )
    }

    func testCodexRefreshTokenRequestBodyUsesRefreshGrant() {
        let body = String(
            data: CodexWebAuthService.makeRefreshTokenRequestBody(refreshToken: "refresh value"),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=refresh_token&refresh_token=refresh%20value&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
        )
    }

    func testCodexAuthExtractsChatGPTAccountID() {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"chatgpt_account_id":"account-id"}"#.base64URLEncodedForTest()
        let token = "\(header).\(payload).signature"

        XCTAssertEqual(CodexWebAuthService.accountID(from: token), "account-id")
    }

    func testCodexCredentialsParserReadsCliAuthJson() {
        let credentials = CodexCredentialsParser.parse("""
        {
          "tokens": {
            "access_token": "access-token",
            "account_id": "account-id"
          }
        }
        """)

        XCTAssertEqual(credentials, CodexCredentials(accessToken: "access-token", accountID: "account-id"))
    }

    func testCodexCredentialsParserReadsAccountIDFromAccessJWT() throws {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"chatgpt_account_id":"access-account"}"#.base64URLEncodedForTest()
        let accessToken = "\(header).\(payload).signature"

        let credentials = try XCTUnwrap(CodexCredentialsParser.parse("""
        {"tokens":{"access_token":"\(accessToken)"}}
        """))

        XCTAssertEqual(credentials.accountID, "access-account")
    }

    func testCodexCredentialsParserRetainsOAuthLifecycleFieldsAndLegacyTokens() throws {
        let credentials = try XCTUnwrap(CodexCredentialsParser.parse("""
        {
          "tokens": {
            "access_token": "access-token",
            "refresh_token": "refresh-token",
            "id_token": "id-token",
            "account_id": "account-id",
            "expires_at": 2000000000000
          }
        }
        """))

        XCTAssertEqual(credentials.accessToken, "access-token")
        XCTAssertEqual(credentials.refreshToken, "refresh-token")
        XCTAssertEqual(credentials.idToken, "id-token")
        XCTAssertEqual(credentials.accountID, "account-id")
        XCTAssertEqual(credentials.expiresAt, 2_000_000_000)
        XCTAssertEqual(
            CodexCredentialsParser.parse("legacy-access-token"),
            CodexCredentials(accessToken: "legacy-access-token")
        )

        let roundTripped = try XCTUnwrap(
            CodexCredentialsParser.parse(CodexCredentialsParser.storedCredential(from: credentials))
        )
        XCTAssertEqual(roundTripped, credentials)

        let accessOnly = CodexCredentialsParser.storedCredential(from: CodexCredentials(accessToken: "access-only"))
        let accessOnlyData = try XCTUnwrap(accessOnly.data(using: .utf8))
        let accessOnlyRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: accessOnlyData) as? [String: Any]
        )
        let accessOnlyTokens = try XCTUnwrap(accessOnlyRoot["tokens"] as? [String: Any])
        XCTAssertEqual(accessOnlyTokens.count, 1)
        XCTAssertEqual(accessOnlyTokens["access_token"] as? String, "access-only")
    }

    func testCopilotAuthURLUsesGitHubBrowserCallbackFlow() throws {
        let url = CopilotWebAuthService.authorizationURL(
            clientID: "client id",
            redirectURI: "http://127.0.0.1:1456/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/login/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "client_id"), "client id")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://127.0.0.1:1456/callback")
        XCTAssertEqual(components.queryItemValue(named: "scope"), "repo read:org gist")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "prompt"), "select_account")
    }

    func testCopilotTokenRequestBodyUsesAuthorizationCodeExchange() {
        let body = String(
            data: CopilotWebAuthService.makeTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                code: "code value",
                redirectURI: "http://127.0.0.1:1456/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "client_id=client&client_secret=secret&code=code%20value&redirect_uri=http%3A%2F%2F127.0.0.1%3A1456%2Fcallback&code_verifier=verifier%20value"
        )
    }

    func testCopilotRefreshTokenRequestBodyUsesRefreshGrant() {
        let body = String(
            data: CopilotWebAuthService.makeRefreshTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                refreshToken: "refresh value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "client_id=client&client_secret=secret&grant_type=refresh_token&refresh_token=refresh%20value"
        )
    }

    func testClaudeAuthURLUsesBrowserCallbackFlow() throws {
        let url = ClaudeWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1461/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "code"), "true")
        XCTAssertEqual(components.queryItemValue(named: "client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1461/callback")
        XCTAssertEqual(components.queryItemValue(named: "scope"), "org:create_api_key user:profile user:inference user:sessions:claude_code")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
    }

    func testClaudeTokenRequestBodyUsesAuthorizationCodeExchange() throws {
        let data = ClaudeWebAuthService.makeTokenRequestBody(
            code: "code value",
            redirectURI: "http://localhost:1461/callback",
            state: "state value",
            codeVerifier: "verifier value"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "code value")
        XCTAssertEqual(body["redirect_uri"], "http://localhost:1461/callback")
        XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(body["code_verifier"], "verifier value")
        XCTAssertEqual(body["state"], "state value")
    }

    func testClaudeCredentialsParserReadsClaudeCodeOAuthShape() {
        let credentials = ClaudeCredentialsParser.parse("""
        {
          "claudeAiOauth": {
            "subscriptionType": "pro",
            "rateLimitTier": "standard",
            "expiresAt": 1893456000000,
            "accessToken": "access-token",
            "refreshToken": "refresh-token"
          }
        }
        """)

        XCTAssertEqual(
            credentials,
            ClaudeCredentials(
                subscriptionType: "pro",
                rateLimitTier: "standard",
                expiresAt: 1_893_456_000_000,
                accessToken: "access-token",
                refreshToken: "refresh-token"
            )
        )
    }

    func testCursorAuthURLUsesBrowserPollingFlow() throws {
        let url = CursorWebAuthService.authorizationURL(
            uuid: "request-id",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "cursor.com")
        XCTAssertEqual(components.path, "/loginDeepControl")
        XCTAssertEqual(components.queryItemValue(named: "challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "mode"), "login")
        XCTAssertEqual(components.queryItemValue(named: "redirectTarget"), "cli")
    }

    func testCursorPollRequestUsesPKCEVerifier() throws {
        let request = CursorWebAuthService.pollRequest(uuid: "request-id", codeVerifier: "verifier")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api2.cursor.sh")
        XCTAssertEqual(components.path, "/auth/poll")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "verifier"), "verifier")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    @MainActor
    func testCursorBrowserSignInPollsAndStoresSessionShape() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, "api2.cursor.sh")
            XCTAssertEqual(components.path, "/auth/poll")
            XCTAssertNotNil(components.queryItemValue(named: "uuid"))
            XCTAssertNotNil(components.queryItemValue(named: "verifier"))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"accessToken":"cursor-access","refreshToken":"cursor-refresh","authId":"auth0|user-id"}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        var presentedURL: URL?
        let result = try await service.signIn { url in
            presentedURL = url
            return true
        }
        let authURL = try XCTUnwrap(presentedURL)
        let authComponents = try XCTUnwrap(URLComponents(url: authURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(authComponents.host, "cursor.com")
        XCTAssertEqual(result.accessToken, "cursor-access")
        XCTAssertEqual(result.refreshToken, "cursor-refresh")
        XCTAssertTrue(result.storedCredential.contains(#""accessToken": "cursor-access""#))
    }

#if canImport(AuthenticationServices) && canImport(UIKit)
    @MainActor
    func testCursorBrowserSessionUsesEphemeralStorage() {
        let session = CursorWebAuthenticationPresenter.makeSession(
            url: URL(string: "https://cursor.com/loginDeepControl")!
        ) { _ in }

        XCTAssertTrue(session.prefersEphemeralWebBrowserSession)
    }
#endif

    func testCursorBrowserSessionIgnoresStaleCompletionAfterRetry() {
        var generation = CursorWebAuthenticationSessionGeneration()
        let firstSessionID = generation.start()
        let retrySessionID = generation.start()

        XCTAssertFalse(generation.complete(firstSessionID))
        XCTAssertTrue(generation.complete(retrySessionID))
        XCTAssertFalse(generation.complete(retrySessionID))
    }

    @MainActor
    func testCursorSignInStopsWhenPrivateBrowserCannotStart() async {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )
        MockURLProtocol.handler = { _ in
            XCTFail("Token polling should not start when the browser session cannot start.")
            throw URLError(.badServerResponse)
        }
        defer {
            MockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { _ in false }
            XCTFail("Expected Cursor sign-in to reject a failed browser session.")
        } catch {
            XCTAssertEqual(error as? CursorWebAuthService.AuthError, .couldNotStartBrowserSession)
        }
    }

    func testCopilotCredentialsParserReadsStoredJSONAndRawToken() {
        XCTAssertEqual(
            CopilotCredentialsParser.parse(#"{"accessToken":"token","username":"octocat"}"#),
            CopilotCredentials(accessToken: "token", username: "octocat")
        )
        XCTAssertEqual(
            CopilotCredentialsParser.parse("gho_raw_token"),
            CopilotCredentials(accessToken: "gho_raw_token")
        )
    }

    func testCopilotCredentialsParserRetainsRefreshAndExpiryFields() throws {
        let credentials = CopilotCredentials(
            accessToken: "access-token",
            username: "octocat",
            refreshToken: "refresh-token",
            expiresAt: 2_000_000_000,
            refreshTokenExpiresAt: 2_100_000_000
        )

        let stored = CopilotCredentialsParser.storedCredential(from: credentials)
        XCTAssertEqual(try XCTUnwrap(CopilotCredentialsParser.parse(stored)), credentials)
        XCTAssertEqual(
            CopilotCredentialsParser.parse("legacy-token"),
            CopilotCredentials(accessToken: "legacy-token")
        )
    }

    func testCopilotUsageRequestMatchesWindowsCopilotHeaders() {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            usageEndpoint: URL(string: "https://api.github.com/copilot_internal/user")!
        )

        let request = provider.makeUsageRequest(accessToken: "github-token")

        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitHubCopilotChat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Version"), "vscode/1.96.2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Plugin-Version"), "copilot-chat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Github-Api-Version"), "2025-04-01")
    }

    func testCopilotOrganizationBillingRequestSupportsStandaloneOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let date = Date(timeIntervalSince1970: 1_782_882_000)
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: date
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/organizations/Relias-Engineering/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "year"), "2026")
        XCTAssertEqual(components.queryItemValue(named: "month"), "7")
        XCTAssertEqual(components.queryItemValue(named: "product"), "Copilot")
        XCTAssertNil(components.queryItemValue(named: "organization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationBillingRequestSupportsEnterpriseOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            githubEnterprise: "bertelsmann"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: Date(timeIntervalSince1970: 1_782_882_000)
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/enterprises/bertelsmann/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "organization"), "Relias-Engineering")
    }

    func testCopilotOrganizationSeatCountRequestUsesOrgBillingEndpoint() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationSeatCountRequest(
            accessToken: "github-token",
            configuration: configuration
        ))

        XCTAssertEqual(request.url?.path, "/orgs/Relias-Engineering/copilot/billing")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationCreditsPerSeatMatchesWindowsPromotionalWindow() {
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 6), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 7), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 8), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 9), 3_900)
    }

    func testCopilotUsageParserReadsQuotaSnapshots() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_reset_date_utc": "2030-01-03T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 100,
              "remaining": 12,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.providerID, .copilot)
        XCTAssertEqual(result.title, "GitHub Copilot (octocat) - Pro")
        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)", "Chat (88 / 100)"])
        XCTAssertEqual(result.bars.map(\.usageText), ["75%", "88%"])
        XCTAssertEqual(result.subtitle, "Resets in 3d")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 2000)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_890_950_400))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_628_800))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotUsageParserOmitsUnlimitedChatQuota() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "fphemmer",
          "copilot_plan": "business",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 0,
              "remaining": 0,
              "unlimited": true
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)"])
    }

    func testCopilotUsageParserInfersMonthlyProjectionWhenResetIsMissing() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage")
        XCTAssertEqual(result.bars.first?.resetDescription, "Resets in 21d 16h")
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_782_864_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotBillingUsageParserReadsOrganizationUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "organization": "Relias-Engineering",
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1200 },
            { "product": "Actions", "sku": "Actions Linux", "grossQuantity": 99 },
            { "sku": "Copilot AI Credits", "grossQuantity": 300 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            copilotTotalAllotment: 350000
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.accountID, "copilot.org")
        XCTAssertEqual(result.title, "Relias Engineering")
        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage for Relias-Engineering")
        XCTAssertEqual(result.bars.map(\.label), [
            "Current AI credits (1,500 / 350,000)",
        ])
        XCTAssertEqual(result.bars.map(\.usageText), ["0%"])
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_782_864_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotBillingUsageParserProjectsOrganizationUsageWithoutAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.label), ["AI credits used (1,500)"])
        XCTAssertEqual(
            result.bars.first?.projectionDescription(at: fetchedAt),
            "Projected month end at current pace - 5,000 AI credits"
        )
    }

    func testCopilotBillingUsageParserUsesResolvedOrganizationPoolAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt,
            totalAllotment: 50 * 7_000
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Current AI credits (1,500 / 350,000)"])
        XCTAssertEqual(result.bars.first?.usageText, "0%")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotOrganizationAllotmentResolvesFromSeatCount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            session: session,
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let accountConfiguration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/orgs/Relias-Engineering/copilot/billing")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"seat_breakdown":{"total":50}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let total = try await provider.resolveOrganizationAllotment(
            configuration: accountConfiguration,
            accessToken: "github-token",
            date: Date(timeIntervalSince1970: 1_783_667_520)
        )

        XCTAssertEqual(total, 350000)
    }

    func testOpenRouterCreditsParserCalculatesBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration(
            providerID: .openRouter,
            accountLabel: "OpenRouter API",
            authMethod: .apiKey
        )
        let payload = """
        {
          "data": {
            "total_credits": 25.5,
            "total_usage": 7.25
          }
        }
        """

        let result = try XCTUnwrap(OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.title, "OpenRouter API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(result.creditsRemaining, 18.25)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterCreditsParserRejectsMissingCreditFields() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        let payload = """
        {
          "data": {
            "usage": 7.25
          }
        }
        """

        let result = OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration
        )

        XCTAssertNil(result)
    }

    func testOpenRouterProviderFetchesKeyBalance() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        try secretStore.saveSecret("Bearer sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenRouterUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "CodexBar")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"data":{"total_credits":100,"total_usage":12.34}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 87.66, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "Authorization: Bearer sk-or-test"),
            "sk-or-test"
        )
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "\"sk-or-quoted\""),
            "sk-or-quoted"
        )
    }

    func testOpenRouterProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenRouterUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter API key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsJSONBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.accountLabel = "OpenCode ZEN API"
        let payload = """
        {
          "data": {
            "balance": 42.5,
            "currency": "USD"
          }
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.title, "OpenCode ZEN API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(result.creditsRemaining, 42.5)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsDashboardNanodollarBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = #"initial:{balance:1250000000,credits:[]}"#

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.5, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsQuotedDashboardBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = #"<script>data={"balance":875000000,"reloadAmount":20}</script>"#

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 8.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderFetchesDashboardBillingBalance() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "opencode.ai")
            XCTAssertEqual(request.url?.path, "/workspace/wrk_test/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                Data(#"<html>data balance:2575000000 more</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(requestCount, 1)
    }

    func testOpenCodeZenProviderExplainsModelAPIKeyCannotFetchBalanceAfterDashboardRejectsIt() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "sk-opencode-model-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=sk-opencode-model-key")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode ZEN API keys are valid for models, but OpenCode does not expose balance to API keys.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderReadsWindowsSettingsJSONCredentialAndWorkspace() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = ""
        let windowsSettings = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "enabled": true,
              "apiKey": "go-dashboard-token"
            },
            "OpenCodeZen": {
              "enabled": true
            }
          }
        }
        """
        try secretStore.saveSecret(
            windowsSettings,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/workspace/wrk_from_windows/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=go-dashboard-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html>balance:625000000</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 6.25, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterStoresWindowsSettingsJSON() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = MemorySecretStore()
        let configurationStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """

        XCTAssertTrue(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: configurationStore))

        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_from_windows")
        XCTAssertEqual(configuration.accountLabel, "OpenCode ZEN")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "go-dashboard-token"
        )
    }

    func testOpenCodeZenProviderNormalizesAuthHeaderBeforeDashboardRequest() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "Authorization: Bearer opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/workspace/wrk_test/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/148.0"
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"<html>data balance:2575000000 more</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(requestCount, 1)
    }

    func testOpenCodeZenProviderReportsRejectedCredential() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret("bad-balance-credential", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode ZEN rejected this API key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderExplainsOpenCodeSignInPage() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret("auth=opencode-dashboard-token", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode returned the sign-in page. Refresh the saved dashboard auth value.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenNormalizesPastedBalanceCredential() {
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Authorization: Bearer oczen-test-key"),
            "oczen-test-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "\"quoted-key\""),
            "quoted-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "auth=oczen-legacy-shaped-key; other=value"),
            "oczen-legacy-shaped-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Cookie: other=value; auth=oczen-cookie"),
            "oczen-cookie"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Set-Cookie: auth=oczen-cookie; Path=/; HttpOnly"),
            "oczen-cookie"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "https://opencode.ai/workspace/wrk_test/billing"),
            "wrk_test"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: #"OPENCODE_GO_AUTH_COOKIE="go-dashboard-token""#),
            "go-dashboard-token"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "OPENCODE_GO_WORKSPACE_ID=wrk_env"),
            "wrk_env"
        )
    }

    func testOpenCodeZenProviderWithoutWorkspaceIsNotConfigured() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        try secretStore.saveSecret("oczen-test-key", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let provider = OpenCodeZenUsageProvider(secretStore: secretStore)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode workspace ID.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenCodeZenUsageProvider(secretStore: EmptySecretStore())
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode dashboard auth value.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCursorNormalizesPastedAuthJSONAndBearerHeader() {
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: #"{"accessToken":"cursor-token","refreshToken":"refresh"}"#),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "Authorization: Bearer cursor-token"),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "\"cursor-quoted\""),
            "cursor-quoted"
        )
    }

    func testCursorUsageParserReadsDashboardUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor Pro"
        let payload = """
        {
          "billingCycleEnd": "1784332800000",
          "planUsage": {
            "autoPercentUsed": 42.4,
            "apiPercentUsed": 18.2,
            "totalPercentUsed": 62.6
          },
          "spendLimitUsage": {
            "individualLimit": 2000,
            "individualRemaining": 800
          }
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor Pro")
        XCTAssertEqual(result.subtitle, "Included usage - Auto 42% - API 18%")
        XCTAssertEqual(result.bars.map(\.label), [
            "Total",
            "Auto",
            "API",
            "On-demand $12.00 / $20.00",
        ])
        XCTAssertEqual(result.bars.map(\.usageText), ["63%", "42%", "18%", "60%"])
    }

    func testCursorProviderFetchesDashboardUsage() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor"
        try secretStore.saveSecret(
            #"{"accessToken":"cursor-token"}"#,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"planUsage":{"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":5}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor")
        XCTAssertEqual(result.bars.map(\.label), ["Total", "Auto", "API"])
        XCTAssertEqual(result.bars.first?.usageText, "25%")
    }

    func testCursorProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = CursorUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Cursor.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCodexUsageParserReadsUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 81,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            }
          }
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(
            Data(payload.utf8),
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.title, "ChatGPT / Codex (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        let resetDescription = try XCTUnwrap(result.bars.first?.resetDescription)
        XCTAssertTrue(resetDescription.hasPrefix("Resets 1d 0h (Tue 1:00"))
        XCTAssertTrue(resetDescription.hasSuffix("GMT+1)"))
        let newYorkFormatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: Locale(identifier: "en_US")
        )
        let reformattedReset = try XCTUnwrap(result.bars.first?.localizedResetDescription(
            at: fetchedAt,
            dateTimeFormatter: newYorkFormatter
        ))
        XCTAssertTrue(reformattedReset.hasSuffix("EST)"))
        XCTAssertFalse(reformattedReset.contains("GMT+1"))
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))

    }

    func testClaudeUsageParserReadsOAuthUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "de_DE")
        )
        let payload = """
        {
          "five_hour": {
            "utilization": 0.42,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 0.81,
            "resets_at": "2030-01-08T00:00:00Z"
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro",
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.title, "Claude (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        let resetDescription = try XCTUnwrap(result.bars.first?.resetDescription)
        XCTAssertTrue(resetDescription.contains("Di. 01:00"))
        XCTAssertTrue(resetDescription.hasSuffix("GMT+1)"))
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))

        let percentagePayload = #"{"five_hour":{"utilization":15},"seven_day":{"utilization":36}}"#
        let percentageResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(percentagePayload.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(percentageResult.bars.map(\.used), [15, 36])
    }

    func testClaudeUsageParserReadsStructuredAndScopedLimitsWithoutDuplicates() throws {
        let payload = """
        {
          "five_hour": {"utilization": 0.99, "resets_at": "2030-01-01T00:00:00Z"},
          "seven_day": {"utilization": 0.88, "resets_at": "2030-01-08T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 0.44, "resets_at": "2030-01-08T00:00:00Z"},
          "limits": [
            {"kind":"session","percent":15,"is_active":true},
            {"kind":"weekly_all","percent":36,"resets_at":"2030-01-08T00:00:00Z","is_active":true},
            {"kind":"weekly_scoped","percent":71,"resets_at":"2030-01-08T00:00:00.838164+00:00","scope":{"model":{"display_name":"Fable"}},"is_active":true},
            {"kind":"weekly_scoped","percent":112,"scope":{"model":{"display_name":"Future Model"}},"is_active":true},
            {"kind":"weekly_scoped","percent":49,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true},
            {"kind":"internal_codename","percent":100,"scope":{"model":{"display_name":"Do Not Show"}},"is_active":true},
            {"kind":"weekly_scoped","percent":90,"scope":{"model":{"id":"internal-only"}},"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max_20x"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "Weekly usage limit",
            "Fable weekly limit",
            "Future Model weekly limit",
            "Claude Sonnet 4.5 weekly limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [15, 36, 71, 112, 49])
        XCTAssertEqual(result.bars[3].usageText, "112%")
        XCTAssertEqual(result.bars[0].resetsAt, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertNil(result.bars[3].resetsAt)
        XCTAssertNotNil(result.bars[2].resetsAt)
        XCTAssertTrue(result.usageMessages.contains {
            $0 == "Fable usage is capped within the all-model weekly allowance."
        })
        XCTAssertFalse(result.bars.contains { $0.label.contains("Do Not Show") })

        let incompleteStructured = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":0.42},"limits":[{"kind":"session","percent":null}]}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(incompleteStructured.bars.first?.used, 42)
    }

    func testClaudeUsageParserReadsCurrencyAwareUsageCredits() throws {
        let payload = """
        {
          "limits": [{"kind":"weekly_all","percent":24,"is_active":true}],
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 5000,
            "used_credits": 1250,
            "currency": "EUR",
            "decimal_places": 2
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.first?.used, 24)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [Decimal(1250), Decimal(5000), Decimal(3750)])
        XCTAssertEqual(result.monetaryMetrics.map(\.amount), [Decimal(string: "12.5")!, Decimal(50), Decimal(string: "37.5")!])
        XCTAssertEqual(result.monetaryMetrics.map(\.currencyCode), ["EUR", "EUR", "EUR"])
        XCTAssertEqual(result.monetaryMetrics.last?.detail, "Not a prepaid balance")
        XCTAssertNil(result.creditsRemaining)
    }

    func testClaudeUsageParserRepresentsDisabledUnlimitedAndMalformedExtraUsage() throws {
        let disabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(disabled.usageMessages, ["Usage credits are disabled: Not funded."])
        XCTAssertTrue(disabled.monetaryMetrics.isEmpty)

        let unlimited = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":250,"currency":"GBP","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unlimited.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(unlimited.usageMessages, ["Usage credits are enabled with no monthly spend limit reported."])

        let malformed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"unknown","percent":50}],"extra_usage":{"is_enabled":true,"used_credits":10}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(malformed.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            malformed.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let unknownState = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            unknownState.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let missingSpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(missingSpend.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            missingSpend.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let inferredPrecision = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(inferredPrecision.monetaryMetrics.map(\.decimalPlaces), [2, 2, 2])
        XCTAssertEqual(inferredPrecision.monetaryMetrics.map(\.amount), [12.5, 50, 37.5])

        let unreportedEnabledState = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unreportedEnabledState.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(
            unreportedEnabledState.usageMessages,
            ["Usage-credit enabled status was not reported."]
        )
    }

    func testClaudeUsageParserReadsRateLimitHeaders() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let result = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "0.25",
                "anthropic-ratelimit-unified-5h-reset": "1893456000"
            ],
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.title, "Claude (Max)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit"])
        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.25)

        let overQuota = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "1.2",
                "anthropic-ratelimit-unified-5h-reset": "1893456000"
            ],
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))
        XCTAssertEqual(overQuota.bars.first?.used, 100)
    }

    func testUsageBarFormatsPercentAndProjection() throws {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let bar = UsageBar(
            label: "5 hour usage limit",
            used: 25,
            limit: 100,
            projectionCurrent: 0.25,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )

        XCTAssertEqual(bar.usageText, "25%")
        XCTAssertEqual(bar.projectedFraction(at: now), 1)
        XCTAssertEqual(bar.projectedSeverity(at: now), .critical)
        XCTAssertEqual(bar.effectiveSeverity(at: now), .critical)
        let projection = try XCTUnwrap(bar.projectionDescription(at: now))
        XCTAssertTrue(projection.hasPrefix("Projected 100% at current pace - Limit hit "))
        XCTAssertTrue(projection.hasSuffix(" - 1h early"))
    }

    func testUserFacingDateTimeFormatterUsesTimezoneAtDisplayedInstant() throws {
        let winter = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        let summer = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
        let marchMismatch = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z"))
        let octoberMismatch = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z"))
        let locale = Locale(identifier: "en_US")
        let cases: [(String, String, String)] = [
            ("Europe/Berlin", "GMT+1", "GMT+2"),
            ("America/New_York", "EST", "EDT"),
            ("Asia/Kathmandu", "GMT+5:45", "GMT+5:45"),
        ]

        for (identifier, winterZone, summerZone) in cases {
            let formatter = UserFacingDateTimeFormatter(
                timeZone: try XCTUnwrap(TimeZone(identifier: identifier)),
                locale: locale
            )

            XCTAssertTrue(formatter.timeWithZone(winter, includesWeekday: false).hasSuffix(winterZone))
            XCTAssertTrue(formatter.timeWithZone(summer, includesWeekday: false).hasSuffix(summerZone))
        }

        let berlin = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: locale
        )
        let newYork = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: locale
        )
        XCTAssertTrue(berlin.timeWithZone(marchMismatch, includesWeekday: false).hasSuffix("GMT+1"))
        XCTAssertTrue(newYork.timeWithZone(marchMismatch, includesWeekday: false).hasSuffix("EDT"))
        XCTAssertTrue(berlin.timeWithZone(octoberMismatch, includesWeekday: false).hasSuffix("GMT+1"))
        XCTAssertTrue(newYork.timeWithZone(octoberMismatch, includesWeekday: false).hasSuffix("EDT"))
    }

    func testUserFacingDateTimeFormatterHonorsLocaleAndLocalWeekday() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let usFormatter = UserFacingDateTimeFormatter(
            timeZone: newYork,
            locale: Locale(identifier: "en_US")
        )
        let germanFormatter = UserFacingDateTimeFormatter(
            timeZone: berlin,
            locale: Locale(identifier: "de_DE")
        )

        let newYorkValue = usFormatter.timeWithZone(instant, includesWeekday: true)
        let berlinValue = germanFormatter.timeWithZone(instant, includesWeekday: true)
        XCTAssertTrue(newYorkValue.contains("Mon"))
        XCTAssertTrue(newYorkValue.contains("PM"))
        XCTAssertTrue(berlinValue.contains("Di."))
        XCTAssertTrue(berlinValue.contains("01:00"))
        XCTAssertFalse(berlinValue.contains("AM"))
        XCTAssertFalse(berlinValue.contains("PM"))
    }

    func testUserFacingDateTimeFormatterReevaluatesTimezoneProvider() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        var timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = UserFacingDateTimeFormatter(
            timeZoneProvider: { timeZone },
            localeProvider: { Locale(identifier: "en_US") }
        )

        XCTAssertTrue(formatter.timeWithZone(instant, includesWeekday: false).hasSuffix("EST"))
        timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let updatedValue = formatter.timeWithZone(instant, includesWeekday: false)
        XCTAssertTrue(updatedValue.hasSuffix("GMT+1"))
        XCTAssertFalse(updatedValue.contains("EST"))
    }

    func testCodexResetDescriptionsCoverRelativeAndExpiredRanges() throws {
        let resetAt = Date(timeIntervalSince1970: 1_893_456_000)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )
        let payload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            }
          }
        }
        """
        let cases: [(Date, String)] = [
            (resetAt.addingTimeInterval(60), "Resets now"),
            (resetAt.addingTimeInterval(-30 * 60), "Resets 30m"),
            (resetAt.addingTimeInterval(-2 * 60 * 60), "Resets 2h 0m"),
            (resetAt.addingTimeInterval(-(2 * 24 + 4) * 60 * 60), "Resets 2d 4h"),
        ]

        for (fetchedAt, expectedPrefix) in cases {
            let result = try XCTUnwrap(CodexUsageParser.parse(
                Data(payload.utf8),
                fetchedAt: fetchedAt,
                dateTimeFormatter: formatter
            ))
            XCTAssertTrue(try XCTUnwrap(result.bars.first?.resetDescription).hasPrefix(expectedPrefix))
        }
    }

    func testUsageBarFormatsProjectedLimitInInjectedTimezone() throws {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu")),
            locale: Locale(identifier: "en_US")
        )

        let description = UsageBar.formatLimitHit(
            current: 0.25,
            limit: 1,
            periodStart: start,
            periodEnd: end,
            now: now,
            dateTimeFormatter: formatter
        )

        XCTAssertTrue(description.contains("Thu 9:45"))
        XCTAssertTrue(description.contains("GMT+5:45"))
        XCTAssertTrue(description.hasSuffix(" - 1h early"))
    }

    @MainActor
    func testWidgetSnapshotReformatsResetAndProjectionForChangedTimezone() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let configuration = store.addAccount(for: .codex)
        store.saveSecret("test-token", for: configuration)
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let resetAt = start.addingTimeInterval(3 * 60 * 60)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "ChatGPT / Codex",
            subtitle: "Live ChatGPT usage",
            bars: [
                UsageBar(
                    label: "5 hour usage limit",
                    used: 25,
                    limit: 100,
                    resetDescription: "Resets 2h (10:00 PM EST)",
                    resetsAt: resetAt,
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionCurrent: 0.25,
                    projectionLimit: 1,
                    projectionPeriodStart: start,
                    projectionPeriodEnd: start.addingTimeInterval(5 * 60 * 60),
                    showProjectionOnCurrentBar: true
                ),
            ],
            fetchedAt: now
        )
        let newYork = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: Locale(identifier: "en_US")
        )
        let berlin = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults,
            now: now,
            dateTimeFormatter: newYork
        )
        let storedBar = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.first
        )
        let easternProjection = try XCTUnwrap(storedBar.localizedProjectionDescription(
            dateTimeFormatter: newYork
        ))
        let easternReset = try XCTUnwrap(storedBar.localizedResetDescription(
            at: now,
            dateTimeFormatter: newYork
        ))
        XCTAssertTrue(easternProjection.contains("EST"))
        XCTAssertTrue(easternReset.contains("EST"))

        let localProjection = try XCTUnwrap(storedBar.localizedProjectionDescription(
            dateTimeFormatter: berlin
        ))
        let localReset = try XCTUnwrap(storedBar.localizedResetDescription(
            at: now,
            dateTimeFormatter: berlin
        ))
        XCTAssertTrue(localProjection.contains("GMT+1"))
        XCTAssertFalse(localProjection.contains("EST"))
        XCTAssertTrue(localReset.contains("GMT+1"))
        XCTAssertFalse(localReset.contains("EST"))
    }

    func testUsageBarShowsSafeProjectionWhenPaceStaysBelowLimit() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let bar = UsageBar(
            label: "5 hour usage limit",
            used: 8,
            limit: 100,
            projectionCurrent: 0.08,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )

        XCTAssertEqual(bar.projectedFraction(at: now), 0.4)
        XCTAssertEqual(bar.projectedSeverity(at: now), .normal)
        XCTAssertEqual(bar.effectiveSeverity(at: now), .normal)
        XCTAssertEqual(bar.projectionDescription(at: now), "Projected to stay under limit")
    }

    func testUsageBarKeepsOverLimitPercentVisible() {
        let bar = UsageBar(label: "Weekly usage limit", used: 112, limit: 100)

        XCTAssertEqual(bar.usageText, "112%")
        XCTAssertEqual(bar.fractionUsed, 1)
    }

    @MainActor
    func testUsageHistoryStoreRecordsAndPersistsSnapshots() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = makeHistoryResult(accountID: "codex.personal", fetchedAt: fetchedAt, used: 42)

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: fetchedAt)

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.snapshots.count, 1)
        XCTAssertEqual(reloadedStore.snapshots.first?.accountID, "codex.personal")
        XCTAssertEqual(reloadedStore.snapshots.first?.bars.first?.fractionUsed, 0.42)
        XCTAssertNil(reloadedStore.snapshots.first?.creditsRemaining)
    }

    @MainActor
    func testUsageHistoryStorePersistsAllMonetaryMetricsAlongsideBars() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live Claude usage",
            bars: [UsageBar(label: "Weekly usage limit", used: 40, limit: 100)],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 1250,
                    currencyCode: "EUR",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3750,
                    currencyCode: "EUR",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: fetchedAt
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: fetchedAt)

        let snapshot = try XCTUnwrap(UsageHistoryStore(defaults: defaults).snapshots.first)
        XCTAssertEqual(snapshot.monetaryMetrics?.map(\.kind), [.spent, .remainingHeadroom])
        XCTAssertEqual(snapshot.monetaryMetrics?.map(\.currencyCode), ["EUR", "EUR"])
        XCTAssertEqual(snapshot.primaryValue, 0.4)

        let options = store.historySeriesOptions(for: result)
        XCTAssertEqual(options.map(\.label), [
            "Usage",
            "Usage credits spent",
            "Remaining spend headroom",
        ])
        XCTAssertEqual(options[1].series.points.map(\.value), [12.5])
        XCTAssertEqual(options[1].series.currencyCode, "EUR")
        XCTAssertEqual(options[2].series.points.map(\.value), [37.5])

        let relabeledResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            monetaryMetrics: result.monetaryMetrics.map { metric in
                ProviderMonetaryMetric(
                    kind: metric.kind,
                    label: "Updated \(metric.label)",
                    minorUnits: metric.minorUnits,
                    currencyCode: metric.currencyCode,
                    decimalPlaces: metric.decimalPlaces,
                    detail: metric.detail
                )
            },
            fetchedAt: result.fetchedAt
        )
        let relabeledOptions = store.historySeriesOptions(for: relabeledResult)
        XCTAssertEqual(relabeledOptions[1].series.points.map(\.value), [12.5])
        XCTAssertEqual(relabeledOptions[2].series.points.map(\.value), [37.5])

        let monetaryOnlyResult = ProviderUsageResult(
            accountID: "claude.monetary-only",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live Claude usage",
            bars: [],
            monetaryMetrics: result.monetaryMetrics,
            fetchedAt: fetchedAt
        )
        store.record(results: [monetaryOnlyResult], now: fetchedAt)
        let compactSeries = store.historySeries(for: monetaryOnlyResult)
        XCTAssertEqual(compactSeries.currencyCode, "EUR")
        XCTAssertEqual(compactSeries.decimalPlaces, 2)
        XCTAssertTrue(compactSeries.latestValueDescription.contains("37.50"))
        XCTAssertFalse(compactSeries.latestValueDescription.contains("$"))

        let transientMonetaryOnly = ProviderUsageResult(
            accountID: result.accountID,
            providerID: .claude,
            title: "Claude",
            subtitle: "Partial Claude usage",
            bars: [],
            monetaryMetrics: result.monetaryMetrics,
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )
        store.record(results: [transientMonetaryOnly], now: fetchedAt.addingTimeInterval(60))
        let usageSeries = store.historySeries(for: result)
        XCTAssertEqual(usageSeries.points.count, 1)
        XCTAssertEqual(usageSeries.points.first?.value, 0.4)
        let mixedCurrencySeries = store.historySeries(for: transientMonetaryOnly)
        XCTAssertEqual(mixedCurrencySeries.points.map(\.value), [37.5, 37.5])
    }

    @MainActor
    func testUsageHistoryStorePrunesRetentionAndPerAccountLimit() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults, retentionDays: 7, maxSnapshotsPerAccount: 2)

        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-8 * 24 * 60 * 60), used: 10),
        ], now: now)
        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-3 * 24 * 60 * 60), used: 20),
        ], now: now)
        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-2 * 24 * 60 * 60), used: 30),
        ], now: now)
        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-24 * 60 * 60), used: 40),
        ], now: now)

        let snapshots = store.snapshots(for: "codex.personal")
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.compactMap { $0.bars.first?.used }, [30, 40])
    }

    @MainActor
    func testUsageHistoryStoreRemovesDeletedAccounts() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 42),
            makeHistoryResult(accountID: "openrouter.work", providerID: .openRouter, fetchedAt: now, creditsRemaining: 19.25),
        ], now: now)
        store.removeSnapshotsForMissingAccounts(validAccountIDs: ["codex.personal"], now: now)

        XCTAssertEqual(store.snapshots.map(\.accountID), ["codex.personal"])
    }

    @MainActor
    func testUsageHistoryStoreSkipsEmptyProviderStates() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Not configured",
            bars: [],
            fetchedAt: now
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: now)

        XCTAssertTrue(store.snapshots.isEmpty)
    }

    @MainActor
    func testUsageHistoryTrendSummaryReportsUsageMovement() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let first = makeHistoryResult(accountID: "codex.personal", fetchedAt: now.addingTimeInterval(-60), used: 25)
        let second = makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 40)

        store.record(results: [first], now: now)
        store.record(results: [second], now: now)

        let summary = try XCTUnwrap(store.trendSummary(for: second, now: now))
        XCTAssertEqual(summary.points, [0.25, 0.4])
        XCTAssertEqual(summary.direction, .up)
        XCTAssertFalse(summary.isBalance)
        XCTAssertEqual(summary.valueDescription, "Changed +15 pts")
        XCTAssertTrue(summary.windowDescription.hasPrefix("Since "))
        XCTAssertTrue(summary.windowDescription.contains(" at "))
    }

    @MainActor
    func testUsageHistoryTrendSummaryReportsBalanceMovement() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let first = makeHistoryResult(
            accountID: "openrouter.work",
            providerID: .openRouter,
            fetchedAt: now.addingTimeInterval(-60),
            creditsRemaining: 22
        )
        let second = makeHistoryResult(
            accountID: "openrouter.work",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 19.25
        )

        store.record(results: [first], now: now)
        store.record(results: [second], now: now)

        let summary = try XCTUnwrap(store.trendSummary(for: second, now: now))
        XCTAssertEqual(summary.points, [22, 19.25])
        XCTAssertEqual(summary.direction, .down)
        XCTAssertTrue(summary.isBalance)
        XCTAssertEqual(summary.valueDescription, "Changed -$2.75")
        XCTAssertTrue(summary.windowDescription.hasPrefix("Since "))
        XCTAssertTrue(summary.windowDescription.contains(" at "))
    }

    @MainActor
    func testUsageHistorySeriesHandlesEmptyAndSingleSampleStates() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let result = makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 42)
        let store = UsageHistoryStore(defaults: defaults)

        let emptySeries = store.historySeries(for: result)
        XCTAssertTrue(emptySeries.points.isEmpty)
        XCTAssertEqual(emptySeries.latestValueDescription, "No data")
        XCTAssertEqual(emptySeries.rangeDescription, "No range yet")
        XCTAssertEqual(emptySeries.changeDescription, "No history yet")
        XCTAssertEqual(emptySeries.sampleWindowDescription, "No samples")
        XCTAssertEqual(emptySeries.chartDomain, 0...1)

        store.record(results: [result], now: now)

        let singleSampleSeries = store.historySeries(for: result)
        XCTAssertEqual(singleSampleSeries.points.count, 1)
        XCTAssertEqual(singleSampleSeries.latestValueDescription, "42%")
        XCTAssertEqual(singleSampleSeries.minimumValueDescription, "42%")
        XCTAssertEqual(singleSampleSeries.maximumValueDescription, "42%")
        XCTAssertEqual(singleSampleSeries.rangeDescription, "Flat at 42%")
        XCTAssertEqual(singleSampleSeries.changeDescription, "Collecting history")
        XCTAssertTrue(singleSampleSeries.sampleWindowDescription.hasPrefix("1 sample - "))
    }

    @MainActor
    func testUsageHistorySeriesReportsFlatValuesSpikesAndTimestampOrder() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let samples = [
            makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
                used: 20
            ),
            makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: now.addingTimeInterval(-24 * 60 * 60),
                used: 95
            ),
            makeHistoryResult(accountID: "codex.personal", fetchedAt: now, used: 40),
        ]

        for sample in samples.reversed() {
            store.record(results: [sample], now: now)
        }

        let series = store.historySeries(for: samples[2])
        XCTAssertEqual(series.points.map(\.capturedAt), samples.map(\.fetchedAt))
        XCTAssertEqual(series.points.map(\.value), [0.2, 0.95, 0.4])
        XCTAssertEqual(series.latestValueDescription, "40%")
        XCTAssertEqual(series.minimumValueDescription, "20%")
        XCTAssertEqual(series.maximumValueDescription, "95%")
        XCTAssertEqual(series.rangeDescription, "Range 20% to 95%")
        XCTAssertEqual(series.changeDescription, "Down 55 pts")
        XCTAssertEqual(series.direction, .down)
        XCTAssertEqual(series.sampleWindowDescription.components(separatedBy: " - ").count, 3)
        XCTAssertEqual(series.chartDomain, 0...1)

        let flatResult = makeHistoryResult(
            accountID: "flat.usage",
            fetchedAt: now.addingTimeInterval(-60),
            used: 40
        )
        store.record(results: [flatResult], now: now)
        store.record(
            results: [makeHistoryResult(accountID: "flat.usage", fetchedAt: now, used: 40)],
            now: now
        )

        let flatSeries = store.historySeries(for: flatResult)
        XCTAssertEqual(flatSeries.rangeDescription, "Flat at 40%")
        XCTAssertEqual(flatSeries.changeDescription, "No change")
        XCTAssertEqual(flatSeries.direction, .flat)
    }

    @MainActor
    func testUsageHistorySeriesPadsFlatBalanceChartDomain() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let result = makeHistoryResult(
            accountID: "openrouter.work",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: 19.25
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: now)

        let series = store.historySeries(for: result)
        XCTAssertTrue(series.isBalance)
        XCTAssertEqual(series.latestValueDescription, "$19.25")
        XCTAssertEqual(series.rangeDescription, "Flat at $19.25")
        XCTAssertLessThan(series.chartDomain.lowerBound, 19.25)
        XCTAssertGreaterThan(series.chartDomain.upperBound, 19.25)

        let overdrawnResult = makeHistoryResult(
            accountID: "openrouter.overdrawn",
            providerID: .openRouter,
            fetchedAt: now,
            creditsRemaining: -3
        )
        store.record(results: [overdrawnResult], now: now)

        let overdrawnSeries = store.historySeries(for: overdrawnResult)
        XCTAssertLessThan(overdrawnSeries.chartDomain.lowerBound, -3)
        XCTAssertGreaterThan(overdrawnSeries.chartDomain.upperBound, -3)
    }

    @MainActor
    func testProviderUsageCardPreservesStoredHistoryAfterEmptyRefresh() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let priorResult = makeHistoryResult(
            accountID: "openrouter.personal",
            providerID: .openRouter,
            fetchedAt: now.addingTimeInterval(-60),
            creditsRemaining: 19.25
        )
        let failedResult = ProviderUsageResult(
            accountID: priorResult.accountID,
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Session expired",
            bars: [],
            fetchedAt: now
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [priorResult], now: now)
        let history = store.historySeries(for: failedResult)

        let card = ProviderUsageCard(
            result: failedResult,
            statusText: failedResult.subtitle,
            history: history
        )

        XCTAssertTrue(card.showsHistory)
        XCTAssertTrue(history.isBalance)
        XCTAssertEqual(history.latestValueDescription, "$19.25")
    }

    func testCodexUsageProviderProactivelyRefreshesAndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                idToken: "old-id",
                accountID: "account-id",
                expiresAt: 2_000_000_060
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/codex-token" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.timeoutInterval, 15)
                XCTAssertEqual(
                    String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8),
                    "grant_type=refresh_token&refresh_token=old-refresh&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
                )
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-id")
            let persisted = try XCTUnwrap(
                CodexCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertEqual(persisted.accessToken, "new-access")
            XCTAssertEqual(persisted.refreshToken, "new-refresh")
            XCTAssertEqual(persisted.expiresAt, 2_000_003_600)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderPreservesCredentialChangedDuringRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let initial = CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: 1_999_999_000
        ))
        let replacement = CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: "signed-in-access",
            refreshToken: "signed-in-refresh",
            expiresAt: 2_000_003_600
        ))
        let secretStore = ReplacingThirdReadSecretStore(initialSecret: initial, replacementSecret: replacement)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"refreshed-old-access","refresh_token":"rotated-old-refresh","expires_in":3600}"#.utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed-in-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(secretStore.saveCount, 0)
    }

    func testCodexUsageProviderDerivesRefreshedExpiryFromJWT() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expectedExpiry: Int64 = 2_000_003_600
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"exp":2000003600,"chatgpt_account_id":"refreshed-account"}"#.base64URLEncodedForTest()
        let refreshedAccessToken = "\(header).\(payload).signature"
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        let secretStore = MemorySecretStore()
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "expired-access",
                refreshToken: "refresh-token",
                expiresAt: 1_999_999_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"\#(refreshedAccessToken)","refresh_token":"rotated"}"#.utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(refreshedAccessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "refreshed-account")
            let persisted = try XCTUnwrap(
                CodexCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertEqual(persisted.expiresAt, expectedExpiry)
            XCTAssertEqual(persisted.accountID, "refreshed-account")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderExplainsExpiredCredentialWithoutRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "expired-access",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let provider = CodexUsageProvider(secretStore: secretStore, now: { now })

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "ChatGPT / Codex credential expired and cannot be renewed. Sign in again."
        )
    }

    func testCodexUsageProviderUsesValidTokenWhenProactiveRefreshIsTemporarilyUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "still-valid-access",
                refreshToken: "refresh-token",
                expiresAt: 2_000_000_060
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/codex-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer still-valid-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderDoesNotUseCredentialWhenKeychainRotationFails() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let stored = CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-token",
            expiresAt: 1_999_999_000
        ))
        let secretStore = FailingSaveSecretStore(secret: stored)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/codex-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":3600}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            result.subtitle,
            "Could not securely save the renewed ChatGPT / Codex credential. Sign in again."
        )
    }

    func testCopilotUsageProviderRequestsSignInWhenKeychainRotationFails() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let stored = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-token",
            expiresAt: 1_999_999_000
        ))
        let secretStore = FailingSaveSecretStore(secret: stored)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/github-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":28800}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            result.subtitle,
            "Could not securely save the renewed GitHub credential. Sign in again."
        )
    }

    func testCodexUsageProviderRetriesOnlyOnceAfterAuthenticationRejection() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!
        )
        var usageRequests = 0
        var refreshRequests = 0

        MockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
                )
            }
            usageRequests += 1
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(result.subtitle, "ChatGPT / Codex authorization was revoked. Sign in again.")
    }

    func testCodexUsageProviderRecoversFromUsageRejectionWithRefreshedCredential() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!
        )
        var usageRequests = 0
        var refreshRequests = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
                )
            }
            usageRequests += 1
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                usageRequests == 1 ? "Bearer old-access" : "Bearer new-access"
            )
            let statusCode = usageRequests == 1 ? 401 : 200
            let data = usageRequests == 1
                ? Data()
                : Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderExplainsRejectedRefreshAndLegacyRejection() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "expired-access",
                refreshToken: "rejected-refresh",
                expiresAt: 1_999_999_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"invalid_grant","access_token":"must-not-leak"}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let rejected = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(rejected.subtitle, "ChatGPT / Codex credential renewal was rejected. Sign in again.")
        XCTAssertFalse(rejected.subtitle.contains("must-not-leak"))

        try secretStore.saveSecret("legacy-access", account: account)
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let legacy = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(legacy.subtitle, "ChatGPT / Codex credential was rejected. Sign in again.")
    }

    func testCopilotUsageProviderProactivelyRefreshesAndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                username: "octocat",
                refreshToken: "old-refresh",
                expiresAt: 2_000_000_060,
                refreshTokenExpiresAt: 2_100_000_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/github-token" {
                XCTAssertEqual(request.timeoutInterval, 15)
                XCTAssertEqual(
                    String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8),
                    "client_id=client&client_secret=secret&grant_type=refresh_token&refresh_token=old-refresh"
                )
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":15897600}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token new-access")
            let persisted = try XCTUnwrap(
                CopilotCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertEqual(persisted.accessToken, "new-access")
            XCTAssertEqual(persisted.refreshToken, "new-refresh")
            XCTAssertEqual(persisted.username, "octocat")
            XCTAssertEqual(persisted.expiresAt, 2_000_028_800)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderDoesNotCarryStaleExpiryWhenRefreshOmitsLifetime() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let priorExpiry: Int64 = 2_000_000_060
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        let secretStore = MemorySecretStore()
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expiresAt: priorExpiry,
                refreshTokenExpiresAt: 2_100_000_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        MockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)
                )
            }
            let persisted = try XCTUnwrap(
                CopilotCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertNil(persisted.expiresAt)
            XCTAssertNil(persisted.refreshTokenExpiresAt)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderPreservesCredentialChangedDuringRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let initial = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: 1_999_999_000
        ))
        let replacement = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "signed-in-access",
            refreshToken: "signed-in-refresh",
            expiresAt: 2_000_028_800
        ))
        let secretStore = ReplacingThirdReadSecretStore(initialSecret: initial, replacementSecret: replacement)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        MockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"refreshed-old-access","refresh_token":"rotated-old-refresh","expires_in":28800}"#.utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token signed-in-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(secretStore.saveCount, 0)
    }

    func testCopilotUsageProviderSharesConcurrentRefreshForSameAccount() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "single-use-refresh",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        let counterLock = NSLock()
        var refreshRequests = 0
        var usageRequests = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                counterLock.lock()
                refreshRequests += 1
                counterLock.unlock()
                Thread.sleep(forTimeInterval: 0.1)
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":28800}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token new-access")
            counterLock.lock()
            usageRequests += 1
            counterLock.unlock()
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        async let first = provider.fetchUsage(for: configuration)
        async let second = provider.fetchUsage(for: configuration)
        let results = try await [first, second]

        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(usageRequests, 2)
        XCTAssertTrue(results.allSatisfy { $0.bars.first?.used == 25 })
    }

    func testCopilotUsageProviderDoesNotReuseRotatedTokenFromLateStaleRead() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let stored = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "old-access",
            refreshToken: "single-use-refresh",
            expiresAt: 1_999_999_000
        ))
        let secretStore = StaleThirdReadSecretStore(initialSecret: stored)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var refreshRequests = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":28800}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token new-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let first = try await provider.fetchUsage(for: configuration)
        let second = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(first.bars.first?.used, 25)
        XCTAssertEqual(second.bars.first?.used, 25)
    }

    func testCopilotUsageProviderExplainsExpiredCredentialWithoutRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "expired-access",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let provider = CopilotUsageProvider(secretStore: secretStore, now: { now })

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "GitHub credential expired and cannot be renewed. Sign in again."
        )
    }

    func testCopilotUsageProviderExplainsExpiredRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "expired-access",
                refreshToken: "expired-refresh",
                expiresAt: 1_999_999_000,
                refreshTokenExpiresAt: 1_999_999_500
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let provider = CopilotUsageProvider(secretStore: secretStore, now: { now })

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "GitHub credential expired and cannot be renewed. Sign in again."
        )
    }

    func testCopilotUsageProviderUsesValidTokenWhenProactiveRefreshIsTemporarilyUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "still-valid-access",
                refreshToken: "refresh-token",
                expiresAt: 2_000_000_060
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/github-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token still-valid-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderExplainsRejectedRefreshWithoutLeakingResponse() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "expired-access",
                refreshToken: "rejected-refresh",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"bad_refresh_token","access_token":"must-not-leak"}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "GitHub credential renewal was rejected. Sign in again.")
        XCTAssertFalse(result.subtitle.contains("must-not-leak"))
    }

    func testCopilotUsageProviderRetriesOnceAndSeparatesPermissionFailures() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
        )
        var usageRequests = 0
        var refreshRequests = 0

        MockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":28800}"#.utf8)
                )
            }
            usageRequests += 1
            let status = usageRequests <= 2 ? 401 : 403
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let rejected = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(rejected.subtitle, "GitHub authorization was revoked. Sign in again.")

        try secretStore.saveSecret("legacy-access", account: ProviderConfigurationStore.keychainAccount(for: configuration))
        let forbidden = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(forbidden.subtitle, "This GitHub account does not have access to Copilot usage.")
    }

    func testCopilotUsageProviderRecoversFromUsageRejectionWithRefreshedCredential() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
        )
        var usageRequests = 0
        var refreshRequests = 0
        MockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":28800}"#.utf8)
                )
            }
            usageRequests += 1
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                usageRequests == 1 ? "token old-access" : "token new-access"
            )
            let statusCode = usageRequests == 1 ? 401 : 200
            let data = usageRequests == 1
                ? Data()
                : Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderSeparatesRateLimitFromMissingAccess() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            "legacy-access",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!
        )
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["X-RateLimit-Remaining": "0"]
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "GitHub rate limit reached. Try again later.")
    }

    func testCopilotOrganizationUsageDistinguishesPermissionFailureFromMissingOrganization() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "HemSoft"
        )
        try secretStore.saveSecret(
            "legacy-access",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            githubAPIBaseURL: URL(string: "https://example.test")!
        )
        var statusCode = 403
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "This GitHub account lacks permission to read the configured Copilot organization billing data."
        )

        statusCode = 404
        let missing = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(
            missing.subtitle,
            "GitHub Copilot organization not found. Check the configured organization name."
        )
    }

    func testCodexUsageWithoutCredentialIsNotDemoData() async throws {
        let provider = CodexUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .codex)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with ChatGPT.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testClaudeUsageWithoutCredentialIsNotDemoData() async throws {
        let provider = ClaudeUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Claude.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testClaudeUsageProviderPreservesStaleSnapshotOnRateLimitWithoutProbe() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                subscriptionType: "pro",
                rateLimitTier: nil,
                expiresAt: 0,
                accessToken: "claude-token",
                refreshToken: nil
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let clock = TestDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: urlSessionConfiguration),
            now: { clock.now() }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            if requestCount == 1 {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":36,"is_active":true}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let fresh = try await provider.fetchUsage(for: configuration)
        let stale = try await provider.fetchUsage(for: configuration)
        let backedOff = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(fresh.bars, stale.bars)
        XCTAssertEqual(stale.bars, backedOff.bars)
        XCTAssertEqual(fresh.fetchedAt, stale.fetchedAt)
        XCTAssertTrue(stale.subtitle.contains("rate-limited"))
        XCTAssertTrue(stale.subtitle.contains("last known data"))

        clock.advance(by: 121)
        _ = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(requestCount, 3)
    }

    func testClaudeUsageProviderClearsBackoffWhenCredentialChanges() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "old-token")),
            account: keychainAccount
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: ["Retry-After": "3600"]
                    )!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"limits":[{"kind":"weekly_all","percent":24,"is_active":true}]}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let rateLimited = try await provider.fetchUsage(for: configuration)
        XCTAssertTrue(rateLimited.subtitle.contains("rate-limited"))

        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "new-token")),
            account: keychainAccount
        )
        let refreshed = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(refreshed.bars.first?.used, 24)
        XCTAssertFalse(refreshed.subtitle.contains("rate-limited"))
    }

    func testClaudeUsageProviderCachesSuccessfulHeaderFallbackForLaterRateLimit() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{}"#.utf8)
                )
            }
            if requestCount == 2 {
                XCTAssertEqual(request.url?.path, "/v1/messages")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "anthropic-ratelimit-unified-5h-utilization": "0.25",
                            "anthropic-ratelimit-unified-5h-reset": "1893456000",
                        ]
                    )!,
                    Data()
                )
            }
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let fallback = try await provider.fetchUsage(for: configuration)
        let stale = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(fallback.bars, stale.bars)
        XCTAssertEqual(fallback.fetchedAt, stale.fetchedAt)
        XCTAssertTrue(stale.subtitle.contains("last known data"))
    }

    func testClaudeUsageProviderMergesOAuthOnlyStateWithHeaderFallback() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/api/oauth/usage" {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"extra_usage":{"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/v1/messages")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "anthropic-ratelimit-unified-5h-utilization": "0.25",
                        "anthropic-ratelimit-unified-5h-reset": "1893456000",
                    ]
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(result.usageMessages, ["Usage-credit enabled status was not reported."])

        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/oauth/usage" {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8)
                )
            }
            throw URLError(.timedOut)
        }
        let preserved = try await ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        ).fetchUsage(for: configuration)
        XCTAssertEqual(preserved.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertTrue(preserved.bars.isEmpty)
    }

    func testClaudeUsageProviderDoesNotProbeMessagesOnlySnapshotDuringBackoff() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"extra_usage":{"is_enabled":false}}"#.utf8)
                )
            }
            if requestCount == 2 {
                XCTAssertEqual(request.url?.path, "/v1/messages")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let messagesOnly = try await provider.fetchUsage(for: configuration)
        let stale = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(messagesOnly.usageMessages, stale.usageMessages)
        XCTAssertTrue(stale.subtitle.contains("rate-limited"))
    }

    func testClaudeUsageProviderDistinguishesOAuthUsageFailures() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                accessToken: "claude-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: urlSessionConfiguration)
        )
        var statusCode = 401
        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/messages" {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let unauthorized = try await provider.fetchUsage(for: configuration)
        statusCode = 403
        let forbidden = try await provider.fetchUsage(for: configuration)
        statusCode = 404
        let missing = try await provider.fetchUsage(for: configuration)
        statusCode = 503
        let unavailable = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(unauthorized.subtitle, "Claude credential was rejected. Sign in again.")
        XCTAssertEqual(forbidden.subtitle, "Claude credential lacks permission to read subscription usage.")
        XCTAssertEqual(missing.subtitle, "Claude subscription usage is unavailable for this account.")
        XCTAssertEqual(unavailable.subtitle, "Claude usage is temporarily unavailable (server error 503).")
    }

    @MainActor
    func testDemoRefreshReturnsSortedResults() async {
        let service = UsageRefreshService.demo()

        await service.refresh()

        XCTAssertEqual(
            service.results.map(\.providerID),
            [.codex, .claude, .cursor, .copilot, .openCodeZen, .openRouter]
        )
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }

    @MainActor
    func testLiveRefreshIncludesOpenRouterProvider() async throws {
        let secretStore = MemorySecretStore()
        var openRouter = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        openRouter.accountLabel = "OpenRouter API"
        try secretStore.saveSecret("sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: openRouter))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenRouterUsageProvider(secretStore: secretStore, session: session)
        ])

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/credits")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"data":{"total_credits":10,"total_usage":2.5}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        await service.refresh(configurations: [openRouter])

        let result = try XCTUnwrap(service.results.first)
        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.title, "OpenRouter API")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 7.5, accuracy: 0.0001)
    }

    @MainActor
    func testSingleAccountRefreshUpdatesOnlyRequestedProvider() async throws {
        let secretStore = MemorySecretStore()
        var openCode = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        openCode.accountLabel = "OpenCode ZEN"
        openCode.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: openCode)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenCodeZenUsageProvider(secretStore: secretStore, session: session),
            HangingUsageProvider(providerID: .openRouter),
        ])

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/workspace/wrk_test/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                Data(#"<html>balance:1225000000</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let refreshedResult = await service.refresh(configuration: openCode)
        let result = try XCTUnwrap(refreshedResult)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.25, accuracy: 0.0001)
        XCTAssertEqual(service.results.map(\.accountID), [openCode.id])
    }

    private func makeHistoryResult(
        accountID: String,
        providerID: ProviderID = .codex,
        fetchedAt: Date,
        used: Double? = nil,
        bars: [UsageBar]? = nil,
        creditsRemaining: Double? = nil
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: accountID,
            providerID: providerID,
            title: providerID.displayName,
            subtitle: "Test data",
            bars: bars ?? used.map { [UsageBar(label: "Usage", used: $0, limit: 100)] } ?? [],
            creditsRemaining: creditsRemaining,
            fetchedAt: fetchedAt
        )
    }
}

private struct EmptySecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        nil
    }

    func saveSecret(_ secret: String, account: String) throws {
    }

    func deleteSecret(account: String) throws {
    }
}

private actor StubAppStoreReleaseFetcher: AppStoreReleaseFetching {
    private var result: Result<AppStoreRelease, AppStoreReleaseError>
    private var fetchCount = 0

    init(result: Result<AppStoreRelease, AppStoreReleaseError>) {
        self.result = result
    }

    func fetchRelease() async throws -> AppStoreRelease {
        fetchCount += 1
        return try result.get()
    }

    func setResult(_ result: Result<AppStoreRelease, AppStoreReleaseError>) {
        self.result = result
    }

    func currentFetchCount() -> Int {
        fetchCount
    }
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}

private final class FailingSaveSecretStore: SecretStore, @unchecked Sendable {
    private let secret: String

    init(secret: String) {
        self.secret = secret
    }

    func readSecret(account: String) throws -> String? {
        secret
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw KeychainError.unhandledStatus(-25308)
    }

    func deleteSecret(account: String) throws {}
}

private final class StaleThirdReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let initialSecret: String
    private var currentSecret: String
    private var readCount = 0

    init(initialSecret: String) {
        self.initialSecret = initialSecret
        self.currentSecret = initialSecret
    }

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return readCount == 3 ? initialSecret : currentSecret
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        currentSecret = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        currentSecret = ""
    }
}

private final class ReplacingThirdReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let initialSecret: String
    private let replacementSecret: String
    private var readCount = 0
    private var storedSaveCount = 0

    init(initialSecret: String, replacementSecret: String) {
        self.initialSecret = initialSecret
        self.replacementSecret = replacementSecret
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSaveCount
    }

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return readCount >= 3 ? replacementSecret : initialSecret
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storedSaveCount += 1
    }

    func deleteSecret(account: String) throws {}
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer {
        stream.close()
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let byteCount = stream.read(&buffer, maxLength: buffer.count)
        guard byteCount > 0 else {
            break
        }
        data.append(contentsOf: buffer.prefix(byteCount))
    }
    return data
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class TestDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date.addTimeInterval(interval)
        }
    }
}

private struct HangingUsageProvider: UsageProvider {
    let providerID: ProviderID

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        try await Task.sleep(for: .seconds(60))
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: providerID.displayName,
            subtitle: "Unexpected",
            bars: [],
            fetchedAt: Date()
        )
    }
}

private extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
