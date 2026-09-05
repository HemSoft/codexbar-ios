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
