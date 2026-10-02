import XCTest

@MainActor
final class CodexCreditsPoolUITests: XCTestCase {
    func testOptInBalanceStatesAndSavedAccountChoices() {
        continueAfterFailure = false
        let states = [
            ("codex-credits", "62,500 credits"),
            ("codex-credits-zero", "0 credits"),
            ("codex-credits-unavailable", "Credits unavailable"),
            ("codex-credits-unlimited", "Unlimited credits"),
            ("codex-credits-failure", "62,500 credits"),
        ]
        for (scenario, expected) in states {
            let runID = UUID().uuidString
            var app = launch(scenario: scenario, runID: runID)
            let poolID = "dashboard-metric-codex.credits-pool"
            let quota = app.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@", "dashboard-metric-codex.window-18000", "12%"
            )).firstMatch
            XCTAssertTrue(quota.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertFalse(app.buttons[poolID].exists, "Credit pool must be off by default")
            if scenario == "codex-credits" { keep("credits-default-dashboard", app: app) }
            openAccount("Personal Codex", in: app)
            let toggle = app.switches["account-metric-visibility-codex.credits-pool"]
            reveal(toggle, in: app)
            XCTAssertEqual(toggle.value as? String, "0", app.debugDescription)
            if scenario == "codex-credits" { keep("credits-settings-off", app: app) }
            // The labeled SwiftUI row also has a switch role; tap its native child switch.
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, "1", app.debugDescription)
            if scenario == "codex-credits" { keep("credits-settings-on", app: app) }
            app.terminate()
            app = launch(scenario: scenario, runID: runID, reset: false)
            let pool = app.buttons[poolID]
            XCTAssertTrue(pool.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(pool.label.contains(expected), pool.label)
            XCTAssertFalse(pool.label.contains("$"), pool.label)
            reveal(pool, in: app)
            keep("\(scenario)-dashboard", app: app)
            if scenario == "codex-credits" {
                openAccount("Work Codex", in: app)
                let workToggle = app.switches["account-metric-visibility-codex.credits-pool"]
                reveal(workToggle, in: app)
                XCTAssertEqual(workToggle.value as? String, "0", "The other account must remain off")
                app.terminate()
                app = launch(scenario: scenario, runID: runID, reset: false)
                tap(app.buttons["More options for Personal Codex"], in: app)
                tap(app.buttons["Customize Card…"], in: app)
                XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
                let choice = app.buttons["customize-metric-codex.credits-pool"]
                reveal(choice, in: app)
                XCTAssertTrue(app.staticTexts["62,500 credits"].exists, app.debugDescription)
                keep("credits-customize-on", app: app)
                tap(choice, in: app)
                tap(app.buttons["Hide"], in: app)
                reveal(app.buttons["Show Credits pool"], in: app)
                tap(app.buttons["Done"], in: app)
                XCTAssertTrue(app.buttons[poolID].waitForNonExistence(timeout: 5), app.debugDescription)
                openAccount("Personal Codex", in: app)
                let restoredToggle = app.switches["account-metric-visibility-codex.credits-pool"]
                reveal(restoredToggle, in: app)
                XCTAssertEqual(restoredToggle.value as? String, "0")
                restoredToggle.switches.firstMatch.tap()
                app.terminate()
                app = launch(scenario: scenario, runID: runID, reset: false)
                XCTAssertTrue(app.buttons[poolID].waitForExistence(timeout: 10))
                XCTAssertTrue(app.buttons[poolID].label.contains("62,500 credits"))
            }
            if scenario == "codex-credits-failure" {
                let refresh = app.buttons["Refresh usage"]
                tap(refresh, in: app)
                let failureText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic refresh failed")).firstMatch
                XCTAssertTrue(failureText.waitForExistence(timeout: 10), app.debugDescription)
                XCTAssertTrue(app.buttons[poolID].label.contains("62,500 credits"), app.buttons[poolID].label)
                XCTAssertTrue(app.buttons[poolID].label.contains("stale"), app.buttons[poolID].label)
                reveal(app.buttons[poolID], in: app)
                keep("credits-stale-dashboard", app: app)
            }
            app.terminate()
        }
    }

    private func launch(scenario: String, runID: String, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": runID,
            "CODEXBAR_UI_TEST_RESET": reset ? "1" : "0", "CODEXBAR_UI_TEST_SCENARIO": scenario,
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func openAccount(_ label: String, in app: XCUIApplication) {
        tap(app.buttons["Open settings"], in: app)
        tap(app.descendants(matching: .any)["settings-accountsAndGroups"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Accounts & Groups"].waitForExistence(timeout: 10))
        tap(app.otherElements[label], in: app)
        XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isEnabled, app.debugDescription)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 1)
        if element.exists && element.isHittable && app.navigationBars.buttons[element.label].exists { return }
        let customizer = app.scrollViews["metric-customization-scroll"]
        let settings = app.collectionViews["provider-account-settings-form"]
        let container = customizer.exists ? customizer : (settings.exists ? settings : app.scrollViews.firstMatch)
        if !customizer.exists && !settings.exists && element.isHittable
            && app.frame.insetBy(dx: 4, dy: 4).contains(element.frame) { return }
        for _ in 0..<12 {
            let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter {
                $0.width <= container.frame.width + 1 && $0.intersects(container.frame)
            }
            let top = max(container.frame.minY, bars.map(\.maxY).max() ?? container.frame.minY)
            let viewport = CGRect(x: container.frame.minX, y: top, width: container.frame.width,
                                  height: max(0, container.frame.maxY - top)).insetBy(dx: 4, dy: 4)
            if element.exists && element.isHittable && viewport.contains(element.frame) { return }
            let upward = !element.exists || element.frame.midY > viewport.midY
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.65 : 0.35))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.4 : 0.6))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Control outside the visible viewport: \(element).\n\(app.debugDescription)")
    }

    private func keep(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
