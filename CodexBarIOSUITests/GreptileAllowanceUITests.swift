import XCTest

@MainActor
final class GreptileAllowanceUITests: XCTestCase {
    func testReviewHistoryAndBillingAvailabilityStates() {
        continueAfterFailure = false
        let app = launch("greptile-free")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not your remaining credits")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["dashboard-metric-greptile.completed-reviews"].exists)
        XCTAssertFalse(app.buttons["dashboard-metric-greptile.review-quota"].exists)
        XCTAssertFalse(app.staticTexts["Starter"].exists)
        reveal(note, in: app)
        keep("greptile-free-history-only", app: app)
        openMoreInformation(in: app)
        keep("greptile-free-review-statuses", app: app)
        tap(app.buttons["Done"].firstMatch, in: app)
        openMoreInformation(in: app, forceFallback: true)
        keep("greptile-forced-menu-fallback-review-statuses", app: app)
        tap(app.buttons["Done"].firstMatch, in: app)
        keepAccountSettings("greptile-free", in: app)
        let metric = app.switches["account-metric-visibility-greptile.completed-reviews"]
        XCTAssertEqual(metric.value as? String, "1")
        app.terminate()

        checkState("greptile-empty", message: "Missing billing data is not a zero balance", metric: nil)
        checkState("greptile-returned-quota", message: "Greptile reports 3 of 17 reviews used", metric: "review-quota")
        let failed = launch("greptile-failure")
        let error = failed.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Greptile is temporarily unavailable"
        )).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10), failed.debugDescription)
        XCTAssertFalse(failed.buttons["dashboard-metric-greptile.completed-reviews"].exists)
        XCTAssertFalse(failed.buttons["dashboard-metric-greptile.review-quota"].exists)
        keep("greptile-provider-failure", app: failed)
        keepAccountSettings("greptile-failure", in: failed)
        failed.terminate()
        checkRenewalScreens()
        checkPaidRenewalScreens()
    }

    private func checkRenewalScreens() {
        let cases = [
            ("greptile-renewal-available", "Renews in", false),
            ("greptile-renewal-available", "Renews in", true),
            ("greptile-renewal-missing", "Renewal date unavailable", false),
            ("greptile-renewal-malformed", "Renewal date unavailable", true),
            ("greptile-renewal-passed", "Period ended.", false),
            ("greptile-renewal-stale", "Last known renewal date", true),
            ("greptile-renewal-expired", "Last known renewal date", false),
        ]
        for (scenario, status, full) in cases {
            let app = launch(scenario, options: [
                "CODEXBAR_UI_TEST_FULL_WIDTH": full ? "1" : "0",
                "CODEXBAR_UI_TEST_DARK": full ? "1" : "0",
                "CODEXBAR_UI_TEST_DEFAULT_TEXT": full ? "0" : "1",
            ])
            let label = app.staticTexts["greptile-renewal-status"].firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(label.label.hasPrefix(status), app.debugDescription)
            let missing = scenario.hasSuffix("missing") || scenario.hasSuffix("malformed")
            XCTAssertEqual(app.staticTexts["greptile-renewal-date"].firstMatch.exists, !missing)
            XCTAssertFalse(app.buttons["dashboard-metric-greptile.review-quota"].exists)
            if missing { XCTAssertFalse(app.buttons["greptile-renewal-connect"].exists) }
            if scenario.hasSuffix("expired") {
                XCTAssertTrue(app.buttons["greptile-renewal-connect"].waitForExistence(timeout: 10))
            }
            reveal(label, in: app)
            keep("\(scenario)-\(full ? "full-dark-large" : "compact-light")", app: app)
            app.terminate()
            app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
            app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION"] = "1"
            app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION_ACCOUNT"] = "ui-greptile-free"
            app.launch()
            XCTAssertTrue(app.navigationBars["More Information"].waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Free allowance renewal"].waitForExistence(timeout: 10), app.debugDescription)
            let detail = app.staticTexts["greptile-renewal-status"].firstMatch
            XCTAssertTrue(detail.label.hasPrefix(status), app.debugDescription)
            keep("\(scenario)-detail-\(full ? "dark-large" : "light")", app: app)
            app.terminate()
        }
    }

    private func checkPaidRenewalScreens() {
        let app = launch("greptile-renewal-paid")
        XCTAssertTrue(app.buttons["dashboard-metric-greptile.completed-reviews"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["greptile-renewal-status"].exists)
        keep("greptile-renewal-paid-compact-light", app: app)
        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION"] = "1"
        app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION_ACCOUNT"] = "ui-greptile-free"
        app.launch()
        XCTAssertTrue(app.navigationBars["More Information"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Review statuses"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Free allowance renewal"].exists)
        keep("greptile-renewal-paid-detail-light", app: app)
        app.terminate()
    }

    private func launch(_ scenario: String, options: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1", "CODEXBAR_UI_TEST_SCENARIO": scenario,
        ]
        app.launchEnvironment.merge(options) { _, replacement in replacement }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let refresh = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Refresh usage")).firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), app.debugDescription)
        refresh.tap()
        return app
    }

    private func openMoreInformation(in app: XCUIApplication, forceFallback: Bool = false) {
        if !forceFallback {
            tap(app.buttons["More options for Greptile Free Fixture"], in: app)
            let information = app.buttons["More information for Greptile Free Fixture"]
            if information.waitForExistence(timeout: 3) {
                tap(information, in: app)
                XCTAssertTrue(app.navigationBars["More Information"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts["Review statuses"].waitForExistence(timeout: 10))
                return
            }
        }
        // Same conditional workaround as the billing journey; force it once even if the menu works.
        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION"] = "1"
        app.launchEnvironment["CODEXBAR_UI_TEST_MORE_INFORMATION_ACCOUNT"] = "ui-greptile-free"
        app.launch()
        XCTAssertTrue(app.navigationBars["More Information"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Review statuses"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Completed"].exists)
        XCTAssertTrue(app.staticTexts["2"].exists)
    }

    private func checkState(_ scenario: String, message: String, metric: String?) {
        let app = launch(scenario)
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), app.debugDescription)
        if let metric {
            XCTAssertTrue(app.buttons["dashboard-metric-greptile.\(metric)"].exists)
        } else {
            XCTAssertFalse(app.buttons["dashboard-metric-greptile.completed-reviews"].exists)
            XCTAssertFalse(app.buttons["dashboard-metric-greptile.review-quota"].exists)
        }
        reveal(note, in: app)
        keep(scenario, app: app)
        keepAccountSettings(scenario, in: app)
        app.terminate()
    }

    private func keepAccountSettings(_ scenario: String, in app: XCUIApplication) {
        tap(app.buttons["Open settings"], in: app)
        tap(app.descendants(matching: .any)["settings-accountsAndGroups"].firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Accounts & Groups"].waitForExistence(timeout: 10))
        tap(app.otherElements["Greptile Free Fixture"], in: app)
        XCTAssertTrue(app.navigationBars["Greptile Free Fixture"].waitForExistence(timeout: 10))
        if scenario == "greptile-free" {
            let add = app.buttons["Add Greptile account for renewal"]
            reveal(add, in: app)
            XCTAssertTrue(add.exists)
            XCTAssertFalse(app.secureTextFields.firstMatch.exists)
            XCTAssertFalse(app.buttons["Sign in with Greptile"].exists)
            keep("greptile-renewal-legacy-account-settings", app: app)
        }
        let section = app.staticTexts["Metrics"].firstMatch
        reveal(section, in: app)
        keep("\(scenario)-account-metrics", app: app)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isEnabled, app.debugDescription)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 1)
        if element.exists && element.isHittable && app.frame.insetBy(dx: 4, dy: 4).contains(element.frame) { return }
        let form = app.collectionViews["provider-account-settings-form"]
        let container = form.exists ? form : app.scrollViews.firstMatch
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
