import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeConsoleTests: XCTestCase {
    func testMicrocentBalanceIsConvertedWithoutAssumingCents() {
        XCTAssertEqual(OpenCodeConsoleUsageProvider.balance(Data(#"{"balanceMicroCents":"2434000000"}"#.utf8)), 24.34)
        XCTAssertEqual(OpenCodeConsoleUsageProvider.balance(Data(#"{"balanceMicroCents":"-100000000"}"#.utf8)), -1)
        XCTAssertNil(OpenCodeConsoleUsageProvider.balance(Data(#"{"balanceMicroCents":"NaN"}"#.utf8)))
        XCTAssertNil(OpenCodeConsoleUsageProvider.balance(Data(#"{"balanceMicroCents":true}"#.utf8)))
    }

    func testConsoleWindowsKeepHistoryIdentitiesAndServerResetTimes() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!
        guard case .subscribed(let windows) = OpenCodeConsoleUsageProvider.goUsage(fixture(), userID: "user_one", now: now) else {
            return XCTFail("Expected verified Go windows")
        }
        XCTAssertEqual(windows.map(\.stableKey), ["go.rolling-5-hour", "go.weekly", "go.monthly"])
        XCTAssertEqual(windows.map(\.usagePercent), [25, 50, 75])
        XCTAssertEqual(windows.first?.resetInSeconds, 3600)
        XCTAssertTrue(windows.allSatisfy(\.hasExactResetBoundary))
    }

    func testConsoleDoesNotDisplayAnotherMembersGoAllowance() {
        guard case .otherWorkspaceMember = OpenCodeConsoleUsageProvider.goUsage(fixture(), userID: "user_two", now: Date()) else {
            return XCTFail("Another member's windows must not be displayed")
        }
    }

    func testInactiveRollingWindowHasNoInventedReset() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        var access = try XCTUnwrap(object["access"] as? [String: Any])
        var meters = try XCTUnwrap(access["meters"] as? [String: Any])
        meters["fiveHour"] = ["startsAt": NSNull(), "resetsAt": NSNull(), "usedMicroCents": "0", "limitMicroCents": "100"]
        access["meters"] = meters
        object["access"] = access
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .subscribed(let windows) = OpenCodeConsoleUsageProvider.goUsage(data, userID: "user_one", now: Date()) else {
            return XCTFail("Expected inactive rolling window")
        }
        XCTAssertEqual(windows.first?.usagePercent, 0)
        XCTAssertEqual(windows.first?.hasReset, false)
    }

    func testMalformedWindowsFailClosedAndNullMeansNotSubscribed() {
        guard case .notSubscribed = OpenCodeConsoleUsageProvider.goUsage(Data("null".utf8), userID: "user_one", now: Date()) else {
            return XCTFail("Null subscription should remain unavailable")
        }
        guard case .failure = OpenCodeConsoleUsageProvider.goUsage(
            Data(#"{"subscriberUserId":"user_one","access":{"meters":{}}}"#.utf8), userID: "user_one", now: Date()
        ) else { return XCTFail("Incomplete windows must fail closed") }
    }

    private func fixture() -> Data {
        Data(#"""
        {"subscriberUserId":"user_one","access":{"startsAt":"2026-09-01T00:00:00Z","endsAt":"2026-10-01T00:00:00Z","meters":{
          "fiveHour":{"usedMicroCents":"25","limitMicroCents":"100","startsAt":"2026-09-22T08:00:00Z","resetsAt":"2026-09-22T13:00:00Z"},
          "week":{"usedMicroCents":"50","limitMicroCents":"100","startsAt":"2026-09-20T00:00:00Z","resetsAt":"2026-09-27T00:00:00Z"},
          "month":{"usedMicroCents":"75","limitMicroCents":"100"}
        }}}
        """#.utf8)
    }
}
