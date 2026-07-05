import Foundation

public enum ClaudeUsageParser {
    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOAuthApps: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOAuthApps = "seven_day_oauth_apps"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    public static func parse(
        _ data: Data,
        subscriptionType: String?,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return nil
        }

        var bars: [UsageBar] = []
        if let bar = usageBar(
            label: "5 hour usage limit",
            window: usage.fiveHour,
            durationSeconds: 18_000,
            fetchedAt: fetchedAt
        ) {
            bars.append(bar)
        }

        let weeklyWindow = usage.sevenDay
            ?? usage.sevenDayOAuthApps
            ?? usage.sevenDaySonnet
            ?? usage.sevenDayOpus
        if let bar = usageBar(
            label: "Weekly usage limit",
            window: weeklyWindow,
            durationSeconds: 604_800,
            fetchedAt: fetchedAt
        ) {
            bars.append(bar)
        }

        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: formatDisplayName(subscriptionType: subscriptionType),
            subtitle: "Live Claude usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    public static func parseRateLimitHeaders(
        _ fields: [AnyHashable: Any],
        subscriptionType: String?,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        var bars: [UsageBar] = []
        if let bar = usageBarFromHeaders(
            label: "5 hour usage limit",
            utilizationKey: "anthropic-ratelimit-unified-5h-utilization",
            resetKey: "anthropic-ratelimit-unified-5h-reset",
            durationSeconds: 18_000,
            fields: fields,
            fetchedAt: fetchedAt
        ) {
            bars.append(bar)
        }

        if let bar = usageBarFromHeaders(
            label: "Weekly usage limit",
            utilizationKey: "anthropic-ratelimit-unified-7d-utilization",
            resetKey: "anthropic-ratelimit-unified-7d-reset",
            durationSeconds: 604_800,
            fields: fields,
            fetchedAt: fetchedAt
        ) {
            bars.append(bar)
        }

        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: formatDisplayName(subscriptionType: subscriptionType),
            subtitle: "Live Claude usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func usageBar(
        label: String,
        window: UsageWindow?,
        durationSeconds: TimeInterval,
        fetchedAt: Date
    ) -> UsageBar? {
        guard
            let utilization = window?.utilization,
            let reset = parseReset(window?.resetsAt)
        else {
            return nil
        }

        return usageBar(
            label: label,
            utilization: utilization,
            reset: reset,
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt
        )
    }

    private static func usageBarFromHeaders(
        label: String,
        utilizationKey: String,
        resetKey: String,
        durationSeconds: TimeInterval,
        fields: [AnyHashable: Any],
        fetchedAt: Date
    ) -> UsageBar? {
        guard
            let utilization = doubleHeader(fields[utilizationKey]),
            let reset = epochHeader(fields[resetKey])
        else {
            return nil
        }

        return usageBar(
            label: label,
            utilization: utilization,
            reset: reset,
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt
        )
    }

    private static func usageBar(
        label: String,
        utilization: Double,
        reset: Date,
        durationSeconds: TimeInterval,
        fetchedAt: Date
    ) -> UsageBar {
        let usedFraction = min(max(utilization, 0), 1)
        return UsageBar(
            label: label,
            used: usedFraction * 100,
            limit: 100,
            resetDescription: formatReset(reset, now: fetchedAt),
            resetsAt: reset,
            projectionCurrent: usedFraction,
            projectionLimit: 1,
            projectionPeriodStart: reset.addingTimeInterval(-durationSeconds),
            projectionPeriodEnd: reset,
            showProjectionOnCurrentBar: true
        )
    }

    private static func parseReset(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        if let epoch = Double(value) {
            let seconds = epoch >= 1_000_000_000_000 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }

        return ISO8601DateFormatter().date(from: value)
    }

    private static func doubleHeader(_ value: Any?) -> Double? {
        if let value = value as? String {
            return Double(value)
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    private static func epochHeader(_ value: Any?) -> Date? {
        guard let rawValue = doubleHeader(value) else {
            return nil
        }

        let seconds = rawValue >= 1_000_000_000_000 ? rawValue / 1000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formatReset(_ resetAt: Date, now: Date) -> String {
        let remaining = resetAt.timeIntervalSince(now)
        let easternReset = formatEasternResetTime(resetAt, remaining: remaining)

        if remaining <= 0 {
            return "Resets now (\(easternReset))"
        }

        let relativeReset: String
        if remaining >= 86_400 {
            let days = Int(remaining / 86_400)
            let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3_600)
            relativeReset = "Resets \(days)d \(hours)h"
        } else if remaining >= 3_600 {
            let hours = Int(remaining / 3_600)
            let minutes = Int(remaining.truncatingRemainder(dividingBy: 3_600) / 60)
            relativeReset = "Resets \(hours)h \(minutes)m"
        } else {
            relativeReset = "Resets \(max(1, Int(remaining / 60)))m"
        }

        return "\(relativeReset) (\(easternReset))"
    }

    private static func formatEasternResetTime(_ resetAt: Date, remaining: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = remaining >= 86_400 ? "EEE h:mm a" : "h:mm a"

        let abbreviation = formatter.timeZone.abbreviation(for: resetAt) ?? "ET"
        return "\(formatter.string(from: resetAt)) \(abbreviation)"
    }

    private static func formatDisplayName(subscriptionType: String?) -> String {
        guard
            let subscriptionType,
            !subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ProviderID.claude.displayName
        }

        return "\(ProviderID.claude.displayName) (\(formatPlanName(subscriptionType)))"
    }

    private static func formatPlanName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
