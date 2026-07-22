import XCTest
@testable import CodexBarIOS

final class UsageHistoryTests: XCTestCase {
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
    func testUsageHistoryStoreSurfacesEncodingFailures() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let invalidResult = makeHistoryResult(
            accountID: "codex.invalid-history",
            fetchedAt: fetchedAt,
            used: .nan
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [invalidResult], now: fetchedAt)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save usage history:") == true)
        XCTAssertNil(defaults.data(forKey: "usageHistorySnapshots"))

        let validResult = makeHistoryResult(
            accountID: "codex.valid-history",
            fetchedAt: fetchedAt,
            used: 42
        )
        store.record(results: [validResult], now: fetchedAt)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.snapshots.map(\.accountID), ["codex.valid-history"])
        XCTAssertNotNil(defaults.data(forKey: "usageHistorySnapshots"))
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
    func testUsageHistoryStoreSkipsStaleBarsWithoutFreshValues() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let barsFetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Cached Claude usage",
            bars: [UsageBar(label: "Weekly usage limit", used: 40, limit: 100)],
            barsFetchedAt: barsFetchedAt,
            fetchedAt: barsFetchedAt.addingTimeInterval(60)
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: result.fetchedAt)

        XCTAssertTrue(store.snapshots.isEmpty)

        let resultWithFreshMoney = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            barsFetchedAt: barsFetchedAt,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3750,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: result.fetchedAt.addingTimeInterval(60)
        )
        store.record(results: [resultWithFreshMoney], now: resultWithFreshMoney.fetchedAt)

        let series = store.historySeries(for: resultWithFreshMoney)
        XCTAssertTrue(series.isBalance)
        XCTAssertEqual(series.points.map(\.value), [37.5])
        XCTAssertEqual(
            store.historySeriesOptions(for: resultWithFreshMoney).map(\.label),
            ["Remaining spend headroom"]
        )
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
    func testProviderUsageCardHistoryVisibilityDoesNotDiscardStoredHistory() {
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

        let hiddenCard = ProviderUsageCard(
            result: failedResult,
            statusText: failedResult.subtitle,
            history: history,
            isHistoryEnabled: false
        )
        let visibleCard = ProviderUsageCard(
            result: failedResult,
            statusText: failedResult.subtitle,
            history: history,
            isHistoryEnabled: true
        )

        XCTAssertFalse(hiddenCard.showsHistory)
        XCTAssertTrue(visibleCard.showsHistory)
        XCTAssertFalse(history.points.isEmpty)
        XCTAssertTrue(history.isBalance)
        XCTAssertEqual(history.latestValueDescription, "$19.25")
    }

    func testProviderUsageCardOffersRetryForCachedRefreshFailure() {
        let result = makeHistoryResult(
            accountID: "codex.cached",
            providerID: .codex,
            fetchedAt: Date(),
            used: 25
        )
        let failedCard = ProviderUsageCard(
            result: result,
            statusText: "Refresh failed - Session expired",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            refreshErrorMessage: "Session expired"
        )
        let refreshingCard = ProviderUsageCard(
            result: result,
            statusText: "Refreshing",
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            isRefreshing: true,
            refreshErrorMessage: "Session expired"
        )

        XCTAssertTrue(failedCard.showsRetryAction)
        XCTAssertFalse(refreshingCard.showsRetryAction)
    }

    @MainActor
    func testProviderUsageCardPresentsBankedResetsWithoutChangingSeverity() {
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "ChatGPT / Codex",
            subtitle: "Live ChatGPT usage",
            bars: [UsageBar(label: "5 hour usage limit", used: 25, limit: 100)],
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 1,
                credits: [CodexBankedRateLimitReset(
                    id: "credit-1",
                    title: "Full reset (Weekly + 5 hr)",
                    expiresAt: Date(timeIntervalSince1970: 1_893_456_000)
                )],
                canConsume: true
            ),
            fetchedAt: fetchedAt
        )
        var redemptionCount = 0
        let card = ProviderUsageCard(
            result: result,
            statusText: result.subtitle,
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false),
            onUseCodexReset: { _ in
                redemptionCount += 1
                return CodexBankedResetRedemptionFeedback(message: "Reset used.", isSuccess: true)
            }
        )

        XCTAssertEqual(card.bankedResetAvailabilityText, "1 reset available")
        XCTAssertTrue(card.showsCodexResetAction)
        XCTAssertTrue(card.resetConfirmationMessage.contains("Full reset (Weekly + 5 hr)"))
        XCTAssertEqual(result.highestSeverity, .normal)
        card.cancelCodexReset()
        XCTAssertEqual(redemptionCount, 0)

        let readOnlyResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: .codex,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            codexBankedRateLimitResets: CodexBankedRateLimitResets(
                availableCount: 3,
                canConsume: false
            ),
            fetchedAt: fetchedAt
        )
        let readOnlyCard = ProviderUsageCard(
            result: readOnlyResult,
            statusText: readOnlyResult.subtitle,
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
        )
        XCTAssertEqual(readOnlyCard.bankedResetAvailabilityText, "3 resets available")
        XCTAssertFalse(readOnlyCard.showsCodexResetAction)

        let zeroResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: .codex,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            codexBankedRateLimitResets: CodexBankedRateLimitResets(availableCount: 0),
            fetchedAt: fetchedAt
        )
        let zeroCard = ProviderUsageCard(
            result: zeroResult,
            statusText: zeroResult.subtitle,
            history: UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
        )
        XCTAssertNil(zeroCard.bankedResets)
    }

    @MainActor
    func testProviderUsageCardKeepsResetFeedbackAfterFinalCreditDisappears() {
        let feedback = CodexBankedResetRedemptionFeedback(
            message: "Reset used. Current usage limits are refreshed.",
            isSuccess: true
        )

        XCTAssertEqual(
            ProviderUsageCard.resetPresentationFeedback(feedback, availableResets: nil),
            feedback
        )
    }

}
