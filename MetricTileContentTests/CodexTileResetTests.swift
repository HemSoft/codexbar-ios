import Foundation
import XCTest
@testable import CodexBarIOS

final class CodexTileResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_456_000)
    private let formatter = UserFacingDateTimeFormatter(
        timeZone: TimeZone(identifier: "America/New_York")!, locale: Locale(identifier: "en_US")
    )

    func testNamedWindowsKeepIndependentProviderDeadlines() throws {
        let payload = #"""
        {"additional_rate_limits":[{"limit_name":"GPT-6.1-Sol","metered_feature":"synthetic-sol","rate_limit":{
        "primary_window":{"used_percent":12,"reset_at":1893463260,"limit_window_seconds":18000},
        "secondary_window":{"used_percent":34,"reset_at":1893715200,"limit_window_seconds":604800}}}]}
        """#
        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8), fetchedAt: now))
        XCTAssertEqual(result.bars.count, 2)
        XCTAssertEqual(result.bars.map(\.resetsAt), [now.addingTimeInterval(7_260), now.addingTimeInterval(259_200)])
        XCTAssertTrue(result.bars.allSatisfy { $0.label.contains("GPT-6.1-Sol") })
        let descriptions = try result.bars.map { try XCTUnwrap(description($0)) }
        guard descriptions.count == 2 else {
            return XCTFail("Expected both named-window reset descriptions")
        }
        XCTAssertTrue(descriptions[0].contains("Resets 2h 1m"))
        XCTAssertTrue(descriptions[1].contains("Resets 3d 0h"))
        XCTAssertNotEqual(descriptions[0], descriptions[1])
    }

    func testCountdownAdvancesWithoutChangingTheReportedDeadline() throws {
        let bar = makeBar(reset: now.addingTimeInterval(3_660))
        let before = try XCTUnwrap(description(bar))
        let after = try XCTUnwrap(description(bar, at: now.addingTimeInterval(120)))
        XCTAssertTrue(before.contains("Resets 1h 1m"))
        XCTAssertTrue(after.contains("Resets 59m"))
        XCTAssertEqual(bar.resetsAt, now.addingTimeInterval(3_660))
        XCTAssertTrue(before.contains("EST"))
        XCTAssertTrue(after.contains("EST"))
    }

    func testRefreshUsesNewDeadlineAndIndependentAccountValues() throws {
        let first = try XCTUnwrap(description(makeBar(reset: now.addingTimeInterval(3_600))))
        let second = try XCTUnwrap(description(makeBar(reset: now.addingTimeInterval(7_200))))
        XCTAssertTrue(first.contains("Resets 1h 0m"))
        XCTAssertTrue(second.contains("Resets 2h 0m"))
        XCTAssertNotEqual(first, second)
    }

    func testPassedDeadlineRequestsRefreshWithoutInventingAnotherReset() throws {
        for reset in [now, now.addingTimeInterval(-60)] {
            let text = try XCTUnwrap(description(makeBar(reset: reset)))
            XCTAssertTrue(text.hasPrefix("Reset time passed"))
            XCTAssertTrue(text.contains("Refresh usage"))
            XCTAssertFalse(text.contains("Resets now"))
        }
    }

    func testStaleDataIsIdentifiedAsLastReported() throws {
        let bar = makeBar(reset: now.addingTimeInterval(3_600))
        let text = try XCTUnwrap(CodexTileResetContent.description(
            for: bar, isCurrent: false, at: now, formatter: formatter
        ))
        XCTAssertTrue(text.hasPrefix("Last reported:"))
    }

    func testMissingTimestampDoesNotReuseAnUnverifiedDescription() {
        let bar = UsageBar(label: "Missing", used: 12, limit: 100, resetDescription: "Tomorrow")
        XCTAssertNil(description(bar))
    }

    private func makeBar(reset: Date) -> UsageBar {
        UsageBar(label: "Named limit", used: 12, limit: 100, resetsAt: reset, resetDisplayStyle: .relativeWithLocalTime)
    }

    private func description(_ bar: UsageBar, at date: Date? = nil) -> String? {
        CodexTileResetContent.description(for: bar, isCurrent: true, at: date ?? now, formatter: formatter)
    }
}
