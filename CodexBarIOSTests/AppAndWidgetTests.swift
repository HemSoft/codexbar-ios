import XCTest
@testable import CodexBarIOS

final class AppAndWidgetTests: XCTestCase {
    func testProviderDeepLinkRoundTripsAccountID() throws {
        let accountID = "claude.work + personal/primary?"
        let url = try XCTUnwrap(CodexBarDeepLink.providerURL(accountID: accountID))

        XCTAssertEqual(url.scheme, "codexbar")
        XCTAssertEqual(url.host, "provider")
        XCTAssertEqual(CodexBarDeepLink.providerAccountID(from: url), accountID)
    }

    func testProviderDeepLinkRejectsUnsupportedOrAmbiguousRoutes() throws {
        XCTAssertNil(CodexBarDeepLink.providerURL(accountID: ""))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "https://provider?account=codex")!))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "codexbar://settings?account=codex")!))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "codexbar://provider/details?account=codex")!))
        XCTAssertNil(CodexBarDeepLink.providerAccountID(from: URL(string: "codexbar://provider")!))
        XCTAssertNil(
            CodexBarDeepLink.providerAccountID(
                from: URL(string: "codexbar://provider?account=codex&account=claude")!
            )
        )
    }

    func testDashboardDeepLinkNavigationKeepsTargetUntilRefreshReorderSettles() {
        var navigation = DashboardDeepLinkNavigationState()
        navigation.begin(accountID: "claude.work", waitsForRefresh: true)

        XCTAssertEqual(navigation.accountID, "claude.work")
        XCTAssertFalse(navigation.shouldFinishAfterInitialScroll)

        navigation.finish(accountID: "another-account")
        XCTAssertEqual(navigation.accountID, "claude.work")

        navigation.finish(accountID: "claude.work")
        XCTAssertNil(navigation.accountID)
        XCTAssertFalse(navigation.waitsForRefresh)
    }

    func testDashboardDeepLinkNavigationFinishesWarmLaunchAfterInitialScroll() {
        var navigation = DashboardDeepLinkNavigationState()
        navigation.begin(accountID: "codex", waitsForRefresh: false)

        XCTAssertTrue(navigation.shouldFinishAfterInitialScroll)

        navigation.finish(accountID: "codex")
        XCTAssertNil(navigation.accountID)
    }

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
            ProviderAccountConfiguration.defaultConfiguration(for: .moonshot).authMethod,
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
        configuration.protocolClasses = [AppAndWidgetMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = AppStoreReleaseService(session: session)

        AppAndWidgetMockURLProtocol.handler = { request in
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
            AppAndWidgetMockURLProtocol.handler = nil
        }

        let fetchedRelease = try await service.fetchRelease()
        XCTAssertEqual(fetchedRelease.version, "1.2")

        AppAndWidgetMockURLProtocol.handler = { request in
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

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(store.autoRefreshInterval, .off)

        store.updateAutoRefreshInterval(.fiveMinutes)

        let reloadedStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(reloadedStore.autoRefreshInterval, .fiveMinutes)
    }

    @MainActor
    func testWidgetRefreshIntervalDefaultsToThirtyMinutesAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        XCTAssertEqual(store.widgetRefreshInterval, .thirtyMinutes)

        store.updateWidgetRefreshInterval(.oneHour)

        let reloadedStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
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

    func testWidgetSnapshotStoreUsesPreviewFixtureForWidgetGallery() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let storedSnapshot = CodexBarWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_788_475_200),
            results: []
        )
        let storedBuilderConfiguration = CodexBarWidgetBuilderConfiguration(
            layout: .oneTile,
            selectedTileIDs: ["provider.real-account"]
        )
        WidgetSnapshotStore.saveSnapshot(storedSnapshot, defaults: defaults)
        WidgetSnapshotStore.saveBuilderConfiguration(storedBuilderConfiguration, defaults: defaults)

        XCTAssertEqual(
            WidgetSnapshotStore.loadSnapshot(forPreview: false, defaults: defaults),
            storedSnapshot
        )
        XCTAssertEqual(
            WidgetSnapshotStore.loadSnapshot(forPreview: true, defaults: defaults),
            .preview
        )
        XCTAssertEqual(
            WidgetSnapshotStore.loadBuilderConfiguration(forPreview: false, defaults: defaults),
            storedBuilderConfiguration
        )
        XCTAssertEqual(
            WidgetSnapshotStore.loadBuilderConfiguration(forPreview: true, defaults: defaults),
            .default
        )
        XCTAssertEqual(
            CodexBarWidgetSnapshot.preview.results.map(\.providerID),
            ["codex", "copilot", "claude", "cursor", "moonshot", "openCodeZen", "openRouter"]
        )
    }

    func testSharedWidgetRenderingMapsEveryProviderLogo() {
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "codex"), "CodexLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "copilot"), "CopilotLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "claude"), "ClaudeLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "cursor"), "CursorLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "moonshot"), "MoonshotLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "openCodeZen"), "OpenCodeZenLogo")
        XCTAssertEqual(CodexBarProviderLogo.assetName(for: "openRouter"), "OpenRouterLogo")
        XCTAssertNil(CodexBarProviderLogo.assetName(for: "unknown"))
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
                        CodexBarWidgetMonetaryMetricSnapshot(
                            kind: ProviderMonetaryMetricKind.remainingHeadroom.rawValue,
                            label: "Remaining spend headroom",
                            minorUnits: 0,
                            currencyCode: "EUR",
                            decimalPlaces: 2,
                            detail: "Not a prepaid balance"
                        ),
                    ],
                    fetchedAt: Date(timeIntervalSince1970: 1_788_475_200),
                    severity: .critical
                ),
            ]
        )

        let tile = try XCTUnwrap(snapshot.builderTiles.first { $0.id == "provider.claude.personal" })

        XCTAssertEqual(tile.title, "Usage credits spent")
        XCTAssertEqual(tile.subtitle, "Month to date")
        XCTAssertTrue(tile.value.contains("12"))
        XCTAssertTrue(tile.value.contains("50"))
        XCTAssertEqual(snapshot.results.first?.summaryMonetaryMetric?.label, "Usage credits spent")
        XCTAssertEqual(snapshot.results.first?.standaloneMonetaryMetrics.count, 1)
        XCTAssertEqual(snapshot.builderTiles.count, 2)
        XCTAssertEqual(snapshot.builderTiles.last?.severity, .critical)

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

    @MainActor
    func testWidgetSnapshotPublisherUsesConfigurationOrderWhenManualOrderIsEmpty() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let claude = store.addAccount(for: .claude)
        let openRouter = store.addAccount(for: .openRouter)
        store.saveSecret("claude-token", for: claude)
        store.saveSecret("openrouter-key", for: openRouter)
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let claudeResult = ProviderUsageResult(
            accountID: claude.id,
            providerID: .claude,
            title: claude.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: fetchedAt
        )
        let openRouterResult = ProviderUsageResult(
            accountID: openRouter.id,
            providerID: .openRouter,
            title: openRouter.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [openRouterResult, claudeResult],
            configurationStore: store,
            snapshotDefaults: defaults
        )

        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        XCTAssertEqual(snapshot.results.map(\.accountID), [claude.id, openRouter.id])
    }

    @MainActor
    func testWidgetSnapshotPublisherNeutralizesStaleBarSeverityAndProjection() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let configuration = store.addAccount(for: .claude)
        store.saveSecret("claude-token", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: configuration.displayName,
            subtitle: "Fresh monetary usage with cached rate limits",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 95,
                    limit: 100,
                    projectionCurrent: 100,
                    projectionLimit: 100,
                    projectionPeriodStart: fetchedAt.addingTimeInterval(-60 * 60),
                    projectionPeriodEnd: fetchedAt.addingTimeInterval(60 * 60)
                ),
            ],
            barsFetchedAt: fetchedAt.addingTimeInterval(-60),
            fetchedAt: fetchedAt
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults,
            now: fetchedAt
        )

        let provider = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first)
        let bar = try XCTUnwrap(provider.bars.first)
        XCTAssertEqual(provider.severity, .normal)
        XCTAssertEqual(bar.severity, .normal)
        XCTAssertNil(bar.projectedFraction)
        XCTAssertNil(bar.projectedSeverity)
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
        XCTAssertTrue(configuration.showsHistory)
    }

    @MainActor
    func testProviderHistoryVisibilityPersistsIndependentlyAcrossAccounts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Personal"))
        var codex = store.addAccount(for: .codex)
        let claude = store.addAccount(for: .claude)

        XCTAssertTrue(codex.showsHistory)
        XCTAssertTrue(claude.showsHistory)

        codex.showsHistory = false
        codex.accountLabel = "Primary Codex"
        codex.groupID = group.id
        XCTAssertTrue(store.update(codex))

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let reloadedCodex = try XCTUnwrap(reloadedStore.configuration(accountID: codex.id))
        let reloadedClaude = try XCTUnwrap(reloadedStore.configuration(accountID: claude.id))

        XCTAssertFalse(reloadedCodex.showsHistory)
        XCTAssertEqual(reloadedCodex.accountLabel, "Primary Codex")
        XCTAssertEqual(reloadedCodex.groupID, group.id)
        XCTAssertTrue(reloadedClaude.showsHistory)
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

    func testDashboardUsageSorterIgnoresStaleBarUrgency() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let staleCritical = ProviderUsageResult(
            accountID: "stale.critical",
            providerID: .claude,
            title: "Claude",
            subtitle: "Cached rate limits",
            bars: [UsageBar(label: "Weekly", used: 95, limit: 100)],
            barsFetchedAt: now.addingTimeInterval(-60),
            fetchedAt: now
        )
        let freshWarning = makeHistoryResult(
            accountID: "fresh.warning",
            providerID: .codex,
            fetchedAt: now,
            used: 80
        )

        XCTAssertEqual(staleCritical.highestSeverity(at: now), .normal)
        let ordered = DashboardUsageSorter.orderedResults(
            [staleCritical, freshWarning],
            mode: .smart,
            manualOrder: [],
            now: now
        )
        XCTAssertEqual(ordered.map(\.accountID), ["fresh.warning", "stale.critical"])
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

}
