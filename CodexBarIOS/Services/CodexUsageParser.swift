import Foundation

public enum CodexUsageParser {
    public static func parse(_ data: Data, fetchedAt: Date = Date()) -> ProviderUsageResult? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rateLimit = root["rate_limit"] as? [String: Any]
        else {
            return nil
        }

        var windows: [CodexUsageWindow] = []
        addWindow(named: "primary_window", from: rateLimit, to: &windows)
        addWindow(named: "secondary_window", from: rateLimit, to: &windows)

        guard !windows.isEmpty else {
            return nil
        }

        windows.sort { $0.durationSeconds < $1.durationSeconds }
        let bars = windows.map { window in
            let usedFraction = window.usedPercent / 100
            return UsageBar(
                label: label(forDuration: window.durationSeconds),
                used: window.usedPercent,
                limit: 100,
                resetDescription: formatReset(window.resetsAt, now: fetchedAt),
                resetsAt: window.resetsAt,
                projectionCurrent: usedFraction,
                projectionLimit: 1,
                projectionPeriodStart: window.resetsAt.addingTimeInterval(TimeInterval(-window.durationSeconds)),
                projectionPeriodEnd: window.resetsAt,
                showProjectionOnCurrentBar: true
            )
        }

        return ProviderUsageResult(
            providerID: .codex,
            title: formatDisplayName(planType: root["plan_type"] as? String),
            subtitle: "Live ChatGPT usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func addWindow(named name: String, from rateLimit: [String: Any], to windows: inout [CodexUsageWindow]) {
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
                durationSeconds: durationSeconds
            )
        )
    }

    private static func label(forDuration durationSeconds: Int) -> String {
        switch durationSeconds {
        case 18_000:
            "5 hour usage limit"
        case 604_800:
            "Weekly usage limit"
        default:
            "\(max(1, durationSeconds / 3_600)) hour usage limit"
        }
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

    private static func formatDisplayName(planType: String?) -> String {
        guard let planType, !planType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ProviderID.codex.displayName
        }

        return "\(ProviderID.codex.displayName) (\(formatPlanName(planType)))"
    }

    private static func formatPlanName(_ planType: String) -> String {
        switch planType.lowercased() {
        case "free":
            "Free"
        case "plus":
            "Plus"
        case "pro", "prolite":
            "Pro"
        case "team":
            "Team"
        case "enterprise":
            "Enterprise"
        default:
            planType
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
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
}

private struct CodexUsageWindow {
    let usedPercent: Double
    let resetsAt: Date
    let durationSeconds: Int
}
