import Foundation

public struct UsageBar: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let used: Double
    public let limit: Double
    public let resetsAt: Date?

    public init(id: UUID = UUID(), label: String, used: Double, limit: Double, resetsAt: Date? = nil) {
        self.id = id
        self.label = label
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
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
        "\(Int(used)) / \(Int(limit))"
    }
}
