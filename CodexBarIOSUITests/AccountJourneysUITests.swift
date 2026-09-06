import XCTest

@MainActor
final class AccountJourneysUITests: XCTestCase {
    func testAccountSetupPersistsGroupAndCredentialAtAccessibilitySize() throws {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["dashboard-add-account"].label, "Add Account")
        openAccountsAndGroups(in: app)
        let groupName = app.textFields["New group"]
        enter("Fixture Team", into: groupName, in: app)
        tap(app.buttons["Add group"], in: app)
        XCTAssertEqual(app.textFields["Group name"].value as? String, "Fixture Team")
        tap(app.buttons["Done"], in: app)

        tap(app.buttons["dashboard-add-account"], in: app)
        tap(app.buttons["OpenRouter"], in: app)
        let accountLabel = app.textFields["account-label"]
        reveal(accountLabel, in: app)
        XCTAssertEqual(accountLabel.value as? String, "OpenRouter 1")
        let groupPicker = app.descendants(matching: .any)["account-group-picker"].firstMatch
        tap(groupPicker, in: app)
        tap(app.buttons["Fixture Team"], in: app)
        XCTAssertTrue(groupPicker.label.contains("Group"))
        XCTAssertEqual(groupPicker.value as? String, "Fixture Team")
        let credential = app.secureTextFields["Paste OpenRouter Management API Key"]
        enter("ui-test-credential", into: credential, in: app)
        tap(app.buttons["Save Management API Key"], in: app)
        XCTAssertTrue(app.buttons["Remove Saved Credential"].waitForExistence(timeout: 5))
        tap(app.buttons["Done"], in: app)
        assertBalance("60.00", freshness: "fresh", in: app)
        XCTAssertTrue(app.buttons["More options for OpenRouter 1"].exists)

        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launch()
        assertBalance("25.00", freshness: "fresh", in: app)
        openAccountsAndGroups(in: app)
        let savedAccount = app.otherElements["OpenRouter 1"]
        reveal(savedAccount, in: app)
        XCTAssertEqual(savedAccount.value as? String, "OpenRouter configured, Fixture Team group")
        tap(savedAccount, in: app)
        XCTAssertEqual(app.textFields["account-label"].value as? String, "OpenRouter 1")
        XCTAssertEqual(app.descendants(matching: .any)["account-group-picker"].firstMatch.value as? String, "Fixture Team")
        reveal(app.buttons["Remove Saved Credential"], in: app)
        XCTAssertTrue(app.buttons["Remove Saved Credential"].isHittable)
    }

    func testRefreshRecoveryHistoryAndAccountDeepLink() throws {
        let app = launch(scenario: "recovery")
        assertBalance("25.00", freshness: "fresh", in: app)
        tap(app.buttons["Refresh usage"], in: app)
        assertBalance("25.00", freshness: "stale", in: app)
        tap(app.buttons["Refresh problem details"], in: app)
        XCTAssertTrue(app.staticTexts["Fixture refresh failed. Retry to recover."].waitForExistence(timeout: 5))
        tap(app.buttons["Retry"], in: app)
        assertBalance("60.00", freshness: "fresh", in: app)
        XCTAssertFalse(app.buttons["Retry"].exists)
        let targetMenu = app.buttons["More options for Target Account"]
        XCTAssertFalse(targetMenu.isHittable, "The URL destination must start outside the viewport")

        let history = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Usage history.")).firstMatch
        tap(history, in: app)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        let chart = app.otherElements["Recovery Account history chart"]
        reveal(chart, in: app)
        XCTAssertTrue(chart.label.contains("Recovery Account"))
        let sevenDayValue = chart.value as? String
        tap(app.buttons["Today"], in: app)
        XCTAssertTrue(app.buttons["Today"].isSelected)
        XCTAssertNotEqual(chart.value as? String, sevenDayValue)
        tap(app.buttons["7 days"], in: app)
        XCTAssertTrue(app.buttons["7 days"].isSelected)
        XCTAssertEqual(chart.value as? String, sevenDayValue)

        // Only URL navigation may reveal the initially offscreen destination.
        XCUIDevice.shared.system.open(URL(string: "codexbar://provider?account=ui-navigation-5")!)
        XCTAssertTrue(app.navigationBars["History"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(targetMenu.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(targetMenu.label, "More options for Target Account")
        XCUIDevice.shared.system.open(URL(string: "codexbar://provider?account=ui-recovery-account")!)
        let accountMenu = app.buttons["More options for Recovery Account"]
        XCTAssertTrue(accountMenu.wait(for: \.isHittable, toEqual: true, timeout: 5))
        assertBalance("60.00", freshness: "fresh", in: app)
    }

    func testSixGoogleChoicesAndIndependentCustomizationPersist() throws {
        let app = launch(scenario: "google-six")
        assertGoogleMetric("gemini.five-hour", contains: "12%", in: app)
        assertGoogleMetric("gemini.weekly", contains: "45%", in: app)
        for (id, value) in zip(Self.codingMetricIDs, ["0%", "31%", "0%", "0%"]) {
            assertGoogleMetric(id, contains: value, in: app)
        }
        openGoogleAccount("Apps Fixture", in: app)
        assertMetricSwitches(["gemini.five-hour", "gemini.weekly"], in: app)
        dismissAccountSettings(in: app)
        openGoogleAccount("Coding Fixture", in: app)
        assertMetricSwitches(Self.codingMetricIDs, in: app)
        dismissAccountSettings(in: app)

        openCodingCustomizer(in: app)
        let weekly = "antigravity.gemini-weekly"
        tap(app.buttons["customize-metric-\(weekly)"], in: app)
        tap(app.buttons["Move Earlier"], in: app)
        let first = app.buttons["customize-metric-\(weekly)"]
        let second = app.buttons["customize-metric-antigravity.gemini-5h"]
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        tap(first, in: app)
        tap(app.buttons["Tile Width"], in: app)
        tap(app.buttons["Half"], in: app)
        tap(first, in: app)
        tap(app.buttons["Visualization"], in: app)
        tap(app.buttons["Circular ring"], in: app)
        tap(first, in: app)
        tap(app.buttons["Hide"], in: app)
        XCTAssertTrue(app.buttons["Show Gemini Models weekly"].exists)
        tap(app.buttons["Done"], in: app)
        XCTAssertTrue(app.navigationBars["Customize Card"].waitForNonExistence(timeout: 5))
        assertGoogleMetric("gemini.weekly", contains: "45%", in: app)
        assertGoogleMetric("antigravity.3p-weekly", contains: "0%", in: app)
        XCTAssertTrue(app.buttons["dashboard-metric-\(weekly)"].waitForNonExistence(timeout: 5))

        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launch()
        assertGoogleMetric("antigravity.3p-weekly", contains: "0%", in: app)
        XCTAssertTrue(app.buttons["dashboard-metric-\(weekly)"].waitForNonExistence(timeout: 5))
        openCodingCustomizer(in: app)
        tap(app.buttons["Show Gemini Models weekly"], in: app)
        XCTAssertLessThan(first.frame.minY, second.frame.minY)
        tap(first, in: app)
        tap(app.buttons["Visualization"], in: app)
        XCTAssertTrue(app.buttons["Circular ring"].isSelected, app.debugDescription)
        app.tap()
    }

    func testGeminiOnlyDashboardShowsCodingSetupAndKeepsSelectionOnRelaunch() throws {
        let app = launch(scenario: "google-apps-only")
        assertGoogleMetric("gemini.five-hour", contains: "12%", in: app)
        assertGoogleMetric("gemini.weekly", contains: "45%", in: app)
        for id in Self.codingMetricIDs {
            assertGoogleMetric(id, contains: "Setup required", in: app)
        }
        tap(app.buttons["More options for Antigravity"], in: app)
        tap(app.buttons["Customize Card…"], in: app)
        let hiddenID = "antigravity.gemini-weekly"
        tap(app.buttons["customize-metric-\(hiddenID)"], in: app)
        tap(app.buttons["Hide"], in: app)
        tap(app.buttons["Done"], in: app)
        tap(app.buttons["Refresh usage"], in: app)
        assertGoogleMetric("antigravity.3p-weekly", contains: "Setup required", in: app)
        XCTAssertTrue(app.buttons["dashboard-metric-\(hiddenID)"].waitForNonExistence(timeout: 5))
        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launch()
        assertGoogleMetric("antigravity.3p-weekly", contains: "Setup required", in: app)
        XCTAssertTrue(app.buttons["dashboard-metric-\(hiddenID)"].waitForNonExistence(timeout: 5))
        openGoogleAccount("Antigravity", in: app)
        let toggle = app.switches["account-metric-visibility-\(hiddenID)"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        tap(toggle, in: app)
        dismissAccountSettings(in: app)
        for id in Self.codingMetricIDs {
            assertGoogleMetric(id, contains: "Setup required", in: app)
        }
    }

    func testAntigravityOnlyChoicesSurvivePartialAndFailedRefresh() throws {
        let app = launch(scenario: "google-antigravity")
        XCTAssertTrue(app.buttons["More options for Coding Fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["More options for Apps Fixture"].waitForNonExistence(timeout: 5))
        assertGoogleMetric("gemini.five-hour", contains: "Setup required", in: app)
        assertGoogleMetric("gemini.weekly", contains: "Setup required", in: app)
        for (id, value) in zip(Self.codingMetricIDs, ["0%", "31%", "0%", "0%"]) {
            assertGoogleMetric(id, contains: value, in: app)
        }
        tap(app.buttons["Refresh usage"], in: app)
        assertGoogleMetric("antigravity.gemini-weekly", contains: "Unavailable", in: app)
        assertGoogleMetric("antigravity.3p-5h", contains: "Disabled", in: app)
        assertGoogleMetric("antigravity.gemini-5h", contains: "0%", in: app)
        openCodingCustomizer(in: app)
        for id in Self.codingMetricIDs {
            reveal(app.buttons["customize-metric-\(id)"], in: app)
            XCTAssertTrue(app.buttons["customize-metric-\(id)"].isHittable)
        }
        tap(app.buttons["Done"], in: app)
        openGoogleAccount("Coding Fixture", in: app)
        for (id, reason) in [("antigravity.gemini-weekly", "Unavailable"), ("antigravity.3p-5h", "Disabled")] {
            let toggle = app.switches["account-metric-visibility-\(id)"]
            reveal(toggle, in: app)
            XCTAssertTrue(toggle.label.contains(reason), toggle.label)
            XCTAssertEqual(toggle.value as? String, "1")
        }
        dismissAccountSettings(in: app)
        // Dismissing account settings refreshes the account and consumes the failure stage.
        assertGoogleMetric("antigravity.gemini-5h", contains: "stale", in: app)
        assertGoogleMetric("antigravity.gemini-weekly", contains: "Unavailable", in: app)
        tap(app.buttons["Refresh usage"], in: app)
        for (id, value) in zip(Self.codingMetricIDs, ["100%", "31%", "20%", "60%"]) {
            assertGoogleMetric(id, contains: value, in: app)
            XCTAssertTrue(app.buttons["dashboard-metric-\(id)"].label.contains("fresh"))
        }
        openGoogleAccount("Coding Fixture", in: app)
        assertMetricSwitches(Self.codingMetricIDs, in: app)
        tap(app.buttons["Done"], in: app)
    }

    private static let codingMetricIDs = [
        "antigravity.gemini-5h", "antigravity.gemini-weekly", "antigravity.3p-5h", "antigravity.3p-weekly",
    ]

    private func assertGoogleMetric(_ id: String, contains value: String, in app: XCUIApplication) {
        let metric = app.buttons["dashboard-metric-\(id)"]
        reveal(metric, in: app)
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: metric)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed, metric.label)
    }

    private func assertMetricSwitches(_ ids: [String], in app: XCUIApplication) {
        for id in ids {
            let toggle = app.switches["account-metric-visibility-\(id)"]
            reveal(toggle, in: app)
            XCTAssertEqual(toggle.value as? String, "1")
        }
    }

    private func openGoogleAccount(_ name: String, in app: XCUIApplication) {
        tap(app.buttons["More options for \(name)"], in: app)
        tap(app.buttons["Configure account \(name)"], in: app)
    }

    private func openCodingCustomizer(in app: XCUIApplication) {
        tap(app.buttons["More options for Coding Fixture"], in: app)
        tap(app.buttons["Customize Card…"], in: app)
        XCTAssertTrue(app.navigationBars["Customize Card"].waitForExistence(timeout: 5))
    }

    private func dismissAccountSettings(in app: XCUIApplication) {
        tap(app.navigationBars.buttons["Done"], in: app)
        XCTAssertTrue(app.collectionViews["provider-account-settings-form"].waitForNonExistence(timeout: 5), app.debugDescription)
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
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ]
        app.launch()
        addTeardownBlock { [weak self] in
            guard let self else { return }
            await MainActor.run {
                guard (self.testRun?.failureCount ?? 0) > 0 else { return }
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Failed journey"
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Accessibility hierarchy"
                hierarchy.lifetime = .keepAlways
                self.add(hierarchy)
            }
        }
        return app
    }

    private func assertBalance(_ amount: String, freshness: String, in app: XCUIApplication) {
        let balance = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            amount, freshness
        )).firstMatch
        XCTAssertTrue(balance.waitForExistence(timeout: 10), app.debugDescription)
        reveal(balance, in: app)
        XCTAssertTrue(balance.isHittable)
        XCTAssertTrue(balance.label.lowercased().contains("balance"), balance.label)
    }

    private func openAccountsAndGroups(in app: XCUIApplication) {
        tap(app.buttons["Open settings"], in: app)
        let category = app.descendants(matching: .any)["settings-accountsAndGroups"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 10), app.debugDescription)
        tap(category, in: app)
        XCTAssertTrue(app.navigationBars["Accounts & Groups"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertTrue(element.isHittable, app.debugDescription)
        element.tap()
    }

    private func enter(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        reveal(field, in: app)
        revealField(field, in: app)
        tap(field, in: app)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            // The first iPad split-view tap can activate the detail pane without focusing its field.
            revealField(field, in: app)
            field.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText(text)
    }

    private func revealField(_ field: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        let identifier = field.identifier.isEmpty ? (field.placeholderValue ?? field.label) : field.identifier
        let form = app.collectionViews.containing(field.elementType, identifier: identifier).firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Expected the form containing \(identifier)")
        for _ in 0..<12 {
            let viewport = fieldViewport(form: form, in: app)
            if viewport.contains(field.frame) && field.isHittable { return }
            // Short drags keep a field from jumping behind a sheet's navigation bar.
            let upward = field.frame.midY > viewport.midY
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.65 : 0.35))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.4 : 0.6))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Field is outside the visible form: \(field).\n\(app.debugDescription)")
    }

    private func fieldViewport(form: XCUIElement, in app: XCUIApplication) -> CGRect {
        let frame = form.frame
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame).filter {
            $0.width <= frame.width + 1 && $0.intersects(frame)
        }
        let top = max(frame.minY, bars.map(\.maxY).max() ?? frame.minY)
        let keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists ? min(frame.maxY, keyboard.frame.minY) : frame.maxY
        return CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
            .insetBy(dx: 4, dy: 4)
    }

    private func scrollContainer(for element: XCUIElement, in app: XCUIApplication) -> XCUIElement? {
        let customizer = app.scrollViews["metric-customization-scroll"]
        if customizer.exists { return customizer }
        let settings = app.collectionViews["provider-account-settings-form"]
        if settings.exists { return settings }
        guard element.exists else { return nil }
        let identifier = element.identifier.isEmpty ? element.label : element.identifier
        let scroll = app.scrollViews.containing(element.elementType, identifier: identifier).firstMatch
        return scroll.exists ? scroll : nil
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 3) && element.isHittable { return }
        if let scroll = scrollContainer(for: element, in: app) {
            for defaultUpward in [true, false] {
                for _ in 0..<12 {
                    let viewport = fieldViewport(form: scroll, in: app)
                    if element.exists && element.isHittable && viewport.contains(element.frame) { return }
                    let upward = element.exists ? element.frame.midY > viewport.midY : defaultUpward
                    let origin = app.coordinate(withNormalizedOffset: .zero)
                    let start = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (upward ? 0.75 : 0.3)))
                    let end = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.minY + viewport.height * (upward ? 0.35 : 0.7)))
                    start.press(forDuration: 0.05, thenDragTo: end)
                }
            }
            XCTFail("Control is unreachable in its scroll view: \(element).\n\(app.debugDescription)")
            return
        }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists && element.isHittable { return }
        }
        for _ in 0..<8 {
            app.swipeDown()
            if element.exists && element.isHittable { return }
        }
        XCTFail("Control is unreachable at accessibility text size: \(element).\n\(app.debugDescription)")
    }
}
