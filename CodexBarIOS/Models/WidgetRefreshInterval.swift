import Foundation

public enum WidgetRefreshInterval: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case threeHours = 10_800

    public var id: Int {
        rawValue
    }

    public var seconds: TimeInterval {
        TimeInterval(rawValue)
    }

    public var displayName: String {
        switch self {
        case .fifteenMinutes:
            "15 min"
        case .thirtyMinutes:
            "30 min"
        case .oneHour:
            "1 hour"
        case .threeHours:
            "3 hours"
        }
    }
}
