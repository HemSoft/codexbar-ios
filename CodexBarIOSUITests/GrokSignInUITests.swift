import XCTest

@MainActor
final class GrokSignInUITests: XCTestCase {
    func testGuidedSetupCancellationReconnectAndRemoval() {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        app.buttons["dashboard-add-account"].tap()
        XCTAssertTrue(app.buttons["Grok"].waitForExistence(timeout: 5))
        keep("Grok Add Account", app: app)
        app.buttons["Grok"].tap()
        let signIn = app.buttons["grok-sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertEqual(app.secureTextFields.count, 0)
        keep("Grok disconnected settings", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        keep("Grok sample approval", app: app)
        app.buttons["Decline"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Disconnect Grok"].exists)
        keep("Grok canceled authorization", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        app.buttons["Approve sample account"].tap()
        XCTAssertTrue(app.buttons["Return to Grok settings"].waitForExistence(timeout: 5))
        keep("Grok sample account connected", app: app)
        app.buttons["Return to Grok settings"].tap()
        XCTAssertTrue(app.buttons["Disconnect Grok"].waitForExistence(timeout: 10))
        keep("Grok connected settings", app: app)
        signIn.tap()
        XCTAssertTrue(app.buttons["Approve sample account"].waitForExistence(timeout: 5))
        app.buttons["Approve sample account"].tap()
        app.buttons["Return to Grok settings"].tap()
        keep("Grok reconnected settings", app: app)
        let disconnect = app.buttons["Disconnect Grok"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        let form = app.collectionViews["provider-account-settings-form"]
        for _ in 0..<6 where !disconnect.isHittable { form.swipeUp() }
        XCTAssertTrue(disconnect.wait(for: \.isHittable, toEqual: true, timeout: 10), app.debugDescription)
        disconnect.tap()
        XCTAssertFalse(app.buttons["Disconnect Grok"].exists)
        XCTAssertTrue(signIn.exists)
        keep("Grok local removal", app: app)
    }

    func testGrokAndCursorMetersStaySeparateAndNoAllowanceIsUnavailable() {
        let app = launch(scenario: "grok")
        let grok = app.buttons["dashboard-metric-grok.included-usage"]
        let bot = app.buttons["dashboard-metric-cursor.grok-bot-weekly"]
        XCTAssertTrue(grok.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(bot.exists, app.debugDescription)
        keep("Grok and Cursor separate meters", app: app)
        app.buttons["More options for Sample Grok"].tap()
        let moreInformation = app.buttons["More information for Sample Grok"]
        if moreInformation.waitForExistence(timeout: 3) {
            moreInformation.tap()
        } else {
            // iPadOS beta may not expose a synthesized context menu.
            app.terminate()
            app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
            app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION"] = "1"
            app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION_ACCOUNT"] = "ui-grok-connected"
            app.launch()
        }
        XCTAssertTrue(app.navigationBars["More Information"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Usage breakdown"].exists)
        keep("Grok product shares as information", app: app)
        app.terminate()

        let noAllowance = launch(scenario: "grok-no-allowance")
        XCTAssertTrue(noAllowance.staticTexts["No shared paid allowance was reported."].waitForExistence(timeout: 10))
        XCTAssertFalse(noAllowance.buttons["dashboard-metric-grok.included-usage"].exists)
        keep("Grok no eligible allowance", app: noAllowance)
    }

    private func launch(scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func keep(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
