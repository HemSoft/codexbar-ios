import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeBrowserPolicyTests: XCTestCase {
    func testDeviceApprovalRequiresTheExactConsoleOriginAndPath() {
        XCTAssertEqual(
            OpenCodeDeviceAuthService.verificationURL("/console/device?user_code=SYNTHETIC")?.host,
            "opencode.ai"
        )
        for address in [
            "http://opencode.ai/console/device", "https://opencode.ai.attacker.test/console/device",
            "https://attacker.test/console/device", "https://opencode.ai:8443/console/device",
            "https://user:password@opencode.ai/console/device", "javascript:alert(1)",
            "https://opencode.ai/console/device#fragment", "https://opencode.ai/console/other",
        ] {
            XCTAssertNil(OpenCodeDeviceAuthService.verificationURL(address))
        }
    }

    func testOnlyProviderWorkspaceIdentitiesAreAccepted() {
        for value in ["wrk_abc", "org_abc"] { XCTAssertTrue(OpenCodeConsoleCredential.validWorkspace(value)) }
        for value in ["not-a-workspace", "wrk_abc/other", "org_", "org_a\nheader"] {
            XCTAssertFalse(OpenCodeConsoleCredential.validWorkspace(value))
        }
    }

    func testTokenValidationAndCredentialRoundTrip() throws {
        let token = OpenCodeDeviceToken(
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh", tokenType: "Bearer",
            expiresIn: 3600, orgID: "wrk_one"
        )
        let credential = try token.credential(workspaceID: "wrk_one", userID: "user_one")
        XCTAssertEqual(OpenCodeConsoleCredential.parse(try credential.encoded()), credential)
        XCTAssertThrowsError(try token.credential(workspaceID: "wrk_two", userID: "user_one"))
        XCTAssertNil(OpenCodeConsoleCredential.parse("{\"auth\":\"old-cookie\"}"))
    }

    func testReconnectCannotSwitchTheExistingWorkspace() {
        XCTAssertTrue(OpenCodeSessionValidator.canReconnect(workspaceID: "wrk_one", configuredWorkspace: ""))
        XCTAssertTrue(OpenCodeSessionValidator.canReconnect(workspaceID: "org_one", configuredWorkspace: "org_one"))
        XCTAssertFalse(OpenCodeSessionValidator.canReconnect(workspaceID: "wrk_two", configuredWorkspace: "wrk_one"))
        XCTAssertTrue(OpenCodeSessionValidator.canReconnect(
            workspaceID: "wrk_one", configuredWorkspace: "https://opencode.ai/workspace/wrk_one/go"
        ))
    }

    func testVerificationRequiresActualProviderData() {
        let failed = ProviderUsageResult(
            accountID: "test", providerID: .openCodeZen, title: "Test", subtitle: "Rejected", bars: [],
            failureMessage: "Rejected", fetchedAt: Date()
        )
        XCTAssertFalse(OpenCodeSessionValidator.hasVerifiedUsage(failed))
        let empty = ProviderUsageResult(
            accountID: "test", providerID: .openCodeZen, title: "Test", subtitle: "Empty", bars: [], fetchedAt: Date()
        )
        XCTAssertFalse(OpenCodeSessionValidator.hasVerifiedUsage(empty))
        let balance = ProviderUsageResult(
            accountID: "test", providerID: .openCodeZen, title: "Test", subtitle: "Balance", bars: [], creditsRemaining: 0, fetchedAt: Date()
        )
        XCTAssertTrue(OpenCodeSessionValidator.hasVerifiedUsage(balance))
        let usage = ProviderUsageResult(
            accountID: "test", providerID: .openCodeZen, title: "Test", subtitle: "Usage",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly", used: 10, limit: 100)], fetchedAt: Date()
        )
        XCTAssertTrue(OpenCodeSessionValidator.hasVerifiedUsage(usage))
    }
}
