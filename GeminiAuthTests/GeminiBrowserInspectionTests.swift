import Foundation
import XCTest
@testable import CodexBarIOS

final class GeminiBrowserInspectionTests: XCTestCase {
    func testSignedOutLoadingCanceledAndUnsafePagesDoNotReadCookies() {
        var state = GeminiBrowserInspectionState()
        for context in [
            context(active: false),
            context(loading: true),
            context(url: "https://accounts.google.com/signin/challenge"),
            context(url: "https://google.com.evil.example/usage"),
            context(url: "http://gemini.google.com/usage"),
            context(url: "about:blank"),
        ] {
            XCTAssertNil(state.begin(in: context))
        }
        XCTAssertEqual(state.begin(in: context()), 0)
    }

    func testOneCookieReadAtATimeAndMissingPrimaryAllowsRetry() throws {
        var state = GeminiBrowserInspectionState()
        let revision = try XCTUnwrap(state.begin(in: context()))
        XCTAssertNil(state.begin(in: context()))
        XCTAssertEqual(state.complete(cookies: [], revision: revision, in: context()), .ignore)
        XCTAssertEqual(state.begin(in: context()), 0)
        XCTAssertEqual(state.complete(
            cookies: [try cookie("__Secure-1PSIDTS", value: "rotating-only")], revision: 0, in: context()
        ), .ignore)
        XCTAssertEqual(state.begin(in: context()), 0)
    }

    func testNavigationLoadingAndCancellationDiscardLateCookieReadsAndReleaseGate() throws {
        for changed in [
            context(revision: 1),
            context(loading: true),
            context(active: false),
            context(url: "https://accounts.google.com/signin"),
        ] {
            var state = GeminiBrowserInspectionState()
            let revision = try XCTUnwrap(state.begin(in: context()))
            XCTAssertEqual(state.complete(cookies: try validCookies(), revision: revision, in: changed), .ignore)
            XCTAssertEqual(state.begin(in: context(revision: 2)), 2)
        }
    }

    func testUsagePageReturnsOnlyPolicySelectedCredentialForValidation() throws {
        var state = GeminiBrowserInspectionState()
        let revision = try XCTUnwrap(state.begin(in: context()))
        let cookies = try validCookies() + [cookie("SID", value: "not-exported")]
        let expected = try XCTUnwrap(GeminiBrowserSessionPolicy.storedCredential(from: cookies))
        XCTAssertEqual(state.complete(cookies: cookies, revision: revision, in: context()), .credential(expected))
        XCTAssertFalse(expected.contains("not-exported"))
    }

    func testAccountLandingReturnsOncePerCredentialAndUsageCanStillComplete() throws {
        var state = GeminiBrowserInspectionState()
        let account = context(url: "https://myaccount.google.com/")
        let cookies = try validCookies()
        XCTAssertEqual(try inspect(&state, cookies: cookies, in: account), .openUsage)
        XCTAssertEqual(try inspect(&state, cookies: cookies, in: account), .explainRepeatedReturn)
        let fresh = try validCookies(primary: "fresh-synthetic-session")
        XCTAssertEqual(try inspect(&state, cookies: fresh, in: account), .openUsage)
        XCTAssertEqual(try inspect(&state, cookies: fresh, in: account), .explainRepeatedReturn)
        let expected = try XCTUnwrap(GeminiBrowserSessionPolicy.storedCredential(from: fresh))
        XCTAssertEqual(try inspect(&state, cookies: fresh, in: context()), .credential(expected))
    }

    func testStaleReadDoesNotConsumeTheAutomaticReturnAttempt() throws {
        var state = GeminiBrowserInspectionState()
        let account = context(url: "https://myaccount.google.com/")
        let revision = try XCTUnwrap(state.begin(in: account))
        XCTAssertEqual(state.complete(
            cookies: try validCookies(), revision: revision,
            in: context(url: "https://myaccount.google.com/", revision: 1)
        ), .ignore)
        XCTAssertEqual(try inspect(&state, cookies: validCookies(), in: account), .openUsage)
    }

    func testAmbiguousCookieReadFailsWithoutAUsableCredentialAndReleasesGate() throws {
        var state = GeminiBrowserInspectionState()
        let cookies = try validCookies() + [cookie("__Secure-1PSID", value: "conflicting-session")]
        XCTAssertEqual(try inspect(&state, cookies: cookies, in: context()), .ambiguousSession)
        XCTAssertEqual(state.begin(in: context()), 0)
    }

    func testRejectedCookiesDoNotTriggerAccountReturnOrExposeCredentials() throws {
        var state = GeminiBrowserInspectionState()
        let rejected = try [
            cookie("__Secure-1PSID", value: "host-only", domain: "google.com"),
            cookie("__Secure-1PSID", value: "wrong-path", path: "/accounts"),
            cookie("__Secure-1PSID", value: "insecure", secure: false),
            cookie("__Secure-1PSID", value: "expired", expires: Date(timeIntervalSince1970: 1)),
        ]
        let account = context(url: "https://myaccount.google.com/")
        XCTAssertEqual(try inspect(&state, cookies: rejected, in: account), .ignore)
        XCTAssertEqual(try inspect(&state, cookies: validCookies(), in: account), .openUsage)
    }

    func testNewAttemptDoesNotInheritAFormerAttemptsReturnHistory() throws {
        let account = context(url: "https://myaccount.google.com/")
        var first = GeminiBrowserInspectionState()
        XCTAssertEqual(try inspect(&first, cookies: validCookies(), in: account), .openUsage)
        XCTAssertNil(first.begin(in: context(active: false)))
        var second = GeminiBrowserInspectionState()
        XCTAssertEqual(try inspect(&second, cookies: validCookies(), in: account), .openUsage)
    }

    private func inspect(
        _ state: inout GeminiBrowserInspectionState, cookies: [HTTPCookie], in context: GeminiBrowserInspectionContext
    ) throws -> GeminiBrowserInspectionState.Action {
        let revision = try XCTUnwrap(state.begin(in: context))
        return state.complete(cookies: cookies, revision: revision, in: context)
    }

    private func context(
        active: Bool = true, loading: Bool = false,
        url: String = "https://gemini.google.com/usage?pli=1", revision: Int = 0
    ) -> GeminiBrowserInspectionContext {
        GeminiBrowserInspectionContext(isActive: active, isLoading: loading, url: URL(string: url), navigationRevision: revision)
    }

    private func validCookies(primary: String = "synthetic-session") throws -> [HTTPCookie] {
        try [cookie("__Secure-1PSID", value: primary), cookie("__Secure-1PSIDTS", value: "synthetic-rotation")]
    }

    private func cookie(
        _ name: String, value: String, domain: String = ".google.com", path: String = "/",
        secure: Bool = true, expires: Date? = nil
    ) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }
}
