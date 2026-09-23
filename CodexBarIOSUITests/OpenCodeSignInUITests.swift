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
        XCTAssertTrue(app.buttons["Choose Sample workspace"].waitForExistence(timeout: 10))
        capture("Synthetic browser approval and workspace choice", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Saved Credential"].exists)
        connect(in: app)
        capture("OpenCode connected", app: app)
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
        chooseWorkspace(in: app)
        app.buttons["Connect this workspace"].tap()
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

    private func chooseWorkspace(in app: XCUIApplication) {
        app.buttons["Sign in with OpenCode"].tap()
        XCTAssertTrue(app.buttons["Choose Sample workspace"].waitForExistence(timeout: 10))
        app.buttons["Choose Sample workspace"].tap()
        XCTAssertTrue(app.buttons["Connect this workspace"].wait(for: \.isEnabled, toEqual: true, timeout: 10))
    }

    private func connect(in app: XCUIApplication) {
        app.buttons["Sign in with OpenCode"].tap()
        XCTAssertTrue(app.buttons["Choose Sample workspace"].waitForExistence(timeout: 10))
        app.buttons["Choose Sample workspace"].tap()
        let connect = app.buttons["Connect this workspace"]
        XCTAssertTrue(connect.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        capture("Selected workspace", app: app)
        connect.tap()
        XCTAssertTrue(app.buttons["Remove Saved Credential"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Reconnect OpenCode"].exists)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
