import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeBrowserPolicyTests: XCTestCase {
    func testOnlyVerifiedOriginsCanNavigate() {
        for host in ["opencode.ai", "auth.opencode.ai", "github.com", "accounts.google.com"] {
            XCTAssertTrue(OpenCodeBrowserSessionPolicy.allowsNavigation(to: URL(string: "https://\(host)/login")))
        }
        for value in [
            "http://opencode.ai/auth", "https://opencode.ai.attacker.test/auth",
            "https://attacker.test/opencode.ai", "https://opencode.ai:8443/auth",
            "https://user:password@opencode.ai/auth", "javascript:alert(1)",
        ] {
            XCTAssertFalse(OpenCodeBrowserSessionPolicy.allowsNavigation(to: URL(string: value)))
        }
    }

    func testWorkspaceRequiresExactOriginAndValidIdentity() {
        XCTAssertEqual(OpenCodeBrowserSessionPolicy.workspaceID(from: URL(string: "https://opencode.ai/workspace/wrk_abc/go")), "wrk_abc")
        for value in [
            "https://auth.opencode.ai/workspace/wrk_abc", "http://opencode.ai/workspace/wrk_abc",
            "https://opencode.ai/workspace/not-a-workspace", "https://opencode.ai/workspace/wrk_abc%2Fbad",
            "https://opencode.ai/auth?workspace=wrk_abc", "https://opencode.ai/workspace/",
        ] {
            XCTAssertNil(OpenCodeBrowserSessionPolicy.workspaceID(from: URL(string: value)))
        }
    }

    func testCookieOriginExpiryAndAmbiguity() throws {
        let now = Date()
        let valid = cookie("one", domain: "opencode.ai", expires: now.addingTimeInterval(60))
        XCTAssertEqual(try OpenCodeBrowserSessionPolicy.credential(from: [valid], now: now), "one")
        XCTAssertEqual(try OpenCodeBrowserSessionPolicy.credential(from: [valid, valid], now: now), "one")
        let wrongDomain = cookie("other", domain: "auth.opencode.ai", expires: now.addingTimeInterval(60))
        XCTAssertNil(try OpenCodeBrowserSessionPolicy.credential(from: [wrongDomain], now: now))
        let expired = cookie("expired", domain: "opencode.ai", expires: now.addingTimeInterval(-1))
        XCTAssertNil(try OpenCodeBrowserSessionPolicy.credential(from: [expired], now: now))
        let conflict = cookie("two", domain: ".opencode.ai", expires: now.addingTimeInterval(60))
        XCTAssertThrowsError(try OpenCodeBrowserSessionPolicy.credential(from: [valid, conflict], now: now))
        let unsafe = cookie("value; injected=true", domain: "opencode.ai", expires: now.addingTimeInterval(60))
        XCTAssertThrowsError(try OpenCodeBrowserSessionPolicy.credential(from: [unsafe], now: now))
    }

    func testReconnectCannotSwitchTheExistingWorkspace() {
        XCTAssertTrue(OpenCodeSessionValidator.canReconnect(workspaceID: "wrk_one", configuredWorkspace: ""))
        XCTAssertTrue(OpenCodeSessionValidator.canReconnect(workspaceID: "wrk_one", configuredWorkspace: "wrk_one"))
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

    private func cookie(_ value: String, domain: String, expires: Date) -> HTTPCookie {
        HTTPCookie(properties: [.name: "auth", .value: value, .domain: domain, .path: "/", .expires: expires])!
    }
}
