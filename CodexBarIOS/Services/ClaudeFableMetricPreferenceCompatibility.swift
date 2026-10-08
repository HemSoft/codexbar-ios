import Foundation

/// Retain choices saved before documented Fable display names shared one metric identity.
enum ClaudeFableMetricPreferenceCompatibility {
    private static let destinationID = ClaudeUsageIdentity.fableWeeklyMetricID
    private static let legacyIDs = ClaudeUsageIdentity.legacyFableStableKeys.map { "claude.\($0)" }

    static func migrate(layout: inout AccountMetricLayout, availableMetricIDs: [String]) {
        let available = Set(availableMetricIDs)
        guard available.contains(destinationID), available.isDisjoint(with: legacyIDs) else { return }
        let sources = orderedSources(in: layout)
        if canReplaceDestination(layout.preferences[destinationID]),
           let sourceID = sources.first(where: { hasCustomPresentation(layout.preferences[$0]) }) ?? sources.first,
           var preference = layout.preferences[sourceID] {
            if let destination = layout.preferences[destinationID] {
                preference.isNewlyDiscovered = preference.isNewlyDiscovered && destination.isNewlyDiscovered
            }
            layout.preferences[destinationID] = preference
        }
        for id in legacyIDs { layout.preferences.removeValue(forKey: id) }
        let hasCanonicalOrder = layout.orderedMetricIDs.contains(destinationID)
        let replacements = layout.orderedMetricIDs.compactMap { id -> String? in
            guard legacyIDs.contains(id) else { return id }
            return hasCanonicalOrder ? nil : destinationID
        }
        var seen = Set<String>()
        layout.orderedMetricIDs = replacements.filter { seen.insert($0).inserted }
    }

    private static func orderedSources(in layout: AccountMetricLayout) -> [String] {
        var seen = Set<String>()
        return (layout.orderedMetricIDs + legacyIDs).filter {
            legacyIDs.contains($0) && layout.preferences[$0] != nil && seen.insert($0).inserted
        }
    }

    private static func canReplaceDestination(_ preference: MetricTilePreference?) -> Bool {
        guard let preference else { return true }
        return preference.isNewlyDiscovered && !hasCustomPresentation(preference)
    }

    private static func hasCustomPresentation(_ preference: MetricTilePreference?) -> Bool {
        guard let preference else { return false }
        return !preference.isVisible || preference.visualizationStyle != nil
            || preference.width != .automatic || preference.watchVisibility != .inherit
    }
}
