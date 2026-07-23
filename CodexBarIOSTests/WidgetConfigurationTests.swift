import WidgetKit
import XCTest
@testable import CodexBarIOS

final class WidgetConfigurationTests: XCTestCase {
    func testEveryWidgetFocusMapsToItsProvider() {
        let mappings: [(CodexBarWidgetFocus, String?)] = [
            (.dashboardOrder, nil),
            (.codex, "codex"),
            (.copilot, "copilot"),
            (.claude, "claude"),
            (.cursor, "cursor"),
            (.moonshot, "moonshot"),
            (.openCodeZen, "openCodeZen"),
            (.openRouter, "openRouter"),
        ]

        for (focus, providerID) in mappings {
            XCTAssertEqual(focus.providerID, providerID)
        }
    }

    func testEveryRefreshPolicySelectsItsOverrideOrFallback() {
        let fallback = WidgetRefreshInterval.threeHours

        XCTAssertEqual(CodexBarWidgetRefreshPolicy.appDefault.interval(fallback: fallback), fallback)
        XCTAssertEqual(
            CodexBarWidgetRefreshPolicy.fifteenMinutes.interval(fallback: fallback),
            .fifteenMinutes
        )
        XCTAssertEqual(
            CodexBarWidgetRefreshPolicy.thirtyMinutes.interval(fallback: fallback),
            .thirtyMinutes
        )
        XCTAssertEqual(CodexBarWidgetRefreshPolicy.oneHour.interval(fallback: fallback), .oneHour)
        XCTAssertEqual(
            CodexBarWidgetRefreshPolicy.threeHours.interval(fallback: .fifteenMinutes),
            .threeHours
        )
    }

    func testSnapshotScopesProvidersByGroupAndFocus() {
        let snapshot = Self.fixtureSnapshot
        let work = CodexBarWidgetGroupChoice(id: "work", title: "Work")
        let ungrouped = CodexBarWidgetGroupChoice(
            id: CodexBarWidgetGroupChoice.ungroupedID,
            title: "Ungrouped"
        )

        XCTAssertEqual(
            snapshot.scopedProviders(group: work).map(\.accountID),
            ["codex.work", "claude.work"]
        )
        XCTAssertEqual(
            snapshot.scopedProviders(group: work, focus: .claude).map(\.accountID),
            ["claude.work"]
        )
        XCTAssertEqual(
            snapshot.scopedProviders(group: ungrouped).map(\.accountID),
            ["openrouter.personal"]
        )
        XCTAssertTrue(snapshot.scopedProviders(group: work, focus: .moonshot).isEmpty)
    }

    func testGroupChoicesHandleUngroupedNamesAndIdentifierFallbacks() async throws {
        let snapshot = Self.fixtureSnapshot
        let query = CodexBarWidgetGroupChoiceQuery(loadSnapshot: { snapshot })
        let choices = try await query.suggestedEntities()
        let titlesByID = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0.title) })

        XCTAssertEqual(titlesByID["work"], "Work")
        XCTAssertEqual(titlesByID["named-ungrouped"], "Ungrouped (group)")
        XCTAssertEqual(titlesByID[CodexBarWidgetGroupChoice.ungroupedID], "Ungrouped")
        XCTAssertEqual(choices.last?.id, CodexBarWidgetGroupChoice.ungroupedID)

        let matches = try await query.entities(matching: "wOr")
        XCTAssertEqual(matches.map(\.id), ["work"])

        let resolved = try await query.entities(for: ["work", "missing-group"])
        XCTAssertEqual(resolved.map(\.title), ["Work", "Saved Group"])
        XCTAssertEqual(resolved.map(\.id), ["work", "missing-group"])
    }

    func testTileQueryFiltersAndMatchesCaseInsensitivelyWithInjectedSnapshot() async throws {
        let snapshot = Self.fixtureSnapshot
        let query = CodexBarWidgetTileChoiceQuery(
            loadSnapshot: { snapshot },
            group: CodexBarWidgetGroupChoice(id: "work", title: "Work"),
            focus: .codex
        )

        let choices = try await query.suggestedEntities()
        XCTAssertFalse(choices.isEmpty)
        XCTAssertTrue(choices.allSatisfy { $0.id.contains("codex.work") })

        let matches = try await query.entities(matching: "5-HOUR")
        XCTAssertEqual(matches.map(\.id), ["bar.codex.work.five-hour"])

        let subtitleMatches = try await query.entities(matching: "81% USED")
        XCTAssertEqual(subtitleMatches.map(\.id), ["bar.codex.work.five-hour"])

        let resolved = try await query.entities(for: [
            "bar.codex.work.five-hour",
            "missing-tile",
        ])
        XCTAssertEqual(resolved[0].title, "ChatGPT / Codex - 5-hour usage")
        XCTAssertEqual(resolved[1].id, "missing-tile")
        XCTAssertEqual(resolved[1].title, "Saved Tile")
    }

    func testProviderTilesSelectRepresentativeBarAndBuildEveryTileKind() throws {
        let codex = try XCTUnwrap(
            Self.fixtureSnapshot.results.first { $0.accountID == "codex.work" }
        )
        let summary = codex.summaryTile

        XCTAssertEqual(summary.id, "provider.codex.work")
        XCTAssertEqual(summary.bar?.id, "codex.work.weekly")
        XCTAssertEqual(summary.severity, .warning)

        let barTile = codex.barTile(try XCTUnwrap(codex.bars.first))
        XCTAssertEqual(barTile.id, "bar.codex.work.five-hour")
        XCTAssertEqual(barTile.accountID, "codex.work")
        XCTAssertEqual(barTile.bar?.usageText, "81%")

        let monetaryMetric = try XCTUnwrap(codex.monetaryMetrics?.first)
        let monetaryTile = codex.monetaryTile(monetaryMetric)
        XCTAssertEqual(monetaryTile.id, "money.codex.work.\(monetaryMetric.id)")
        XCTAssertEqual(monetaryTile.monetaryMetric, monetaryMetric)

        let monetaryOnly = try XCTUnwrap(
            Self.fixtureSnapshot.results.first { $0.accountID == "moonshot.team" }
        )
        XCTAssertEqual(monetaryOnly.summaryTile.title, "Balance")
        XCTAssertEqual(monetaryOnly.summaryTile.monetaryMetric, monetaryOnly.monetaryMetrics?.first)
    }

    func testUnavailableTilesDisplayModesAndAccountDeepLinks() throws {
        let unavailable = CodexBarWidgetTile.unavailable(
            choice: CodexBarWidgetTileChoice(
                id: "saved.removed",
                title: "Removed tile",
                subtitle: "Previously saved"
            )
        )
        XCTAssertEqual(unavailable.id, "unavailable.saved.removed")
        XCTAssertEqual(unavailable.providerID, "unavailable")
        XCTAssertEqual(unavailable.severity, .warning)

        XCTAssertEqual(
            CodexBarWidgetTileDisplayMode.mode(at: 1, in: [.fullBar, .balanceOnly]),
            .balanceOnly
        )
        XCTAssertEqual(
            CodexBarWidgetTileDisplayMode.mode(at: 4, in: [.fullBar]),
            .automatic
        )
        XCTAssertEqual(
            CodexBarWidgetTileDisplayMode(builderDisplayMode: .urgentStatus),
            .urgentStatus
        )

        let codex = try XCTUnwrap(
            Self.fixtureSnapshot.results.first { $0.accountID == "codex.work" }
        )
        let deepLink = try XCTUnwrap(codex.summaryTile.deepLinkURL)
        XCTAssertEqual(CodexBarDeepLink.providerAccountID(from: deepLink), "codex.work")
        XCTAssertNil(unavailable.deepLinkURL)
    }

    func testTimelineLoaderUsesInjectedClockSnapshotsAndRefreshInterval() {
        let now = Date(timeIntervalSince1970: 1_234_567)
        let liveSnapshot = Self.fixtureSnapshot
        let previewSnapshot = CodexBarWidgetSnapshot(
            generatedAt: now.addingTimeInterval(-1),
            results: []
        )
        let loader = CodexBarWidgetTimelineLoader(
            now: { now },
            loadSnapshot: { isPreview in
                isPreview ? previewSnapshot : liveSnapshot
            },
            loadRefreshInterval: { .threeHours }
        )
        var configuration = CodexBarWidgetConfigurationIntent()
        configuration.refreshPolicy = .thirtyMinutes

        let preview = loader.snapshot(configuration: configuration, isPreview: true)
        let live = loader.snapshot(configuration: configuration, isPreview: false)
        XCTAssertEqual(preview.date, now)
        XCTAssertEqual(preview.snapshot, previewSnapshot)
        XCTAssertTrue(preview.isPreview)
        XCTAssertEqual(live.snapshot, liveSnapshot)
        XCTAssertFalse(live.isPreview)

        let placeholder = loader.placeholder(configuration: configuration)
        XCTAssertEqual(placeholder.snapshot, .preview)
        XCTAssertTrue(placeholder.isPreview)

        let plan = loader.timelinePlan(configuration: configuration)
        let timeline = plan.timeline
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries.first?.date, now)
        XCTAssertEqual(timeline.entries.first?.snapshot, liveSnapshot)
        XCTAssertEqual(plan.nextRefreshDate, now.addingTimeInterval(30 * 60))

        configuration.refreshPolicy = .appDefault
        let fallbackPlan = loader.timelinePlan(configuration: configuration)
        XCTAssertEqual(fallbackPlan.nextRefreshDate, now.addingTimeInterval(3 * 60 * 60))
    }

    private static let fixtureSnapshot = CodexBarWidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_000_000),
        results: [
            CodexBarWidgetProviderSnapshot(
                accountID: "codex.work",
                providerID: "codex",
                title: "ChatGPT / Codex",
                subtitle: "Work account",
                groupID: "work",
                groupName: "Work",
                bars: [
                    CodexBarWidgetUsageBarSnapshot(
                        id: "codex.work.five-hour",
                        label: "5-hour usage",
                        fractionUsed: 0.81,
                        usageText: "81%",
                        resetDescription: "Soon",
                        severity: .warning
                    ),
                    CodexBarWidgetUsageBarSnapshot(
                        id: "codex.work.weekly",
                        label: "Weekly usage",
                        fractionUsed: 0.55,
                        usageText: "55%",
                        resetDescription: "Friday",
                        severity: .normal,
                        projectedFraction: 0.96,
                        projectedSeverity: .critical
                    ),
                ],
                creditsRemaining: nil,
                monetaryMetrics: [
                    CodexBarWidgetMonetaryMetricSnapshot(
                        kind: "spend",
                        label: "Spend",
                        minorUnits: 1234,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "This month"
                    ),
                ],
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .warning
            ),
            CodexBarWidgetProviderSnapshot(
                accountID: "claude.work",
                providerID: "claude",
                title: "Claude",
                subtitle: "Work account",
                groupID: "work",
                groupName: "Work",
                bars: [],
                creditsRemaining: 10,
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .normal
            ),
            CodexBarWidgetProviderSnapshot(
                accountID: "moonshot.team",
                providerID: "moonshot",
                title: "Moonshot",
                subtitle: "Team",
                groupID: "named-ungrouped",
                groupName: "ungrouped",
                bars: [],
                creditsRemaining: nil,
                monetaryMetrics: [
                    CodexBarWidgetMonetaryMetricSnapshot(
                        kind: "balance",
                        label: "Balance",
                        minorUnits: 2500,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Available"
                    ),
                    CodexBarWidgetMonetaryMetricSnapshot(
                        kind: "spend",
                        label: "Spend",
                        minorUnits: 500,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "This month"
                    ),
                ],
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .normal
            ),
            CodexBarWidgetProviderSnapshot(
                accountID: "openrouter.personal",
                providerID: "openRouter",
                title: "OpenRouter",
                subtitle: "Personal",
                bars: [],
                creditsRemaining: 12.34,
                fetchedAt: Date(timeIntervalSince1970: 999_900),
                severity: .normal
            ),
        ]
    )
}
