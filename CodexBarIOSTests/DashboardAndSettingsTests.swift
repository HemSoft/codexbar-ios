import XCTest
@testable import CodexBarIOS

final class DashboardAndSettingsTests: XCTestCase {
    @MainActor
    func testDemoRefreshReturnsEveryProviderResult() async {
        let service = UsageRefreshService.demo()

        await service.refresh()

        XCTAssertEqual(
            Set(service.results.map(\.providerID)),
            Set(ProviderID.allCases)
        )
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }

    func testDashboardCardItemsRepresentConfiguredAccountsBeforeResultsArrive() {
        var codex = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        codex.accountLabel = "Personal Codex"
        var claude = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        claude.accountLabel = "Work Claude"

        let items = DashboardProviderCardItem.items(
            configurations: [codex, claude],
            results: [],
            refreshingAccountIDs: [codex.id, claude.id],
            errorsByAccountID: [:],
            orderingMode: .manual,
            manualOrder: [claude.id, codex.id]
        )

        XCTAssertEqual(items.map(\.id), [claude.id, codex.id])
        XCTAssertEqual(items.map(\.configuration.displayName), ["Work Claude", "Personal Codex"])
        XCTAssertTrue(items.allSatisfy { $0.result == nil && $0.isRefreshing })
    }

    func testDashboardCardItemsAreEmptyWhenNoProvidersAreConfigured() {
        let staleResult = makeHistoryResult(
            accountID: "removed.account",
            fetchedAt: Date(),
            used: 10
        )

        let items = DashboardProviderCardItem.items(
            configurations: [],
            results: [staleResult],
            refreshingAccountIDs: [],
            errorsByAccountID: [:],
            orderingMode: .manual,
            manualOrder: []
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testDashboardCardItemsKeepLoadedAndFailedAccountsVisible() {
        let codex = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let claude = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let codexResult = makeHistoryResult(
            accountID: codex.id,
            providerID: .codex,
            fetchedAt: Date(),
            used: 25
        )

        let items = DashboardProviderCardItem.items(
            configurations: [codex, claude],
            results: [codexResult],
            refreshingAccountIDs: [codex.id],
            errorsByAccountID: [claude.id: "Session expired"],
            orderingMode: .manual,
            manualOrder: []
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].result, codexResult)
        XCTAssertTrue(items[0].isRefreshing)
        XCTAssertNil(items[1].result)
        XCTAssertEqual(items[1].errorMessage, "Session expired")
    }

    @MainActor
    func testRefreshPublishesAccountsAsEachFetchCompletes() async {
        let gate = UsageProviderGate()
        let slow = ProviderAccountConfiguration(
            id: "codex.slow",
            providerID: .codex,
            accountLabel: "A Slow Codex",
            authMethod: .browserSession
        )
        let fast = ProviderAccountConfiguration(
            id: "codex.fast",
            providerID: .codex,
            accountLabel: "Z Fast Codex",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(providerID: .codex, blockedAccountID: slow.id, gate: gate),
        ])

        let refreshTask = Task {
            await service.refresh(configurations: [slow, fast])
        }
        await gate.waitUntilBlocked()
        for _ in 0..<100 where service.results.first(where: { $0.accountID == fast.id }) == nil {
            await Task.yield()
        }

        XCTAssertEqual(service.results.map(\.accountID), [fast.id])
        XCTAssertEqual(service.refreshingAccountIDs, [slow.id])
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [slow.id])
        XCTAssertTrue(service.isRefreshing)

        await gate.release()
        await refreshTask.value

        XCTAssertEqual(service.results.map(\.accountID), [fast.id, slow.id])
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }

    @MainActor
    func testRefreshPreservesCachedResultWhileAccountIsLoading() async {
        let gate = UsageProviderGate()
        let configuration = ProviderAccountConfiguration(
            id: "codex.cached",
            providerID: .codex,
            accountLabel: "Cached Codex",
            authMethod: .browserSession
        )
        let cachedResult = makeHistoryResult(
            accountID: configuration.id,
            providerID: .codex,
            fetchedAt: Date().addingTimeInterval(-300),
            used: 15
        )
        let service = UsageRefreshService(
            providers: [
                GatedUsageProvider(
                    providerID: .codex,
                    blockedAccountID: configuration.id,
                    gate: gate
                ),
            ],
            initialResults: [cachedResult]
        )

        let refreshTask = Task {
            await service.refresh(configurations: [configuration])
        }
        await gate.waitUntilBlocked()

        XCTAssertEqual(service.results, [cachedResult])
        XCTAssertEqual(service.refreshingAccountIDs, [configuration.id])

        await gate.release()
        await refreshTask.value

        XCTAssertEqual(service.results.first?.accountID, configuration.id)
        XCTAssertNotEqual(service.results.first, cachedResult)
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testExplicitAccountRefreshQueuesBehindInFlightStartupRefresh() async {
        let gate = UsageProviderGate()
        let startupConfiguration = ProviderAccountConfiguration(
            id: "codex.queued",
            providerID: .codex,
            accountLabel: "Original Codex",
            authMethod: .browserSession
        )
        var updatedConfiguration = startupConfiguration
        updatedConfiguration.accountLabel = "Updated Codex"
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: startupConfiguration.id,
                gate: gate
            ),
        ])

        let startupRefresh = Task {
            await service.refresh(configurations: [startupConfiguration])
        }
        await gate.waitUntilBlocked()
        let explicitRefresh = Task {
            await service.refresh(configuration: updatedConfiguration)
        }
        await Task.yield()

        XCTAssertEqual(service.refreshingAccountIDs, [startupConfiguration.id])

        await gate.release()
        await startupRefresh.value
        let updatedResult = await explicitRefresh.value

        XCTAssertEqual(updatedResult?.title, "Updated Codex")
        XCTAssertEqual(service.results.first?.title, "Updated Codex")
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testBatchRefreshRechecksAccountsAfterWaitingForInFlightRefresh() async {
        let firstGate = UsageProviderGate()
        let secondGate = UsageProviderGate()
        let recorder = UsageProviderRecorder()
        let first = ProviderAccountConfiguration(
            id: "codex.first-explicit",
            providerID: .codex,
            accountLabel: "First Codex",
            authMethod: .browserSession
        )
        let second = ProviderAccountConfiguration(
            id: "codex.second-explicit",
            providerID: .codex,
            accountLabel: "Second Codex",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            AccountGatedUsageProvider(
                providerID: .codex,
                gates: [first.id: firstGate, second.id: secondGate],
                recorder: recorder
            ),
        ])

        let secondRefresh = Task {
            await service.refresh(configuration: second)
        }
        await secondGate.waitUntilBlocked()
        let batchRefresh = Task {
            await service.refresh(configurations: [first, second])
        }
        while service.refreshWaiterCount(for: second.id) < 1 {
            await Task.yield()
        }
        let firstRefresh = Task {
            await service.refresh(configuration: first)
        }
        await firstGate.waitUntilBlocked()

        await secondGate.release()
        _ = await secondRefresh.value
        while service.refreshWaiterCount(for: first.id) < 1 {
            await Task.yield()
        }

        let labelsBeforeFirstRelease = await recorder.recordedLabels()
        XCTAssertEqual(labelsBeforeFirstRelease.filter { $0 == first.accountLabel }.count, 1)
        XCTAssertEqual(service.refreshingAccountIDs, [first.id])

        await firstGate.release()
        _ = await firstRefresh.value
        await batchRefresh.value

        let completedLabels = await recorder.recordedLabels()
        XCTAssertEqual(completedLabels.filter { $0 == first.accountLabel }.count, 2)
        XCTAssertEqual(completedLabels.filter { $0 == second.accountLabel }.count, 2)
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testConcurrentBatchRefreshQueuesOneFollowUpRun() async {
        let gate = UsageProviderGate()
        let recorder = UsageProviderRecorder()
        let firstConfiguration = ProviderAccountConfiguration(
            id: "codex.coalesced",
            providerID: .codex,
            accountLabel: "Original Codex",
            authMethod: .browserSession
        )
        var pendingConfiguration = firstConfiguration
        pendingConfiguration.accountLabel = "Intermediate Codex"
        var latestConfiguration = firstConfiguration
        latestConfiguration.accountLabel = "Updated Codex"
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: firstConfiguration.id,
                gate: gate,
                recorder: recorder
            ),
        ])
        let pendingRefreshCompleted = AsyncFlag()
        let latestRefreshCompleted = AsyncFlag()

        let firstRefresh = Task {
            await service.refresh(configurations: [firstConfiguration])
        }
        await gate.waitUntilBlocked()
        let pendingRefresh = Task {
            await service.refresh(configurations: [pendingConfiguration])
            await pendingRefreshCompleted.set()
        }
        while service.queuedBatchRefreshCount < 1 {
            await Task.yield()
        }

        let completedBeforeRelease = await pendingRefreshCompleted.currentValue()
        XCTAssertFalse(completedBeforeRelease)
        let latestRefresh = Task {
            await service.refresh(configurations: [latestConfiguration])
            await latestRefreshCompleted.set()
        }
        while service.queuedBatchRefreshCount < 2 {
            await Task.yield()
        }
        let latestCompletedBeforeRelease = await latestRefreshCompleted.currentValue()
        XCTAssertFalse(latestCompletedBeforeRelease)

        await gate.release()
        await firstRefresh.value
        await pendingRefresh.value
        await latestRefresh.value

        let completedAfterRelease = await pendingRefreshCompleted.currentValue()
        XCTAssertTrue(completedAfterRelease)
        let latestCompletedAfterRelease = await latestRefreshCompleted.currentValue()
        XCTAssertTrue(latestCompletedAfterRelease)
        let recordedLabels = await recorder.recordedLabels()
        XCTAssertEqual(recordedLabels, ["Original Codex", "Updated Codex"])
        XCTAssertEqual(service.results.map(\.accountID), [latestConfiguration.id])
        XCTAssertEqual(service.results.first?.title, "Updated Codex")
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
    }

    @MainActor
    func testRefreshTracksFailuresPerAccountWithoutDiscardingSuccessfulResults() async {
        let failed = ProviderAccountConfiguration(
            id: "codex.failed",
            providerID: .codex,
            accountLabel: "Failed Codex",
            authMethod: .browserSession
        )
        let successful = ProviderAccountConfiguration(
            id: "codex.successful",
            providerID: .codex,
            accountLabel: "Successful Codex",
            authMethod: .browserSession
        )
        let cachedFailedResult = ProviderUsageResult(
            accountID: failed.id,
            providerID: .codex,
            title: failed.displayName,
            subtitle: "Cached usage",
            bars: [UsageBar(label: "Usage", used: 75, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 2,
                canConsume: true
            ),
            fetchedAt: Date().addingTimeInterval(-300)
        )
        let service = UsageRefreshService(
            providers: [
                SelectivelyFailingUsageProvider(providerID: .codex, failedAccountID: failed.id),
            ],
            initialResults: [cachedFailedResult]
        )

        await service.refresh(configurations: [failed, successful])

        XCTAssertEqual(Set(service.results.map(\.accountID)), [failed.id, successful.id])
        let preservedFailure = service.results.first { $0.accountID == failed.id }
        XCTAssertEqual(preservedFailure?.bars, cachedFailedResult.bars)
        XCTAssertEqual(preservedFailure?.codexBankedRateLimitResets, cachedFailedResult.codexBankedRateLimitResets)
        XCTAssertEqual(preservedFailure?.fetchedAt, cachedFailedResult.fetchedAt)
        XCTAssertEqual(preservedFailure?.failureMessage, "Refresh failed")
        XCTAssertEqual(
            preservedFailure?.subtitle,
            "Refresh failed Showing last known data."
        )
        XCTAssertEqual(service.successfulRefreshResults.map(\.accountID), [successful.id])
        XCTAssertEqual(service.refreshErrorsByAccountID[failed.id], "Refresh failed")
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [failed.id])
        XCTAssertNil(service.refreshErrorsByAccountID[successful.id])
        XCTAssertTrue(service.refreshingAccountIDs.isEmpty)
        XCTAssertNotNil(service.lastRefreshError)

        let explicitFailure = await service.refresh(configuration: failed)

        XCTAssertEqual(explicitFailure?.accountID, failed.id)
        XCTAssertEqual(explicitFailure?.failureMessage, "Refresh failed")
        XCTAssertEqual(explicitFailure?.subtitle, "Refresh failed")
        XCTAssertEqual(
            service.results.first { $0.accountID == failed.id }?.bars,
            cachedFailedResult.bars
        )
    }

    @MainActor
    func testThrownRefreshFailureCreatesResultWithoutCachedUsage() async {
        let configuration = ProviderAccountConfiguration(
            id: "codex.first-failure",
            providerID: .codex,
            accountLabel: "First Failure",
            authMethod: .browserSession
        )
        let service = UsageRefreshService(providers: [
            SelectivelyFailingUsageProvider(
                providerID: .codex,
                failedAccountID: configuration.id
            ),
        ])

        await service.refresh(configurations: [configuration])

        XCTAssertEqual(service.results.first?.accountID, configuration.id)
        XCTAssertEqual(service.results.first?.title, "First Failure")
        XCTAssertEqual(service.results.first?.subtitle, "Refresh failed")
        XCTAssertEqual(service.results.first?.failureMessage, "Refresh failed")
        XCTAssertTrue(service.results.first?.bars.isEmpty == true)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Refresh failed")
    }

    @MainActor
    func testRefreshTreatsReturnedFailureResultAsFailureAndPreservesCache() async {
        let configuration = ProviderAccountConfiguration(
            id: "codex.returned-failure",
            providerID: .codex,
            accountLabel: "Cached Codex",
            authMethod: .browserSession
        )
        let cachedResult = makeHistoryResult(
            accountID: configuration.id,
            providerID: .codex,
            fetchedAt: Date().addingTimeInterval(-300),
            used: 75
        )
        let service = UsageRefreshService(
            providers: [ReturningFailureUsageProvider(providerID: .codex)],
            initialResults: [cachedResult]
        )

        await service.refresh(configurations: [configuration])

        XCTAssertEqual(service.results.first?.bars, cachedResult.bars)
        XCTAssertEqual(
            service.results.first?.subtitle,
            "Credential expired Showing last known data."
        )
        XCTAssertEqual(service.results.first?.failureMessage, "Credential expired")
        XCTAssertEqual(service.results.first?.fetchedAt, cachedResult.fetchedAt)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Credential expired")
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [configuration.id])
        XCTAssertEqual(service.lastRefreshError, "Credential expired")

        let explicitResult = await service.refresh(configuration: configuration)

        XCTAssertEqual(explicitResult?.failureMessage, "Credential expired")
        XCTAssertEqual(explicitResult?.subtitle, "Credential expired")
        XCTAssertEqual(service.results.first?.bars, cachedResult.bars)
        XCTAssertEqual(service.results.first?.failureMessage, "Credential expired")
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Credential expired")
    }

    @MainActor
    func testLiveRefreshIncludesOpenRouterProvider() async throws {
        let secretStore = MemorySecretStore()
        var openRouter = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        openRouter.accountLabel = "OpenRouter API"
        try secretStore.saveSecret("sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: openRouter))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [DashboardAndSettingsMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenRouterUsageProvider(secretStore: secretStore, session: session)
        ])

        DashboardAndSettingsMockURLProtocol.handler = { request in
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
            DashboardAndSettingsMockURLProtocol.handler = nil
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
        urlSessionConfiguration.protocolClasses = [DashboardAndSettingsMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenCodeZenUsageProvider(secretStore: secretStore, session: session),
            HangingUsageProvider(providerID: .openRouter),
        ])

        DashboardAndSettingsMockURLProtocol.handler = { request in
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
            DashboardAndSettingsMockURLProtocol.handler = nil
        }

        let refreshedResult = await service.refresh(configuration: openCode)
        let result = try XCTUnwrap(refreshedResult)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.25, accuracy: 0.0001)
        XCTAssertEqual(service.results.map(\.accountID), [openCode.id])
    }

    @MainActor
    func testWidgetSnapshotCoordinatorPublishesStoreAndRefreshChangesReactively() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: EmptySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = store.addAccount(for: .codex)
        let service = UsageRefreshService(providers: [
            GatedUsageProvider(
                providerID: .codex,
                blockedAccountID: "never",
                gate: UsageProviderGate()
            ),
        ])
        var publishedAccountIDs: [[String]] = []
        var settingsPublishCount = 0
        let coordinator = WidgetSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            publishSnapshot: { results, _ in
                publishedAccountIDs.append(results.map(\.accountID))
            },
            publishSettings: { _ in
                settingsPublishCount += 1
            }
        )

        await service.refresh(configurations: [configuration])
        await Task.yield()
        XCTAssertEqual(publishedAccountIDs.last, [configuration.id])

        let snapshotCount = publishedAccountIDs.count
        store.updateDashboardCardOrder([configuration.id])
        await Task.yield()
        XCTAssertEqual(publishedAccountIDs.count, snapshotCount + 1)

        store.updateWidgetRefreshInterval(.oneHour)
        await Task.yield()
        XCTAssertEqual(settingsPublishCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testWatchSnapshotContainsPresentationOnlyMetricsAndEveryStyle() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = store.addAccount(for: .codex)
        XCTAssertTrue(store.saveSecret("watch-must-never-see-this-secret", for: configuration))
        store.updateAutoRefreshInterval(.fiveMinutes)

        let bars = MetricVisualizationStyle.allCases.enumerated().map { index, style in
            let bar = UsageBar(
                stableKey: "metric-\(index)",
                label: style.displayName,
                used: Double(index + 1),
                limit: 10,
                resetDescription: "Resets later"
            )
            store.updateVisualizationStyle(
                style,
                accountID: configuration.id,
                metricID: bar.metricIdentifier(providerID: .codex, index: index)
            )
            return bar
        }
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Pro",
            bars: bars,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )

        XCTAssertEqual(snapshot.refreshIntervalSeconds, 300)
        XCTAssertEqual(snapshot.accounts.map(\.id), ["codex.0"])
        XCTAssertEqual(
            snapshot.accounts[0].metrics.map(\.visualizationStyle),
            WatchMetricVisualizationStyle.allCases
        )
        XCTAssertEqual(snapshot.accounts[0].metrics.map(\.usedFraction), [0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        let encodedText = try XCTUnwrap(String(data: snapshot.encoded(), encoding: .utf8))
        XCTAssertFalse(encodedText.contains("watch-must-never-see-this-secret"))
        XCTAssertFalse(encodedText.contains(configuration.id))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(encodedText.localizedCaseInsensitiveContains("cookie"))

        XCTAssertTrue(store.removeAccount(configuration))
        let afterRemoval = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: result.fetchedAt
        )
        XCTAssertTrue(afterRemoval.accounts.isEmpty)
    }

    func testWatchSnapshotDeduplicatorIgnoresGenerationTimeAndSupportsForcedReassertion() throws {
        let first = WatchDashboardSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        let sameSemanticState = WatchDashboardSnapshot(
            generatedAt: first.generatedAt.addingTimeInterval(60),
            refreshIntervalSeconds: 300,
            accounts: []
        )
        var deduplicator = WatchSnapshotDeduplicator()

        XCTAssertTrue(try deduplicator.shouldSend(first, force: false))
        try deduplicator.recordSent(first)
        XCTAssertFalse(try deduplicator.shouldSend(sameSemanticState, force: false))
        XCTAssertTrue(try deduplicator.shouldSend(sameSemanticState, force: true))

        let changed = WatchDashboardSnapshot(
            generatedAt: sameSemanticState.generatedAt,
            refreshIntervalSeconds: 60,
            accounts: []
        )
        XCTAssertTrue(try deduplicator.shouldSend(changed, force: false))
    }

    @MainActor
    func testWatchSnapshotUsesPreservedBarsFetchTimeForFreshness() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = store.addAccount(for: .claude)
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let barsFetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let refreshedAt = barsFetchedAt.addingTimeInterval(30 * 60)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: "Claude",
            subtitle: "Fresh balance with preserved usage",
            bars: [UsageBar(stableKey: "window", label: "Usage", used: 4, limit: 10)],
            barsFetchedAt: barsFetchedAt,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .balance,
                    label: "Balance",
                    minorUnits: 2_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: refreshedAt
        )

        let snapshot = WatchSnapshotPublisher.makeSnapshot(
            results: [result],
            configurationStore: store,
            now: refreshedAt
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.accounts.first).fetchedAt, barsFetchedAt)
    }

    @MainActor
    func testWatchSnapshotCoordinatorActivatesAndCoalescesRapidChanges() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = store.addAccount(for: .codex)
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let bar = UsageBar(stableKey: "window", label: "Usage", used: 4, limit: 10)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "Codex",
            subtitle: "Pro",
            bars: [bar],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let service = UsageRefreshService(providers: [], initialResults: [result])
        let sender = RecordingWatchSnapshotSender()
        let coordinator = WatchSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            sender: sender,
            coalescingDelay: .milliseconds(5)
        )

        XCTAssertEqual(sender.activationCount, 1)
        sender.completeActivation()
        XCTAssertEqual(sender.publishedForces, [true])

        let metricID = bar.metricIdentifier(providerID: .codex, index: 0)
        store.updateVisualizationStyle(.segmentedBar, accountID: configuration.id, metricID: metricID)
        store.updateVisualizationStyle(.circularRing, accountID: configuration.id, metricID: metricID)
        store.updateVisualizationStyle(.largeNumeric, accountID: configuration.id, metricID: metricID)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(sender.publishedForces, [true, false])
        XCTAssertEqual(
            sender.snapshots.last?.accounts[0].metrics[0].visualizationStyle,
            .largeNumeric
        )
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testWatchSnapshotCoordinatorPreservesLastWatchDataWhileInitialRefreshIsPending() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: MemorySecretStore(),
            widgetSnapshotDefaults: defaults
        )
        let configuration = store.addAccount(for: .codex)
        XCTAssertTrue(store.saveSecret("secret", for: configuration))
        let service = UsageRefreshService(providers: [], initialResults: [])
        let sender = RecordingWatchSnapshotSender()
        let coordinator = WatchSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            sender: sender,
            coalescingDelay: .milliseconds(5)
        )

        sender.completeActivation()
        XCTAssertTrue(sender.snapshots.isEmpty)

        XCTAssertTrue(store.removeAccount(configuration))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sender.snapshots.count, 1)
        XCTAssertTrue(sender.snapshots[0].accounts.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testProviderSettingsViewModelDebouncesTextChangesAndFlushesOnDismissal() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let configuration = store.addAccount(for: .openRouter)
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id
        )

        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "Team Router"
        viewModel.binding(for: \.showsHistory).wrappedValue = false

        XCTAssertEqual(viewModel.configuration.accountLabel, "Team Router")
        XCTAssertFalse(viewModel.configuration.showsHistory)
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.accountLabel, "Team Router")
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.showsHistory, false)

        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "Final Router"
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.accountLabel, "Team Router")
        viewModel.flushPendingChanges()

        XCTAssertEqual(viewModel.configuration.accountLabel, "Final Router")
        XCTAssertEqual(store.configuration(accountID: configuration.id)?.accountLabel, "Final Router")
    }

    @MainActor
    func testProviderSettingsViewModelRegistersDefaultAccountBeforeSavingCredential() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: ProviderID.openRouter.rawValue
        )
        viewModel.secret = "sk-or-test"

        viewModel.saveGenericCredential()

        let savedConfiguration = store.configuration(accountID: ProviderID.openRouter.rawValue)
        XCTAssertNotNil(savedConfiguration)
        XCTAssertEqual(viewModel.secret, "")
        XCTAssertTrue(savedConfiguration.map { store.hasSecret(for: $0) } ?? false)
    }

    @MainActor
    func testProviderSettingsViewModelCancelsPendingEditsBeforeCursorSignOut() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let cursor = store.addAccount(for: .cursor)
        let connected = try XCTUnwrap(
            store.connectCursorAccount(cursor, credential: "cursor-token")
        )
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: connected.id
        )

        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "stale@example.com"
        viewModel.signOutOfCursor()
        viewModel.flushPendingChanges()

        XCTAssertEqual(store.configuration(accountID: connected.id)?.accountLabel, "")
        XCTAssertFalse(store.hasSecret(for: connected))
    }

    @MainActor
    func testProviderSettingsViewModelCancelsPendingEditsWhenSavingOpenCodeCredential() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let openCode = store.addAccount(for: .openCodeZen)
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: openCode.id
        )
        viewModel.binding(for: \.accountLabel, persistence: .debounced).wrappedValue = "Team ZEN"
        viewModel.secret = "opencode-token"

        viewModel.saveOpenCodeCredential()
        var externallyUpdated = store.configuration(accountID: openCode.id)!
        externallyUpdated.showsHistory = false
        XCTAssertTrue(store.update(externallyUpdated))
        viewModel.flushPendingChanges()

        XCTAssertEqual(store.configuration(accountID: openCode.id)?.accountLabel, "Team ZEN")
        XCTAssertEqual(store.configuration(accountID: openCode.id)?.showsHistory, false)
    }

    @MainActor
    func testProviderSettingsViewModelReportsCredentialSaveFailureWithoutCompleting() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: FailingSaveSecretStore(secret: "existing-token")
        )
        let configuration = store.addAccount(for: .openRouter)
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 }
        )
        viewModel.secret = "replacement-token"

        viewModel.saveGenericCredential()

        XCTAssertNotNil(viewModel.credentialError)
        XCTAssertEqual(viewModel.secret, "replacement-token")
        XCTAssertEqual(credentialsChangedCount, 0)
    }

    @MainActor
    func testProviderSettingsViewModelReportsCredentialRemovalFailureWithoutCompleting() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: FailingDeleteSecretStore()
        )
        let configuration = store.addAccount(for: .openRouter)
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            onCredentialsChanged: { credentialsChangedCount += 1 }
        )

        viewModel.removeSavedCredential()

        XCTAssertNotNil(viewModel.credentialError)
        XCTAssertEqual(credentialsChangedCount, 0)
    }

    @MainActor
    func testProviderSettingsViewModelClearsCredentialErrorWhenRetryingCodexSignIn() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: FailingDeleteSecretStore()
        )
        let configuration = store.addAccount(for: .codex)
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: configuration.id,
            codexAuthService: CodexWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        )
        viewModel.removeSavedCredential()
        XCTAssertNotNil(viewModel.credentialError)

        await viewModel.signInWithCodex()

        XCTAssertNil(viewModel.credentialError)
        XCTAssertNotNil(viewModel.codexAuthError)
    }

    @MainActor
    func testProviderSettingsViewModelCompletesSuccessfulSaveDespiteUnrelatedReadFailure() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let secretStore = SelectiveReadFailureSecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let unreadable = store.addAccount(for: .openRouter)
        let target = store.addAccount(for: .moonshot)
        secretStore.failingAccount = ProviderConfigurationStore.keychainAccount(for: unreadable)
        var credentialsChangedCount = 0
        let viewModel = ProviderSettingsViewModel(
            configurationStore: store,
            accountID: target.id,
            onCredentialsChanged: { credentialsChangedCount += 1 }
        )
        viewModel.secret = "moonshot-token"

        viewModel.saveGenericCredential()

        XCTAssertNil(viewModel.credentialError)
        XCTAssertEqual(viewModel.secret, "")
        XCTAssertEqual(credentialsChangedCount, 1)
        XCTAssertNotNil(store.lastError)
    }

    @MainActor
    func testRetryableResetFailurePinsRetryToOriginalCredit() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let configuration = store.addAccount(for: .codex)
        let provider = ResetConsumptionTestProvider(
            outcome: .reset,
            fetchFails: false,
            consumeErrorCode: .timedOut
        )
        let service = UsageRefreshService(providers: [provider])
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service,
                configurationStore: store,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            )
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "credit-original"
        )

        XCTAssertFalse(feedback.isSuccess)
        XCTAssertTrue(feedback.requiresSameResetForRetry)
        XCTAssertTrue(service.hasRetainedCodexResetAttempt(for: configuration.id))
        XCTAssertEqual(
            service.retainedCodexResetAttempt(for: configuration.id),
            CodexRetainedResetAttempt(creditID: "credit-original")
        )

        let retryFeedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "credit-different"
        )
        let consumedKeys = await provider.recordedConsumedKeys()
        let consumedCreditIDs = await provider.recordedConsumedCreditIDs()

        XCTAssertFalse(retryFeedback.isSuccess)
        XCTAssertEqual(consumedCreditIDs, ["credit-original", "credit-original"])
        XCTAssertEqual(consumedKeys.count, 2)
        XCTAssertEqual(consumedKeys[0], consumedKeys[1])
    }

    @MainActor
    func testResetConsumptionRefreshesAuthoritativeInventoryAfterSuccess() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let configuration = store.addAccount(for: .codex)
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "Usage", used: 100, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 2,
                credits: [
                    CodexBankedRateLimitReset(id: "credit-first"),
                    CodexBankedRateLimitReset(id: "credit-second"),
                ],
                canConsume: true
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let provider = ResetConsumptionTestProvider(outcome: .reset, fetchFails: false)
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service,
                configurationStore: store,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            )
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "credit-second"
        )

        XCTAssertTrue(feedback.isSuccess)
        XCTAssertNil(service.results.first?.codexBankedRateLimitResets)
        let fetchCount = await provider.recordedFetchCount()
        XCTAssertEqual(fetchCount, 1)
    }

    @MainActor
    func testResetConsumptionRefetchesAndPreservesVerifiedAvailabilityWhenRefreshFails() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let configuration = store.addAccount(for: .codex)
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "Usage", used: 100, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 1,
                canConsume: true
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let provider = ResetConsumptionTestProvider(outcome: .reset, fetchFails: true)
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])
        let historyStore = UsageHistoryStore(defaults: defaults)
        let widgetCoordinator = WidgetSnapshotCoordinator(
            refreshService: service,
            configurationStore: store,
            publishSnapshot: { _, _ in },
            publishSettings: { _ in }
        )
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: historyStore,
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: widgetCoordinator
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: nil
        )

        XCTAssertTrue(feedback.isSuccess)
        XCTAssertTrue(feedback.message.contains("could not be refreshed"))
        let fetchCount = await provider.recordedFetchCount()
        let consumedKeys = await provider.recordedConsumedKeys()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(consumedKeys.count, 1)
        XCTAssertEqual(service.results.first?.codexBankedRateLimitResets, cachedResult.codexBankedRateLimitResets)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Refresh failed")
    }

    @MainActor
    func testNoCreditHidesPreservedResetActionWhenAuthoritativeRefreshFails() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        let configuration = store.addAccount(for: .codex)
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "Usage", used: 100, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 1,
                canConsume: true
            ),
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let provider = ResetConsumptionTestProvider(outcome: .noCredit, fetchFails: true)
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])
        let orchestrator = DashboardOrchestrator(
            refreshService: service,
            configurationStore: store,
            historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier(),
            appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(
                refreshService: service,
                configurationStore: store,
                publishSnapshot: { _, _ in },
                publishSettings: { _ in }
            )
        )

        let feedback = await orchestrator.consumeCodexBankedReset(
            for: configuration,
            creditID: "stale-credit"
        )

        XCTAssertFalse(feedback.isSuccess)
        XCTAssertTrue(feedback.hidesAction)
        XCTAssertEqual(feedback.message, "No banked reset remains for this account.")
        XCTAssertEqual(service.results.first?.codexBankedRateLimitResets, cachedResult.codexBankedRateLimitResets)
        XCTAssertEqual(service.refreshErrorsByAccountID[configuration.id], "Refresh failed")
    }

}

@MainActor
private final class RecordingWatchSnapshotSender: WatchSnapshotSending {
    private var activationHandler: (@MainActor () -> Void)?
    private(set) var activationCount = 0
    private(set) var snapshots: [WatchDashboardSnapshot] = []
    private(set) var publishedForces: [Bool] = []

    func activate(onActivated: @escaping @MainActor () -> Void) {
        activationCount += 1
        activationHandler = onActivated
    }

    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool {
        snapshots.append(snapshot)
        publishedForces.append(force)
        return true
    }

    func completeActivation() {
        activationHandler?()
    }
}
