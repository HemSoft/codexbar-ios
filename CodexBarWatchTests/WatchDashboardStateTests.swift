import XCTest
@testable import CodexBarWatch

final class WatchDashboardStateTests: XCTestCase {
    func testProductionFoundationStartsWithoutDemoUsage() {
        XCTAssertTrue(WatchDashboardState.empty.samples.isEmpty)
        XCTAssertEqual(WatchDashboardState.empty.statusText, "Set up providers on iPhone")
    }

    func testSamplesAreOrderedByHighestClampedUsage() {
        let state = WatchDashboardState(
            title: "CodexBar",
            statusText: "Fixture",
            samples: [
                WatchUsageSample(
                    id: "low",
                    providerName: "Copilot",
                    accountLabel: "Work",
                    usedFraction: -0.25
                ),
                WatchUsageSample(
                    id: "high",
                    providerName: "Codex",
                    accountLabel: "Primary",
                    usedFraction: 1.4
                ),
                WatchUsageSample(
                    id: "middle",
                    providerName: "Claude",
                    accountLabel: "Personal",
                    usedFraction: 0.6
                ),
            ]
        )

        XCTAssertEqual(state.samplesByHighestUsage.map(\.id), ["high", "middle", "low"])
        XCTAssertEqual(state.samplesByHighestUsage.map(\.clampedUsedFraction), [1, 0.6, 0])
    }

    func testAccessibilitySummaryUsesDeterministicRoundedPercentage() {
        let sample = WatchUsageSample(
            id: "codex",
            providerName: "Codex",
            accountLabel: "Primary",
            usedFraction: 0.724
        )

        XCTAssertEqual(sample.percentageText, "72%")
        XCTAssertEqual(sample.accessibilitySummary, "Codex, Primary, 72% used")
    }
}
