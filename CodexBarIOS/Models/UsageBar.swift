import Foundation

public struct UsageBar: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let used: Double
    public let limit: Double
    public let resetDescription: String?
    public let resetsAt: Date?
    public let projectionCurrent: Double?
    public let projectionLimit: Double?
    public let projectionPeriodStart: Date?
    public let projectionPeriodEnd: Date?
    public let showProjectionOnCurrentBar: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        used: Double,
        limit: Double,
        resetDescription: String? = nil,
        resetsAt: Date? = nil,
        projectionCurrent: Double? = nil,
        projectionLimit: Double? = nil,
        projectionPeriodStart: Date? = nil,
        projectionPeriodEnd: Date? = nil,
        showProjectionOnCurrentBar: Bool = false
    ) {
        self.id = id
        self.label = label
        self.used = used
        self.limit = limit
        self.resetDescription = resetDescription
        self.resetsAt = resetsAt
        self.projectionCurrent = projectionCurrent
        self.projectionLimit = projectionLimit
        self.projectionPeriodStart = projectionPeriodStart
        self.projectionPeriodEnd = projectionPeriodEnd
        self.showProjectionOnCurrentBar = showProjectionOnCurrentBar
    }

    public var fractionUsed: Double {
        guard limit > 0 else {
            return 0
        }

        return min(max(used / limit, 0), 1)
    }

    public var severity: UsageSeverity {
        UsageSeverity(fractionUsed: fractionUsed)
    }

    public var usageText: String {
        guard limit > 0 else {
            return "0%"
        }

        return "\(Int((used / limit * 100).rounded()))%"
    }

    public func projectedFraction(at now: Date = Date()) -> Double? {
        guard
            let projectionCurrent,
            let projectionLimit,
            let projectionPeriodStart,
            let projectionPeriodEnd,
            projectionCurrent > 0,
            projectionLimit > 0
        else {
            return nil
        }

        let projected = Self.projectedUsage(
            current: projectionCurrent,
            periodStart: projectionPeriodStart,
            periodEnd: projectionPeriodEnd,
            now: now
        )

        return min(max(projected / projectionLimit, 0), 1)
    }

    public func projectionDescription(at now: Date = Date()) -> String? {
        guard
            showProjectionOnCurrentBar,
            let projectionCurrent,
            let projectionLimit,
            let projectionPeriodStart,
            let projectionPeriodEnd,
            let projectedFraction = projectedFraction(at: now),
            projectedFraction > fractionUsed
        else {
            return nil
        }

        let limitHit = Self.formatLimitHit(
            current: projectionCurrent,
            limit: projectionLimit,
            periodStart: projectionPeriodStart,
            periodEnd: projectionPeriodEnd,
            now: now
        )

        guard limitHit != Self.limitNotReachedDescription else {
            return nil
        }

        return "Projected \(Int((projectedFraction * 100).rounded()))% at current pace - \(limitHit)"
    }

    private static let limitNotReachedDescription = "Limit not reached"

    private static func projectedUsage(current: Double, periodStart: Date, periodEnd: Date, now: Date) -> Double {
        let elapsed = now.timeIntervalSince(periodStart)
        if elapsed <= 0 || now >= periodEnd {
            return current
        }

        let total = periodEnd.timeIntervalSince(periodStart)
        return current * total / elapsed
    }

    public static func formatLimitHit(
        current: Double,
        limit: Double,
        periodStart: Date,
        periodEnd: Date,
        now: Date = Date()
    ) -> String {
        if current >= limit {
            return "Limit reached"
        }

        let elapsed = now.timeIntervalSince(periodStart)
        guard elapsed > 0 else {
            return "Limit hit unknown"
        }

        let ratePerSecond = current / elapsed
        guard ratePerSecond > 0 else {
            return "Limit hit unknown"
        }

        let secondsToLimit = limit / ratePerSecond
        let hitAt = periodStart.addingTimeInterval(secondsToLimit)
        if hitAt > periodEnd {
            return limitNotReachedDescription
        }

        let earlyDescription = hitAt < periodEnd
            ? " - \(formatEarlyDuration(periodEnd.timeIntervalSince(hitAt))) early"
            : ""

        return "Limit hit \(formatEasternTime(hitAt))\(earlyDescription)"
    }

    private static func formatEasternTime(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "EEE h:mm a"

        let abbreviation = formatter.timeZone.abbreviation(for: timestamp) ?? "ET"
        return "\(formatter.string(from: timestamp)) \(abbreviation)"
    }

    private static func formatEarlyDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []

        if days > 0 {
            parts.append("\(days)d")
        }

        if hours > 0 {
            parts.append("\(hours)h")
        }

        if minutes > 0 || parts.isEmpty {
            parts.append("\(minutes)m")
        }

        return parts.joined(separator: " ")
    }
}
