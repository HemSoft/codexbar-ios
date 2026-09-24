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
        XCTAssertTrue(app.buttons["More options for SuperGrok Lite"].exists)
        XCTAssertTrue(app.staticTexts["Extra Usage Credits"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["On-demand spending"].exists)
        XCTAssertFalse(app.staticTexts["On-demand cap"].exists)
        keep("SuperGrok Lite beside Cursor", app: app)
        if grok.frame.maxY > app.frame.height * 0.8 { app.swipeUp() }
        keep("SuperGrok Lite weekly usage and credits", app: app)
        app.terminate()

        let zero = launch(scenario: "grok-zero")
        let zeroMeter = zero.buttons["dashboard-metric-grok.included-usage"]
        XCTAssertTrue(zeroMeter.waitForExistence(timeout: 10), zero.debugDescription)
        XCTAssertTrue(zeroMeter.label.contains("0%"), zeroMeter.label)
        XCTAssertTrue(zero.staticTexts["No included usage reported by Grok."].exists)
        XCTAssertTrue(zero.staticTexts["Extra Usage Credits"].exists)
        XCTAssertTrue(zero.buttons["dashboard-metric-cursor.grok-bot-weekly"].exists)
        if zeroMeter.frame.maxY > zero.frame.height * 0.8 { zero.swipeUp() }
        keep("SuperGrok Lite zero weekly usage beside Cursor", app: zero)
        zero.terminate()

        let missing = launch(scenario: "grok-percent-unavailable")
        XCTAssertTrue(missing.staticTexts["Grok did not report included usage."].waitForExistence(timeout: 10))
        XCTAssertFalse(missing.buttons["dashboard-metric-grok.included-usage"].exists)
        missing.swipeUp()
        keep("Grok unavailable percentage stays distinct from zero", app: missing)
        missing.terminate()

        let noAllowance = launch(scenario: "grok-no-allowance")
        XCTAssertTrue(noAllowance.staticTexts["No verified shared paid allowance was reported."].waitForExistence(timeout: 10))
        XCTAssertFalse(noAllowance.buttons["dashboard-metric-grok.included-usage"].exists)
        noAllowance.swipeUp()
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
