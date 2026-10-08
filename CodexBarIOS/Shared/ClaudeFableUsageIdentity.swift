/// Shared identity for documented Fable names and choices saved before normalization.
enum ClaudeFableUsageIdentity {
    static let stableKey = "weekly-scoped-fable"
    static let metricID = "claude.\(stableKey)"
    static let modelNames = ["fable", "fable 5", "fable 5.1", "claude fable", "claude fable 5", "claude fable 5.1"]
    static let legacyStableKeys = modelNames.map {
        "weekly-scoped-\($0.filter { $0.isLetter || $0.isNumber })"
    }.filter { $0 != stableKey }

    static func canonicalStableKey(_ key: String) -> String {
        legacyStableKeys.contains(key) ? stableKey : key
    }

    static func replacementMetricID(for savedID: String) -> String? {
        legacyStableKeys.contains(where: { savedID == "claude.\($0)" }) ? metricID : nil
    }

    /// A Fable-labelled choice must never substitute another quota by position.
    /// Unknown Fable names can still match their own reported identity.
    static func requiresWidgetIdentityMatch(_ suffix: String) -> Bool {
        (suffix.hasPrefix("fable-") || suffix.hasPrefix("claude-fable-"))
            && (suffix.hasSuffix("-weekly-limit") || suffix.hasSuffix("-weekly-usage-limit"))
    }

    static func canonicalWidgetSuffix(_ suffix: String) -> String {
        let legacyNames = ["fable-5", "fable-5-1", "claude-fable", "claude-fable-5", "claude-fable-5-1"]
        for name in legacyNames {
            if suffix == "\(name)-weekly-limit" || suffix == "\(name)-weekly-usage-limit" {
                return "fable-weekly-usage-limit"
            }
        }
        return suffix
    }
}
