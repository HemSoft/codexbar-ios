enum CursorUsageIdentity {
    static let cursorModelsStableKey = "cursor-models"
    static let otherModelsStableKey = "other-models"
    static let cursorModelsMetricID = "cursor.\(cursorModelsStableKey)"
    static let otherModelsMetricID = "cursor.\(otherModelsStableKey)"

    static let grokBotWeeklyStableKey = "grok-bot-weekly"
    static let onDemandStableKey = "on-demand"
    static let grokBotWeeklyMetricID = "cursor.\(grokBotWeeklyStableKey)"
    static let onDemandMetricID = "cursor.\(onDemandStableKey)"

    static let spendingChoices = [
        (key: cursorModelsStableKey, label: "Cursor Models"),
        (key: otherModelsStableKey, label: "Other Models"),
        (key: grokBotWeeklyStableKey, label: "Grok Bot weekly"),
        (key: onDemandStableKey, label: "On-demand spending"),
    ]

    static let legacyCursorModelsStableKey = "auto"
    static let legacyOtherModelsStableKey = "api"
    static let legacyTotalStableKey = "total"
    static let legacyCursorModelsMetricID = "cursor.\(legacyCursorModelsStableKey)"
    static let legacyOtherModelsMetricID = "cursor.\(legacyOtherModelsStableKey)"
    static let legacyTotalMetricID = "cursor.\(legacyTotalStableKey)"

    static func canonicalStableKey(_ stableKey: String) -> String {
        switch stableKey {
        case legacyCursorModelsStableKey:
            cursorModelsStableKey
        case legacyOtherModelsStableKey:
            otherModelsStableKey
        default:
            stableKey
        }
    }

    static func replacementMetricID(for metricID: String) -> String? {
        switch metricID {
        case legacyCursorModelsMetricID:
            cursorModelsMetricID
        case legacyOtherModelsMetricID:
            otherModelsMetricID
        default:
            nil
        }
    }

    static func canonicalMetricID(_ metricID: String) -> String {
        replacementMetricID(for: metricID) ?? metricID
    }
}
