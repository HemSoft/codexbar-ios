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
        let confirmed = inventory.bound(toAccessToken: "fixture-token")
        let grant = try XCTUnwrap(confirmed.redeemableGrant(at: now))
        let binding = try XCTUnwrap(confirmed.credentialBinding)
        XCTAssertTrue(confirmed.matchesConfirmation(grant: grant, binding: binding, at: now))
        XCTAssertFalse(inventory.matchesConfirmation(grant: grant, binding: binding, at: now))
        XCTAssertFalse(confirmed.bound(toAccessToken: "replacement-token").matchesConfirmation(grant: grant, binding: binding, at: now))
        XCTAssertFalse(confirmed.matchesConfirmation(grant: grant, binding: binding, at: now.addingTimeInterval(8 * 86_400)))
        let changed = try XCTUnwrap(parse(replacing: "\"resets_left\":2", with: "\"resets_left\":1")).bound(toAccessToken: "fixture-token")
        XCTAssertFalse(changed.matchesConfirmation(grant: grant, binding: binding, at: now))
    }

    func testUnsupportedAndMalformedInventoryNeverBecomeZeroBalance() {
        for payload in ["{}", "{\"cedar_ember\":null}", "{\"cedar_ember\":{\"eligible\":\"true\"}}",
                        "{\"cedar_ember\":{\"eligible\":true}}",
                        "{\"cedar_ember\":{\"eligible\":true,\"grants\":null}}",
        ] {
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
        let cooldown = try XCTUnwrap(cooling.cooldownUntil)
        XCTAssertEqual(cooling.redeemableGrant(at: cooldown)?.id, "fixture_grant")
        let future = try XCTUnwrap(parse(replacing: "2029-12-01T00:00:00Z", with: "2030-01-02T00:00:00Z"))
        XCTAssertEqual(future.availableCount(at: now), 0)
        XCTAssertEqual(future.availableCount(at: cooldown), 2)
        XCTAssertEqual(future.availableCount(at: now.addingTimeInterval(7 * 86_400)), 0)

    }

    func testConfirmedEmptyAndSeparateAccountsRemainIndependent() throws {
        let empty = try XCTUnwrap(ClaudeUsageResetInventoryParser.parse(Data("{\"cedar_ember\":{\"eligible\":true,\"grants\":[]}}".utf8)))
        let unavailable = try XCTUnwrap(ClaudeUsageResetInventoryParser.parse(Data("{\"cedar_ember\":{\"eligible\":false}}".utf8)))
        XCTAssertFalse(unavailable.isEligible)
        XCTAssertEqual(unavailable.availableCount(at: now), 0)
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
