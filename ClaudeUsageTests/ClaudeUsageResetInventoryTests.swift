import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeUsageResetInventoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_456_000)

    func testCurrentSelectedGrantControlsRedemptionAndExpiry() throws {
        let inventory = try XCTUnwrap(parse())
        XCTAssertEqual(inventory.availableCount(at: now), 2)
        XCTAssertEqual(inventory.redeemableGrant(at: now)?.id, "fixture_grant")
        XCTAssertEqual(inventory.redeemableGrant(at: now)?.clears, ["five_hour", "seven_day"])
        XCTAssertEqual(inventory.availableCount(at: now.addingTimeInterval(8 * 86_400)), 0)
        XCTAssertNil(inventory.redeemableGrant(at: now.addingTimeInterval(8 * 86_400)))
    }

    func testUnsupportedAndMalformedInventoryNeverBecomeZeroBalance() {
        for payload in ["{}", "{\"cedar_ember\":null}", "{\"cedar_ember\":{\"eligible\":\"true\"}}"] {
            XCTAssertNil(ClaudeUsageResetInventoryParser.parse(Data(payload.utf8)))
        }
        for replacement in ["-1", "1.5", "true", "1001"] {
            XCTAssertNil(parse(replacing: "\"resets_left\":2", with: "\"resets_left\":\(replacement)"))
        }
        XCTAssertNil(parse(replacing: "2030-01-08T00:00:00Z", with: "not-a-date"))
        XCTAssertNil(parse(replacing: "fixture_grant", with: "invalid/grant"))
    }

    func testEligibilityCooldownPauseAndProviderSelectionFailClosed() throws {
        XCTAssertNil(try XCTUnwrap(parse(replacing: "\"eligible\":true", with: "\"eligible\":false")).redeemableGrant(at: now))
        XCTAssertNil(try XCTUnwrap(parse(replacing: "\"paused\":false", with: "\"paused\":true")).redeemableGrant(at: now))
        XCTAssertNil(try XCTUnwrap(parse(replacing: "\"usable_now\":true", with: "\"usable_now\":false")).redeemableGrant(at: now))
        XCTAssertNil(try XCTUnwrap(parse(replacing: "\"next_grant_id\":\"fixture_grant\"", with: "\"next_grant_id\":\"different\"")).redeemableGrant(at: now))
        let cooling = try XCTUnwrap(parse(replacing: "\"eligible\":true", with: "\"eligible\":true,\"cooldown_until\":\"2030-01-02T00:00:00Z\""))
        XCTAssertEqual(cooling.availableCount(at: now), 2)
        XCTAssertNil(cooling.redeemableGrant(at: now))
    }

    func testConfirmedEmptyAndSeparateAccountsRemainIndependent() throws {
        let empty = try XCTUnwrap(ClaudeUsageResetInventoryParser.parse(Data("{\"cedar_ember\":{\"eligible\":true,\"grants\":[]}}".utf8)))
        let available = try XCTUnwrap(parse())
        XCTAssertEqual(empty.availableCount(at: now), 0)
        XCTAssertNil(empty.redeemableGrant(at: now))
        XCTAssertEqual(available.availableCount(at: now), 2)
    }

    private func parse(replacing old: String = "unused", with new: String = "unused") -> ClaudeUsageResetInventory? {
        let fixture = """
        {"cedar_ember":{"eligible":true,"next_grant_id":"fixture_grant","grants":[{
          "id":"fixture_grant","resets_left":2,"starts_at":"2029-12-01T00:00:00Z",
          "ends_at":"2030-01-08T00:00:00Z","clears":["five_hour","seven_day"],
          "paused":false,"usable_now":true,"use_requires_limit":false
        }]}}
        """
        return ClaudeUsageResetInventoryParser.parse(Data(fixture.replacingOccurrences(of: old, with: new).utf8))
    }
}
