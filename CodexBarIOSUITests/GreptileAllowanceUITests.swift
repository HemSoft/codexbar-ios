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
        tap(app.buttons["More options for Greptile Free Fixture"], in: app)
        tap(app.buttons["More information for Greptile Free Fixture"], in: app)
        XCTAssertTrue(app.navigationBars["More Information"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Review statuses"].exists)
        XCTAssertTrue(app.staticTexts["Completed"].exists)
        keep("greptile-free-review-statuses", app: app)
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
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CODEXBAR_UI_TESTS": "1", "CODEXBAR_UI_TEST_RUN_ID": UUID().uuidString,
            "CODEXBAR_UI_TEST_RESET": "1", "CODEXBAR_UI_TEST_SCENARIO": scenario,
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let refresh = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Refresh usage")).firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), app.debugDescription)
        refresh.tap()
        return app
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
