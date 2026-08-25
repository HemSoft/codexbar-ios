import CoreFoundation
import Foundation

public enum CodexUsageParser {
    private static let fiveHourDurationSeconds = 18_000
    private static let weeklyDurationSeconds = 604_800

    public static func parse(
        _ data: Data,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var windows: [CodexUsageWindow] = []
        if let rateLimit = root["rate_limit"] as? [String: Any] {
            addWindows(
                from: rateLimit,
                bucketStableKey: nil,
                bucketLabel: nil,
                bucketOrder: 0,
                to: &windows
            )
        }
        for key in root.keys.sorted() where key.hasSuffix("_rate_limit") && key != "rate_limit" {
            guard let rateLimit = root[key] as? [String: Any] else {
                continue
            }
            let identity = String(key.dropLast("_rate_limit".count))
            addWindows(
                from: rateLimit,
                bucketStableKey: "bucket-\(stableKeyComponent(identity) ?? "other")",
                bucketLabel: bucketLabel(from: identity),
                bucketOrder: 1,
                to: &windows
            )
        }
        for (index, rateLimit) in additionalRateLimits(from: root["additional_rate_limits"]).enumerated() {
            let identity = nonemptyString(rateLimit["metered_feature"])
                ?? nonemptyString(rateLimit["limit_id"])
                ?? nonemptyString(rateLimit["limit_name"])
            let stableComponent = identity.flatMap(stableKeyComponent) ?? "additional-\(index + 1)"
            let rateLimitWindows = rateLimit["rate_limit"] as? [String: Any] ?? rateLimit
            addWindows(
                from: rateLimitWindows,
                bucketStableKey: "bucket-\(stableComponent)",
                bucketLabel: nonemptyString(rateLimit["limit_name"]) ?? "Additional Codex usage",
                bucketOrder: 2,
                to: &windows
            )
        }
        let resetCredits = parseResetCredits(
            root["rate_limit_reset_credits"],
            canConsume: false,
            includesEmpty: false
        )

        guard !windows.isEmpty || resetCredits != nil else {
            return nil
        }

        windows.sort {
            if $0.bucketOrder != $1.bucketOrder {
                return $0.bucketOrder < $1.bucketOrder
            }
            if $0.bucketStableKey != $1.bucketStableKey {
                return ($0.bucketStableKey ?? "") < ($1.bucketStableKey ?? "")
            }
            if $0.durationSeconds != $1.durationSeconds {
                return $0.durationSeconds < $1.durationSeconds
            }
            return $0.windowOrder < $1.windowOrder
        }
        var stableKeyOccurrences: [String: Int] = [:]
        let bars = windows.map { window in
            let baseStableKey = stableKey(for: window)
            let occurrence = stableKeyOccurrences[baseStableKey, default: 0] + 1
            stableKeyOccurrences[baseStableKey] = occurrence
            let stableKey = occurrence == 1
                ? baseStableKey
                : "\(baseStableKey).duplicate-\(occurrence)"
            let usedFraction = window.usedPercent / 100
            return UsageBar(
                stableKey: stableKey,
                label: label(for: window),
                used: window.usedPercent,
                limit: 100,
                resetDescription: formatReset(
                    window.resetsAt,
                    now: fetchedAt,
                    dateTimeFormatter: dateTimeFormatter
                ),
                resetsAt: window.resetsAt,
                resetDisplayStyle: .relativeWithLocalTime,
                projectionCurrent: usedFraction,
                projectionLimit: 1,
                projectionPeriodStart: window.resetsAt.addingTimeInterval(TimeInterval(-window.durationSeconds)),
                projectionPeriodEnd: window.resetsAt,
                showProjectionOnCurrentBar: true
            )
        }
        return ProviderUsageResult(
            providerID: .codex,
            title: ProviderID.codex.displayName,
            plan: planDescriptor(planType: root["plan_type"] as? String),
            subtitle: "Live ChatGPT usage",
            bars: bars,
            usageMessages: [],
            codexBankedRateLimitResets: resetCredits,
            fetchedAt: fetchedAt
        )
    }

    public static func parseResetCredits(
        _ data: Data,
        canConsume: Bool
    ) -> CodexBankedRateLimitResets? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return parseResetCredits(root, canConsume: canConsume, includesEmpty: true)
    }

    private static func parseResetCredits(
        _ value: Any?,
        canConsume: Bool,
        includesEmpty: Bool
    ) -> CodexBankedRateLimitResets? {
        guard
            let dictionary = value as? [String: Any],
            let availableCount = nonnegativeInteger(dictionary["available_count"]),
            includesEmpty || availableCount > 0
        else {
            return nil
        }

        let credits = (dictionary["credits"] as? [[String: Any]])?.compactMap { credit -> CodexBankedRateLimitReset? in
            guard
                let id = nonemptyString(credit["id"]),
                nonemptyString(credit["status"])?.lowercased() == "available"
            else {
                return nil
            }

            return CodexBankedRateLimitReset(
                id: id,
                title: nonemptyString(credit["title"]),
                description: nonemptyString(credit["description"]),
                expiresAt: nonemptyString(credit["expires_at"]).flatMap(parseISO8601Date)
            )
        }

        return CodexBankedRateLimitResets(
            availableCount: availableCount,
            credits: credits,
            canConsume: canConsume
        )
    }

    private static func addWindows(
        from rateLimit: [String: Any],
        bucketStableKey: String?,
        bucketLabel: String?,
        bucketOrder: Int,
        to windows: inout [CodexUsageWindow]
    ) {
        addWindow(
            named: "primary_window",
            windowOrder: 0,
            from: rateLimit,
            bucketStableKey: bucketStableKey,
            bucketLabel: bucketLabel,
            bucketOrder: bucketOrder,
            to: &windows
        )
        addWindow(
            named: "secondary_window",
            windowOrder: 1,
            from: rateLimit,
            bucketStableKey: bucketStableKey,
            bucketLabel: bucketLabel,
            bucketOrder: bucketOrder,
            to: &windows
        )
    }

    private static func addWindow(
        named name: String,
        windowOrder: Int,
        from rateLimit: [String: Any],
        bucketStableKey: String?,
        bucketLabel: String?,
        bucketOrder: Int,
        to windows: inout [CodexUsageWindow]
    ) {
        guard
            let window = rateLimit[name] as? [String: Any],
            let usedPercent = doubleValue(window["used_percent"]),
            let resetEpoch = intValue(window["reset_at"]),
            let durationSeconds = intValue(window["limit_window_seconds"])
        else {
            return
        }

        windows.append(
            CodexUsageWindow(
                usedPercent: min(max(usedPercent, 0), 100),
                resetsAt: Date(timeIntervalSince1970: TimeInterval(resetEpoch)),
                durationSeconds: durationSeconds,
                bucketStableKey: bucketStableKey,
                bucketLabel: bucketLabel,
                bucketOrder: bucketOrder,
                windowOrder: windowOrder
            )
        )
    }

    private static func additionalRateLimits(from value: Any?) -> [[String: Any]] {
        if let rateLimits = value as? [Any] {
            return rateLimits.compactMap { $0 as? [String: Any] }
        }
        guard let rateLimits = value as? [String: Any] else {
            return []
        }
        return rateLimits.keys.sorted().compactMap { key in
            guard var rateLimit = rateLimits[key] as? [String: Any] else {
                return nil
            }
            if rateLimit["metered_feature"] == nil {
                rateLimit["metered_feature"] = key
            }
            return rateLimit
        }
    }

    private static func stableKeyComponent(_ value: String) -> String? {
        guard !value.isEmpty else {
            return nil
        }
        return value.utf8.map { byte in
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122:
                String(UnicodeScalar(byte))
            default:
                String(format: "_%02X", byte)
            }
        }.joined()
    }

    private static func bucketLabel(from identity: String) -> String {
        let words = identity
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard let first = words.first else {
            return "Other Codex usage"
        }
        return ([first.capitalized] + words.dropFirst().map { $0.lowercased() })
            .joined(separator: " ")
    }

    private static func stableKey(for window: CodexUsageWindow) -> String {
        let durationKey = "window-\(canonicalDuration(window.durationSeconds))"
        guard let bucketStableKey = window.bucketStableKey else {
            // Preserve the identifiers used by existing general Codex metrics.
            return durationKey
        }
        return "\(bucketStableKey).\(durationKey)"
    }

    private static func label(for window: CodexUsageWindow) -> String {
        let durationLabel = label(forDuration: window.durationSeconds)
        guard let bucketLabel = window.bucketLabel else {
            return durationLabel
        }
        return "\(bucketLabel) · \(durationLabel)"
    }

    private static func label(forDuration durationSeconds: Int) -> String {
        if isApproximateDuration(durationSeconds, expected: fiveHourDurationSeconds) {
            "5 hour usage limit"
        } else if isApproximateDuration(durationSeconds, expected: weeklyDurationSeconds) {
            "Weekly usage limit"
        } else if durationSeconds.isMultiple(of: 3_600) {
            "\(max(1, durationSeconds / 3_600)) hour usage limit"
        } else {
            "\(max(1, Int((Double(durationSeconds) / 60).rounded()))) minute usage limit"
        }
    }

    private static func canonicalDuration(_ durationSeconds: Int) -> Int {
        if isApproximateDuration(durationSeconds, expected: fiveHourDurationSeconds) {
            fiveHourDurationSeconds
        } else if isApproximateDuration(durationSeconds, expected: weeklyDurationSeconds) {
            weeklyDurationSeconds
        } else {
            durationSeconds
        }
    }

    private static func isApproximateDuration(_ durationSeconds: Int, expected: Int) -> Bool {
        let tolerance = Double(expected) * 0.05
        return abs(Double(durationSeconds - expected)) <= tolerance
    }

    private static func formatReset(
        _ resetAt: Date,
        now: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> String {
        dateTimeFormatter.resetDescription(
            resetAt: resetAt,
            now: now,
            style: .relativeWithLocalTime,
            fallback: nil
        ) ?? "Resets now"
    }

    private static func planDescriptor(planType: String?) -> ProviderPlanDescriptor? {
        guard let normalized = ProviderPlanDescriptor.normalizedPlanValue(planType) else {
            return nil
        }

        let identifier: String
        let label: String
        switch normalized {
        case "free":
            identifier = "free"
            label = "Free"
        case "go":
            identifier = "go"
            label = "Go"
        case "plus":
            identifier = "plus"
            label = "Plus"
        case "pro", "prolite":
            identifier = "pro"
            label = "Pro"
        case "business", "team":
            identifier = "business"
            label = "Business"
        case "enterprise":
            identifier = "enterprise"
            label = "Enterprise"
        case "edu":
            identifier = "edu"
            label = "Edu"
        case "health":
            identifier = "health"
            label = "Health"
        case "gov":
            identifier = "gov"
            label = "Gov"
        default:
            return nil
        }

        return ProviderPlanDescriptor.make(
            providerPrefix: "codex",
            identifier: identifier,
            label: label
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? Double {
            return Int(value)
        }

        if let value = value as? String {
            return Int(value)
        }

        return nil
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let doubleValue = number.doubleValue
        guard
            doubleValue.isFinite,
            doubleValue >= 0,
            doubleValue.rounded(.towardZero) == doubleValue,
            doubleValue <= Double(Int.max)
        else {
            return nil
        }
        return Int(doubleValue)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct CodexUsageWindow {
    let usedPercent: Double
    let resetsAt: Date
    let durationSeconds: Int
    let bucketStableKey: String?
    let bucketLabel: String?
    let bucketOrder: Int
    let windowOrder: Int
}
