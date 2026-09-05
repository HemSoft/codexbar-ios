import XCTest

@MainActor
final class AccountJourneysUITests: XCTestCase {
    func testAccountSetupPersistsGroupAndCredentialAtAccessibilitySize() throws {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.buttons["dashboard-add-account"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["dashboard-add-account"].label, "Add Account")
        tap(app.buttons["Open settings"], in: app)
        tap(app.descendants(matching: .any)["settings-accountsAndGroups"].firstMatch, in: app)
        let groupName = app.textFields["New group"]
        tap(groupName, in: app)
        groupName.typeText("Fixture Team")
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
        tap(credential, in: app)
        credential.typeText("ui-test-credential")
        tap(app.buttons["Save Management API Key"], in: app)
        XCTAssertTrue(app.buttons["Remove Saved Credential"].waitForExistence(timeout: 5))
        tap(app.buttons["Done"], in: app)
        assertBalance("60.00", freshness: "fresh", in: app)
        XCTAssertTrue(app.buttons["More options for OpenRouter 1"].exists)

        app.terminate()
        app.launchEnvironment["CODEXBAR_UI_TEST_RESET"] = "0"
        app.launch()
        assertBalance("25.00", freshness: "fresh", in: app)
        tap(app.buttons["Open settings"], in: app)
        tap(app.descendants(matching: .any)["settings-accountsAndGroups"].firstMatch, in: app)
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

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        XCTAssertTrue(element.isHittable, app.debugDescription)
        element.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 3) && element.isHittable { return }
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
