import XCTest

@MainActor
final class ClaudeUsageUITests: XCTestCase {
    func testWindowLabelsAndSavedCustomizationForProAndMax() {
        continueAfterFailure = false
        for scenario in ["claude-pro", "claude-max"] {
            let runID = UUID().uuidString
            let app = launch(scenario: scenario, runID: runID)
            let session = app.buttons["dashboard-metric-claude.session"]
            let weekly = app.buttons["dashboard-metric-claude.weekly-all"]
            XCTAssertTrue(session.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(weekly.exists, app.debugDescription)
            XCTAssertTrue(session.label.contains("5-hour"), session.label)
            XCTAssertTrue(session.label.contains("42%"), session.label)
            XCTAssertTrue(weekly.label.contains("Weekly"), weekly.label)
            XCTAssertTrue(weekly.label.contains("64%"), weekly.label)
            XCTAssertTrue(session.label.contains("Resets"), session.label)
            XCTAssertTrue(weekly.label.contains("Resets"), weekly.label)
            keep("\(scenario) dashboard", app: app)

            tap(app.buttons["More options for Synthetic Claude"], in: app)
            tap(app.buttons["Customize Card…"], in: app)
            XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
            let sessionChoice = app.buttons["customize-metric-claude.session"]
            let weeklyChoice = app.buttons["customize-metric-claude.weekly-all"]
            XCTAssertTrue(sessionChoice.exists, app.debugDescription)
            XCTAssertTrue(weeklyChoice.exists, app.debugDescription)
            XCTAssertTrue(sessionChoice.label.contains("5-hour"), sessionChoice.label)
            XCTAssertTrue(weeklyChoice.label.contains("Weekly"), weeklyChoice.label)
            keep("\(scenario) Customize Card", app: app)
            tap(weeklyChoice, in: app)
            tap(app.buttons["Hide"], in: app)
            XCTAssertTrue(app.buttons["Show Weekly"].exists, app.debugDescription)
            tap(app.buttons["Done"], in: app)
            XCTAssertTrue(app.navigationBars["Customize Card"].waitForNonExistence(timeout: 5))
            XCTAssertFalse(weekly.exists)
            app.terminate()

            let restored = launch(scenario: scenario, runID: runID, reset: false)
            XCTAssertTrue(restored.buttons["dashboard-metric-claude.session"].waitForExistence(timeout: 10))
            XCTAssertFalse(restored.buttons["dashboard-metric-claude.weekly-all"].exists)
            restored.terminate()
        }
    }

    private func launch(scenario: String, runID: String, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": runID,
            "CODEXBAR_UI_TEST_RESET": reset ? "1" : "0",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": "1",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        let customizer = app.scrollViews["metric-customization-scroll"]
        let scrollView = customizer.exists ? customizer : app.scrollViews.firstMatch
        for _ in 0..<4 where !element.isHittable { scrollView.swipeUp() }
        XCTAssertTrue(element.isEnabled, app.debugDescription)
        XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        element.tap()
    }

    private func keep(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
