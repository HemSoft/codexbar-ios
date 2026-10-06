import Foundation

public struct GreptileAllowanceRenewal: Equatable, Sendable {
    public let renewsAt: Date?
    public let observedAt: Date
    public var isStale: Bool
    public let unavailableReason: String?
    public var requiresAuthentication: Bool
    public let lookupFailed: Bool
    public let isApplicable: Bool?

    public init(
        renewsAt: Date?, observedAt: Date, isStale: Bool = false, unavailableReason: String? = nil,
        requiresAuthentication: Bool = false, lookupFailed: Bool = false, isApplicable: Bool? = true
    ) {
        self.renewsAt = renewsAt
        self.observedAt = observedAt
        self.isStale = isStale
        self.unavailableReason = unavailableReason
        self.requiresAuthentication = requiresAuthentication
        self.lookupFailed = lookupFailed
        self.isApplicable = isApplicable
    }

    public func status(at now: Date) -> String {
        guard let renewsAt else { return "Renewal date unavailable" }
        if isStale || now.timeIntervalSince(observedAt) > 86_400 { return "Last known renewal date" }
        if renewsAt <= now { return "Period ended. Refresh for the next renewal." }
        let minutes = max(1, Int(ceil(renewsAt.timeIntervalSince(now) / 60)))
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        if days > 0 { return "Renews in \(days)d \(hours)h" }
        if hours > 0 { return "Renews in \(hours)h \(minutes % 60)m" }
        return "Renews in \(minutes)m"
    }

    public var localDateText: String? {
        renewsAt?.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().timeZone(.specificName(.short)))
    }
}
