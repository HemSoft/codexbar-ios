import XCTest
@testable import CodexBarIOS

final class SettingsPresentationRegressionTests: XCTestCase {
    func testAllDestinationsHaveExactTypedContentRoutes() {
        let expected: [SettingsDestination: SettingsContentRoute] = [
            .accountsAndGroups: .data(.accountsAndGroups),
            .dashboard: .preferences(.dashboard),
            .alerts: .preferences(.alerts),
            .widgets: .preferences(.widgets),
            .helpAndAbout: .helpAndAbout,
            .dataAndRecovery: .data(.dataAndRecovery),
        ]
        XCTAssertEqual(Set(expected.keys), Set(SettingsDestination.allCases))
        for destination in SettingsDestination.allCases {
            XCTAssertEqual(SettingsContentRoute.resolve(destination), expected[destination])
        }
    }

    func testNavigationIdentityOrderAndInitialRouteAreUnchanged() {
        XCTAssertEqual(SettingsDestination.allCases.map(\.rawValue), [
            "accountsAndGroups", "dashboard", "alerts", "widgets", "helpAndAbout", "dataAndRecovery",
        ])
        XCTAssertEqual(SettingsDestination.allCases.map(\.title), [
            "Accounts & Groups", "Dashboard", "Alerts", "Widgets", "Help & About", "Data & Recovery",
        ])
        XCTAssertEqual(SettingsDestination.allCases.map(\.systemImage), [
            "person.2", "rectangle.3.group", "bell", "square.grid.2x2",
            "questionmark.circle", "externaldrive.badge.exclamationmark",
        ])
        XCTAssertEqual(SettingsInitialRoute.accounts.destination, .accountsAndGroups)
        XCTAssertTrue(SettingsDestination.allCases.allSatisfy { $0.id == $0 })
    }

    func testAccountSummaryUsesCountsNotIdentifiers() {
        XCTAssertEqual(SettingsCategorySummary.accounts(accountCount: 0, groupCount: 0), "0 accounts · 0 groups")
        XCTAssertEqual(SettingsCategorySummary.accounts(accountCount: 1, groupCount: 1), "1 account · 1 group")
        XCTAssertEqual(SettingsCategorySummary.accounts(accountCount: 12, groupCount: 3), "12 accounts · 3 groups")
    }

    func testDashboardSummaryRetainsExactPreferenceText() {
        XCTAssertEqual(SettingsCategorySummary.dashboard(
            appearance: .dark, ordering: .smart, refreshInterval: .fifteenMinutes,
            historySamplingInterval: .twoHours
        ), "Dark · Smart · 15 min refresh · 2 hours history")
    }

    func testAlertSummariesRetainIndependentUsageAndStatusChoices() {
        let expected = [
            "Off", "GitHub status on", "On · Warning 75% · Critical 90%",
            "On · Warning 75% · Critical 90% · GitHub status on",
        ]
        var index = 0
        for usage in [false, true] {
            for status in [false, true] {
                XCTAssertEqual(SettingsCategorySummary.alerts(
                    isEnabled: usage, githubStatusEnabled: status,
                    warningThreshold: 0.75, criticalThreshold: 0.90
                ), expected[index])
                index += 1
            }
        }
    }

    func testAlertSummaryKeepsOriginalRounding() {
        XCTAssertEqual(SettingsCategorySummary.alerts(
            isEnabled: true, warningThreshold: 0.754, criticalThreshold: 0.906
        ), "On · Warning 75% · Critical 91%")
    }

    func testHelpSummaryDistinguishesNilFromReportedEmptyVersion() {
        XCTAssertEqual(SettingsCategorySummary.help(installedVersion: "Version 1.4.0", availableVersion: nil), "Version 1.4.0")
        XCTAssertEqual(SettingsCategorySummary.help(installedVersion: "Version 1.4.0", availableVersion: "1.5"), "Version 1.5 available")
        XCTAssertEqual(SettingsCategorySummary.help(installedVersion: "Version 1.4.0", availableVersion: ""), "Version  available")
    }

    func testPreferenceUpdateChangesOnlySelectedNotificationKind() {
        let original = GitHubStatusSettings(
            isEnabled: true, pollingInterval: .oneHour, showsInAppBanner: false,
            sendsIncidentNotifications: false, sendsRecoveryNotifications: true
        )
        var incidentExpected = original
        incidentExpected.sendsIncidentNotifications = true
        XCTAssertEqual(GitHubStatusNotificationPreference.incident.updating(original, isEnabled: true), incidentExpected)
        var recoveryExpected = original
        recoveryExpected.sendsRecoveryNotifications = false
        XCTAssertEqual(GitHubStatusNotificationPreference.recovery.updating(original, isEnabled: false), recoveryExpected)
        XCTAssertFalse(original.sendsIncidentNotifications)
        XCTAssertTrue(original.sendsRecoveryNotifications)
    }

    func testRequestsStartIndependentAndGrantClearsOnlyItsPendingState() {
        var state = GitHubStatusNotificationAuthorization()
        let incident = state.begin(.incident)
        let recovery = state.begin(.recovery)
        XCTAssertNotEqual(incident.id, recovery.id)
        XCTAssertTrue(state.isPending(.incident))
        XCTAssertTrue(state.isPending(.recovery))
        XCTAssertEqual(state.complete(incident, granted: true), true)
        XCTAssertFalse(state.isPending(.incident))
        XCTAssertTrue(state.isPending(.recovery))
        XCTAssertEqual(state.complete(recovery, granted: true), true)
        XCTAssertFalse(state.isPending(.recovery))
    }

    func testDeniedOrFailedAuthorizationReturnsFalseNotAnObsoleteResult() {
        for preference in [GitHubStatusNotificationPreference.incident, .recovery] {
            var state = GitHubStatusNotificationAuthorization()
            let request = state.begin(preference)
            XCTAssertEqual(state.complete(request, granted: false), false)
            XCTAssertFalse(state.isPending(preference))
            XCTAssertEqual(GitHubStatusNotificationAuthorization.permissionMessage(granted: false), "Notifications are disabled for CodexBar.")
            XCTAssertNil(GitHubStatusNotificationAuthorization.permissionMessage(granted: true))
        }
    }

    func testDisabledToggleRejectsLateGrantedAndDeniedCompletions() {
        for granted in [false, true] {
            var state = GitHubStatusNotificationAuthorization()
            let request = state.begin(.incident)
            state.cancel(.incident)
            XCTAssertNil(state.complete(request, granted: granted))
            XCTAssertFalse(state.isPending(.incident))
        }
    }

    func testCancelingOnePreferenceDoesNotCancelTheOther() {
        var state = GitHubStatusNotificationAuthorization()
        let incident = state.begin(.incident)
        let recovery = state.begin(.recovery)
        state.cancel(.recovery)
        XCTAssertNil(state.complete(recovery, granted: true))
        XCTAssertTrue(state.isPending(.incident))
        XCTAssertEqual(state.complete(incident, granted: false), false)
    }

    func testMonitoringDisabledRejectsBothInFlightCompletions() {
        var state = GitHubStatusNotificationAuthorization()
        let incident = state.begin(.incident)
        let recovery = state.begin(.recovery)
        state.cancelAll()
        XCTAssertNil(state.complete(incident, granted: true))
        XCTAssertNil(state.complete(recovery, granted: false))
        XCTAssertFalse(state.isPending(.incident))
        XCTAssertFalse(state.isPending(.recovery))
    }

    func testNewRequestSupersedesOldResultWithoutClearingCurrentRequest() {
        var state = GitHubStatusNotificationAuthorization()
        let old = state.begin(.recovery)
        let current = state.begin(.recovery)
        XCTAssertNotEqual(old.id, current.id)
        XCTAssertNil(state.complete(old, granted: true))
        XCTAssertTrue(state.isPending(.recovery))
        XCTAssertEqual(state.complete(current, granted: false), false)
    }

    func testACompletionCanBeConsumedOnlyOnce() {
        var state = GitHubStatusNotificationAuthorization()
        let request = state.begin(.incident)
        XCTAssertEqual(state.complete(request, granted: true), true)
        XCTAssertNil(state.complete(request, granted: false))
    }

    func testIndependentStateDoesNotAcceptAnotherViewsRequest() {
        var first = GitHubStatusNotificationAuthorization()
        var second = GitHubStatusNotificationAuthorization()
        let request = first.begin(.incident)
        _ = second.begin(.incident)
        XCTAssertNil(second.complete(request, granted: true))
        XCTAssertTrue(second.isPending(.incident))
        XCTAssertEqual(first.complete(request, granted: true), true)
    }

    func testCompletionUpdatesLatestPreferencesNotTheStartSnapshot() {
        var state = GitHubStatusNotificationAuthorization()
        let request = state.begin(.incident)
        var latest = GitHubStatusSettings()
        latest.pollingInterval = .fifteenMinutes
        latest.showsInAppBanner = false
        latest.sendsRecoveryNotifications = true
        let granted = state.complete(request, granted: true)
        XCTAssertEqual(granted, true)
        let updated = request.preference.updating(latest, isEnabled: granted == true)
        XCTAssertEqual(updated.pollingInterval, .fifteenMinutes)
        XCTAssertFalse(updated.showsInAppBanner)
        XCTAssertTrue(updated.sendsRecoveryNotifications)
        XCTAssertTrue(updated.sendsIncidentNotifications)
    }
}
