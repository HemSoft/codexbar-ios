import XCTest

@MainActor
final class OpenCodeSignInUITests: XCTestCase {
    func testDisconnectedAccountOffersGuidedSignIn() throws {
        let app = launchAccountSettings()
        let signIn = app.buttons["Sign in with OpenCode"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Workspace ID"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        capture("OpenCode disconnected account", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Use browser sign-in"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Use private sign-in"].exists)
        capture("OpenCode browser choices", app: app)
        app.buttons["Use browser sign-in"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic saved-session browser approval."].waitForExistence(timeout: 10))
        capture("Saved-session browser approval", app: app)
        app.buttons["Back to browser choices"].tap()
        XCTAssertTrue(app.buttons["Use private sign-in"].waitForExistence(timeout: 5))
        app.buttons["Use private sign-in"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic private browser approval."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Choose Sample workspace"].exists)
        capture("Private browser retry", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        chooseWorkspace(in: app)
        app.buttons["Connect this workspace"].tap()
        XCTAssertTrue(app.staticTexts["Checking OpenCode approval"].waitForExistence(timeout: 5))
        capture("Approval check can be canceled", app: app)
        app.buttons["Approval not available"].tap()
        XCTAssertTrue(app.buttons["Use browser sign-in"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "OpenCode approval is not available. Try signing in again. Your saved account was not changed."
        ].exists)
        capture("Unapproved browser return offers retry", app: app)
        app.buttons["Use browser sign-in"].tap()
        app.buttons["Choose Sample workspace"].tap()
        app.buttons["Connect this workspace"].tap()
        XCTAssertTrue(app.staticTexts["Checking OpenCode approval"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        connect(in: app)
        capture("OpenCode connected", app: app)
        connect(in: app, signInButton: "Reconnect OpenCode")
        capture("OpenCode reconnected", app: app)
        app.buttons["Remove Saved Credential"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        XCTAssertFalse(app.textFields["Workspace ID"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        capture("Removed auth retains guided sign-in", app: app)
        connect(in: app)
        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["More options for OpenCode Go + Zen 1"].waitForExistence(timeout: 10))
    }

    func testVerificationFailureKeepsAccountDisconnectedAndAllowsRetry() {
        let app = launchAccountSettings(failsVerification: true)
        chooseWorkspace(in: app, browserButton: "Use private sign-in")
        finishApproval(in: app)
        let message = app.staticTexts[
            "OpenCode usage could not be verified. Check your workspace and try again. Your saved account was not changed."
        ]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        XCTAssertTrue(app.buttons["Sign in with OpenCode"].isEnabled)
        capture("Verification failure with retry", app: app)
        chooseWorkspace(in: app)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
    }

    private func launchAccountSettings(failsVerification: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": "empty",
            "CODEXBAR_UI_TEST_OPENCODE_FAILURE": failsVerification ? "1" : "0",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        app.buttons["dashboard-add-account"].tap()
        let provider = app.buttons["OpenCode Go + Zen"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        return app
    }

    private func chooseWorkspace(
        in app: XCUIApplication, browserButton: String = "Use browser sign-in", signInButton: String = "Sign in with OpenCode"
    ) {
        app.buttons[signInButton].tap()
        XCTAssertTrue(app.buttons[browserButton].waitForExistence(timeout: 5))
        app.buttons[browserButton].tap()
        XCTAssertTrue(app.buttons["Choose Sample workspace"].waitForExistence(timeout: 10))
        app.buttons["Choose Sample workspace"].tap()
        XCTAssertTrue(app.buttons["Connect this workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
    }

    private func connect(in app: XCUIApplication, signInButton: String = "Sign in with OpenCode") {
        chooseWorkspace(in: app, signInButton: signInButton)
        capture("Selected workspace", app: app)
        finishApproval(in: app)
        XCTAssertTrue(app.buttons["Remove Saved Credential"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Reconnect OpenCode"].exists)
    }

    private func finishApproval(in app: XCUIApplication) {
        app.buttons["Connect this workspace"].tap()
        XCTAssertTrue(app.staticTexts["Checking OpenCode approval"].waitForExistence(timeout: 5))
        capture("Checking approval after browser return", app: app)
        app.buttons["Receive synthetic token"].tap()
        XCTAssertTrue(app.staticTexts["Verifying OpenCode account"].waitForExistence(timeout: 5))
        capture("Token received with verification pending", app: app)
        app.buttons["Finish synthetic verification"].tap()
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
