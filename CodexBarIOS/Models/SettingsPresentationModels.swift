import Foundation

enum SettingsInitialRoute: Hashable {
    case accounts

    var destination: SettingsDestination {
        switch self {
        case .accounts:
            .accountsAndGroups
        }
    }
}

enum SettingsDestination: String, CaseIterable, Identifiable, Hashable {
    case accountsAndGroups
    case dashboard
    case alerts
    case widgets
    case helpAndAbout
    case dataAndRecovery

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .accountsAndGroups:
            "Accounts & Groups"
        case .dashboard:
            "Dashboard"
        case .alerts:
            "Alerts"
        case .widgets:
            "Widgets"
        case .helpAndAbout:
            "Help & About"
        case .dataAndRecovery:
            "Data & Recovery"
        }
    }

    var systemImage: String {
        switch self {
        case .accountsAndGroups:
            "person.2"
        case .dashboard:
            "rectangle.3.group"
        case .alerts:
            "bell"
        case .widgets:
            "square.grid.2x2"
        case .helpAndAbout:
            "questionmark.circle"
        case .dataAndRecovery:
            "externaldrive.badge.exclamationmark"
        }
    }
}

/// Data operations and preferences have separate, exhaustive summary/render interfaces.
enum SettingsContentRoute: Equatable {
    enum DataSection: Equatable {
        case accountsAndGroups
        case dataAndRecovery
    }

    enum PreferenceSection: Equatable {
        case dashboard
        case alerts
        case widgets
    }

    case data(DataSection)
    case preferences(PreferenceSection)
    case helpAndAbout

    static func resolve(_ destination: SettingsDestination) -> Self {
        let routes: [SettingsDestination: Self] = [
            .accountsAndGroups: .data(.accountsAndGroups),
            .dataAndRecovery: .data(.dataAndRecovery),
            .dashboard: .preferences(.dashboard),
            .alerts: .preferences(.alerts),
            .widgets: .preferences(.widgets),
            .helpAndAbout: .helpAndAbout,
        ]
        guard let route = routes[destination] else {
            preconditionFailure("Every Settings destination must declare its content route.")
        }
        return route
    }
}

enum SettingsCategorySummary {
    static func accounts(accountCount: Int, groupCount: Int) -> String {
        "\(count(accountCount, singular: "account")) · \(count(groupCount, singular: "group"))"
    }

    static func dashboard(
        appearance: AppAppearance,
        ordering: DashboardOrderingMode,
        refreshInterval: AutoRefreshInterval,
        historySamplingInterval: HistorySamplingInterval
    ) -> String {
        "\(appearance.displayName) · \(ordering.displayName) · \(refreshInterval.displayName) refresh · "
            + "\(historySamplingInterval.displayName) history"
    }

    static func alerts(
        isEnabled: Bool,
        githubStatusEnabled: Bool = false,
        warningThreshold: Double,
        criticalThreshold: Double
    ) -> String {
        guard isEnabled || githubStatusEnabled else {
            return "Off"
        }
        guard isEnabled else {
            return "GitHub status on"
        }
        let warningPercent = Int((warningThreshold * 100).rounded())
        let criticalPercent = Int((criticalThreshold * 100).rounded())
        let statusSuffix = githubStatusEnabled ? " · GitHub status on" : ""
        return "On · Warning \(warningPercent)% · Critical \(criticalPercent)%\(statusSuffix)"
    }

    static func help(installedVersion: String, availableVersion: String?) -> String {
        if let availableVersion {
            return "Version \(availableVersion) available"
        }
        return installedVersion
    }

    private static func count(_ value: Int, singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}
