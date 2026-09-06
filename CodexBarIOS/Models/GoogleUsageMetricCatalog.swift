import Foundation

/// Known quota choices are independent of whether the latest fetch returned a value.
public enum GoogleUsageMetricCatalog {
    static let disabledReason = "Disabled"

    public struct Definition: Equatable, Sendable {
        public let key: String
        public let label: String
        public let window: String
    }

    public static func definitions(for providerID: ProviderID) -> [Definition] {
        switch providerID {
        case .gemini:
            [
                Definition(key: "five-hour", label: "Gemini Apps five-hour", window: "5h"),
                Definition(key: "weekly", label: "Gemini Apps weekly", window: "weekly"),
            ]
        case .antigravity:
            [
                Definition(key: "gemini-5h", label: "Gemini Models five-hour", window: "5h"),
                Definition(key: "gemini-weekly", label: "Gemini Models weekly", window: "weekly"),
                Definition(key: "3p-5h", label: "Other models five-hour", window: "5h"),
                Definition(key: "3p-weekly", label: "Other models weekly", window: "weekly"),
            ]
        default:
            []
        }
    }

    public static func metrics(
        for providerID: ProviderID,
        result: ProviderUsageResult? = nil,
        missingReason: String = "Setup required"
    ) -> [ProviderUsageMetric] {
        let matchingResult = result?.providerID == providerID ? result : nil
        let observed = matchingResult?.availableMetrics ?? []
        let definitions = definitions(for: providerID)
        let knownIDs = Set(definitions.map { "\(providerID.rawValue).\($0.key)" })
        return definitions.map { definition in
            let metricID = "\(providerID.rawValue).\(definition.key)"
            let unavailableReason = matchingResult?.unavailableUsageMetrics[metricID]
            let kind: ProviderUsageMetricKind
            if unavailableReason == disabledReason {
                kind = .unavailableUsage(disabledReason)
            } else {
                kind = observed.first { $0.id == metricID }?.kind
                    ?? .unavailableUsage(unavailableReason ?? missingReason)
            }
            return ProviderUsageMetric(id: metricID, label: definition.label, kind: kind)
        } + observed.filter { !knownIDs.contains($0.id) }
    }

    public static func setupDescription(for providerID: ProviderID) -> String? {
        switch providerID {
        case .gemini:
            "Gemini Apps has two usage limits. For the four Gemini Models and Other models limits shown by Antigravity CLI /usage, "
                + "connect an Antigravity account in Add Account."
        case .antigravity:
            "Four coding quotas: Gemini Models and Other models, each with a five-hour and weekly limit. "
                + "Other models includes Claude and GPT. Gemini Apps uses a separate account and two separate limits."
        default:
            nil
        }
    }
}
