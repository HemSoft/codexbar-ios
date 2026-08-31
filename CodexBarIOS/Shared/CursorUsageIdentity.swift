enum CursorUsageIdentity {
    static let cursorModelsStableKey = "cursor-models"
    static let otherModelsStableKey = "other-models"
    static let cursorModelsMetricID = "cursor.\(cursorModelsStableKey)"
    static let otherModelsMetricID = "cursor.\(otherModelsStableKey)"

    static let legacyCursorModelsStableKey = "auto"
    static let legacyOtherModelsStableKey = "api"
    static let legacyCursorModelsMetricID = "cursor.\(legacyCursorModelsStableKey)"
    static let legacyOtherModelsMetricID = "cursor.\(legacyOtherModelsStableKey)"

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
