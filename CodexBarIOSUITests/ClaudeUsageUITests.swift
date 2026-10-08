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
            XCTAssertTrue(weekly.waitForNonExistence(timeout: 5), app.debugDescription)
            app.terminate()

            let restored = launch(scenario: scenario, runID: runID, reset: false)
            XCTAssertTrue(restored.buttons["dashboard-metric-claude.session"].waitForExistence(timeout: 10))
            XCTAssertTrue(restored.buttons["dashboard-metric-claude.weekly-all"].waitForNonExistence(timeout: 5))
            restored.terminate()
        }
        for defaultText in [true, false] {
            for dark in [false, true] { exerciseSavedReset(defaultText: defaultText, dark: dark) }
        }
        exerciseAmbiguousReset()
        exerciseUnavailableResets()
    }

    private func exerciseSavedReset(defaultText: Bool, dark: Bool) {
        let runID = UUID().uuidString
        let scenario = "claude-resets-two-accounts"
        var app = launch(scenario: scenario, runID: runID, defaultText: defaultText, dark: dark)
        let variant = "\(defaultText ? "default" : "accessibility2")-\(dark ? "dark" : "light")"
        assertResetAvailability(2, account: "ui-claude", in: app)
        assertResetAvailability(1, account: "ui-claude-second", in: app)
        assertRequests(0, title: "Synthetic Claude", in: app)
        keep("claude-resets-available-\(variant)", app: app)
        tap(app.buttons["claude-view-resets-ui-claude"], in: app)
        let summary = app.staticTexts["claude-reset-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("2 resets available"), summary.label)
        tap(app.buttons["claude-use-reset"], in: app)
        let confirmation = app.alerts["Use one Claude reset?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        let message = confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "cannot be undone")).firstMatch
        XCTAssertTrue(message.exists, app.debugDescription)
        XCTAssertTrue(message.label.contains("Synthetic Claude"))
        XCTAssertTrue(message.label.contains("five-hour usage") && message.label.contains("weekly usage"))
        keep("claude-resets-confirmation-\(variant)", app: app)
        tap(confirmation.buttons["Cancel"], in: app)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        tap(app.buttons["Done"], in: app)
        assertRequests(0, title: "Synthetic Claude", in: app)
        assertResetAvailability(2, account: "ui-claude", in: app)
        tap(app.buttons["claude-view-resets-ui-claude"], in: app)
        tap(app.buttons["claude-use-reset"], in: app)
        tap(confirmation.buttons["Use reset"], in: app)
        let feedback = app.staticTexts["claude-reset-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(feedback.label.contains("Claude confirmed the reset"), feedback.label)
        XCTAssertTrue(summary.label.contains("1 reset available"), summary.label)
        keep("claude-resets-refreshed-\(variant)", app: app)
        tap(app.buttons["Done"], in: app)
        assertRequests(1, title: "Synthetic Claude", in: app)
        assertRequests(0, title: "Second Claude", in: app)
        assertResetAvailability(1, account: "ui-claude", in: app)
        assertResetAvailability(1, account: "ui-claude-second", in: app)
        for id in ["dashboard-metric-claude.session", "dashboard-metric-claude.weekly-all"] {
            let title = id.hasSuffix("session") ? "5-hour" : "Weekly"
            let value = id.hasSuffix("session") ? "42" : "64"
            let zero = app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label BEGINSWITH %@", id, "\(title), 0%, 0 of 100 used,"
            )).firstMatch
            let unchanged = app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label BEGINSWITH %@", id, "\(title), \(value)%, \(value) of 100 used,"
            )).firstMatch
            reveal(zero, in: app)
            XCTAssertTrue(zero.exists, app.debugDescription)
            reveal(unchanged, in: app)
            XCTAssertTrue(unchanged.exists, app.debugDescription)
        }
        keep("claude-resets-account-isolation-\(variant)", app: app)
        app.terminate()
        app = launch(scenario: scenario, runID: runID, reset: false, defaultText: defaultText, dark: dark)
        assertRequests(1, title: "Synthetic Claude", in: app)
        assertRequests(0, title: "Second Claude", in: app)
        assertResetAvailability(1, account: "ui-claude", in: app)
        app.terminate()
    }

    private func exerciseAmbiguousReset() {
        let runID = UUID().uuidString
        var app = launch(scenario: "claude-resets-error", runID: runID)
        for _ in 0..<2 {
            tap(app.buttons["claude-view-resets-ui-claude"], in: app)
            tap(app.buttons["claude-use-reset"], in: app)
            tap(app.alerts["Use one Claude reset?"].buttons["Use reset"], in: app)
            let feedback = app.staticTexts["claude-reset-feedback"]
            XCTAssertTrue(feedback.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(feedback.label.contains("has not confirmed"), feedback.label)
            keep("claude-resets-unconfirmed", app: app)
            tap(app.buttons["Done"], in: app)
            assertRequests(1, title: "Synthetic Claude", in: app)
            assertResetAvailability(2, account: "ui-claude", in: app)
        }
        app.terminate()
        app = launch(scenario: "claude-resets-error", runID: runID, reset: false)
        assertRequests(1, title: "Synthetic Claude", in: app)
        assertResetAvailability(2, account: "ui-claude", in: app)
        app.terminate()
    }

    private func exerciseUnavailableResets() {
        for scenario in ["zero", "ineligible", "paused", "inactive", "expired", "unknown", "malformed", "failed"] {
            let app = launch(scenario: "claude-resets-\(scenario)", runID: UUID().uuidString)
            let known = !["unknown", "malformed", "failed"].contains(scenario)
            let availability = app.staticTexts["claude-reset-availability-ui-claude"]
            reveal(availability, in: app)
            XCTAssertTrue(availability.label.contains(known ? "0 saved resets available" : "Saved resets unavailable"), availability.label)
            if known {
                tap(app.buttons["claude-view-resets-ui-claude"], in: app)
                XCTAssertTrue(app.navigationBars["Claude resets"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["claude-use-reset"].exists, "Unavailable grant must have no consumption action")
                keep("claude-resets-\(scenario)", app: app)
                tap(app.buttons["Done"], in: app)
            } else {
                XCTAssertFalse(app.buttons["claude-view-resets-ui-claude"].exists)
                keep("claude-resets-\(scenario)", app: app)
            }
            if scenario != "failed" { assertRequests(0, title: "Synthetic Claude", in: app) }
            app.terminate()
        }
    }

    private func assertRequests(_ count: Int, title: String, in app: XCUIApplication) {
        let header = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", title + ", ", "Reset requests: \(count)"
        )).firstMatch
        reveal(header, in: app)
        XCTAssertTrue(header.exists, app.debugDescription)
    }

    private func assertResetAvailability(_ count: Int, account: String, in app: XCUIApplication) {
        let availability = app.staticTexts["claude-reset-availability-\(account)"]
        reveal(availability, in: app)
        XCTAssertTrue(availability.label.contains(count == 1 ? "1 saved reset available" : "\(count) saved resets available"), availability.label)
    }

    private func launch(scenario: String, runID: String, reset: Bool = true, defaultText: Bool = true, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": runID,
            "CODEXBAR_UI_TEST_RESET": reset ? "1" : "0",
            "CODEXBAR_UI_TEST_SCENARIO": scenario,
            "CODEXBAR_UI_TEST_DEFAULT_TEXT": defaultText ? "1" : "0",
            "CODEXBAR_UI_TEST_DARK": dark ? "1" : "0",
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", dark ? "Dark" : "Light"]
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isEnabled, app.debugDescription)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let customizer = app.scrollViews["metric-customization-scroll"]
        let scrollView = customizer.exists ? customizer : app.scrollViews.firstMatch
        let surface = scrollView.exists ? scrollView : app
        for _ in 0..<5 where !element.exists || !element.isHittable { surface.swipeUp() }
        for _ in 0..<5 where !element.exists || !element.isHittable { surface.swipeDown() }
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(element.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
    }

    private func keep(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
