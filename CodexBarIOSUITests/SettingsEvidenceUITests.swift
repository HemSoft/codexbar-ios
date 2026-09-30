import XCTest

/// Manual-only rendered evidence. Automatic PR CI does not execute the UI-test target.
@MainActor
final class SettingsEvidenceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEverySettingsDestinationAndDoneBack() {
        let app = launch()
        openSettings(app)
        capture("settings-home")
        let destinations = ["accountsAndGroups", "dashboard", "alerts", "widgets", "helpAndAbout", "dataAndRecovery"]
        for destination in destinations {
            select(destination, in: app)
            capture("settings-\(destination)")
            returnToCategories(app)
        }
        tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        XCTAssertTrue(app.buttons["Open settings"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testPendingDuplicateGroupBlocksDoneUntilCorrected() {
        let app = launch()
        openSettings(app)
        select("accountsAndGroups", in: app)
        let field = app.textFields["New group"].firstMatch
        tap(field, in: app)
        field.typeText("Fixture Group")
        tap(app.buttons["Add group"].firstMatch, in: app)
        tap(field, in: app)
        field.typeText("Fixture Group")
        tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        let error = app.descendants(matching: .any).matching(identifier: "settings-group-validation-error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Accounts & Groups"].exists)
        capture("settings-pending-group-error")
        tap(field, in: app)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Fixture Group".count))
        field.typeText("Corrected Group")
        tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
        XCTAssertTrue(app.buttons["Open settings"].waitForExistence(timeout: 5))
        openSettings(app)
        select("accountsAndGroups", in: app)
        XCTAssertTrue(app.textFields.containing(NSPredicate(format: "value == %@", "Corrected Group")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields.containing(NSPredicate(format: "value == %@", "Fixture Group")).firstMatch.waitForExistence(timeout: 5))
        capture("settings-corrected-groups")
        app.terminate()
    }

    func testSyntheticGrantedAndDeniedNotificationFeedback() {
        for granted in [false, true] {
            let app = launch(granted: granted)
            openSettings(app)
            select("alerts", in: app)
            tapSwitch(app.switches["Monitor GitHub Service Status"].firstMatch, in: app)
            let incident = app.switches["Incident Notifications"].firstMatch
            let recovery = app.switches["Recovery Notifications"].firstMatch
            XCTAssertTrue(incident.isEnabled)
            tapSwitch(incident, in: app)
            if granted {
                XCTAssertEqual(incident.value as? String, "1")
                tapSwitch(recovery, in: app)
                XCTAssertEqual(recovery.value as? String, "1")
            } else {
                let message = app.staticTexts["Notifications are disabled for CodexBar."].firstMatch
                reveal(message, in: app)
                XCTAssertTrue(message.waitForExistence(timeout: 5))
                XCTAssertEqual(incident.value as? String, "0")
                tapSwitch(recovery, in: app)
                XCTAssertTrue(message.waitForExistence(timeout: 5))
                XCTAssertEqual(recovery.value as? String, "0")
            }
            capture(granted ? "settings-notifications-granted" : "settings-notifications-denied")
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            XCTAssertTrue(app.buttons["Open settings"].waitForExistence(timeout: 5))
            openSettings(app)
            select("alerts", in: app)
            XCTAssertEqual(app.switches["Monitor GitHub Service Status"].firstMatch.value as? String, "1")
            reveal(incident, in: app)
            XCTAssertEqual(incident.value as? String, granted ? "1" : "0")
            reveal(recovery, in: app)
            XCTAssertEqual(recovery.value as? String, granted ? "1" : "0")
            capture("settings-notifications-persisted-\(granted)")
            tap(app.navigationBars.buttons["Done"].firstMatch, in: app)
            XCTAssertTrue(app.buttons["Open settings"].waitForExistence(timeout: 5))
            openSettings(app)
            select("alerts", in: app)
            tapSwitch(app.switches["Monitor GitHub Service Status"].firstMatch, in: app)
            reveal(incident, in: app)
            XCTAssertFalse(incident.isEnabled)
            reveal(recovery, in: app)
            XCTAssertFalse(recovery.isEnabled)
            capture("settings-monitor-disabled-\(granted)")
            app.terminate()
        }
    }

    private func launch(granted: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1",
            "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1",
            "CODEXBAR_UI_TEST_SCENARIO": "settings-evidence",
            "CODEXBAR_UI_TEST_NOTIFICATION_GRANTED": granted ? "1" : "0",
        ]
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        tap(app.buttons["Open settings"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func select(_ destination: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any).matching(identifier: "settings-\(destination)").firstMatch
        tap(element, in: app)
    }

    private func returnToCategories(_ app: XCUIApplication) {
        let category = app.descendants(matching: .any).matching(identifier: "settings-accountsAndGroups").firstMatch
        if category.exists && category.isHittable { return }
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.exists {
            tap(back, in: app)
        } else {
            tap(app.navigationBars.buttons["Show Sidebar"].firstMatch, in: app)
        }
    }

    private func tapSwitch(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        let control = element.switches.firstMatch
        (control.exists ? control : element).tap()
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let visibleTop = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? 0
            if element.exists && element.frame.midY < visibleTop {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        capture("settings-unreachable-control")
        XCTFail("Unreachable Settings control: \(element). UI: \(app.debugDescription)")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
