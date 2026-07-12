import Foundation

public enum ProviderMonetaryMetricKind: String, Codable, Equatable, Sendable {
    case balance
    case spent
    case spendLimit
    case remainingHeadroom
}

public struct ProviderMonetaryMetric: Identifiable, Codable, Equatable, Sendable {
    public let kind: ProviderMonetaryMetricKind
    public let label: String
    public let minorUnits: Decimal
    public let currencyCode: String
    public let decimalPlaces: Int
    public let detail: String?

    public init(
        kind: ProviderMonetaryMetricKind,
        label: String,
        minorUnits: Decimal,
        currencyCode: String,
        decimalPlaces: Int,
        detail: String? = nil
    ) {
        self.kind = kind
        self.label = label
        self.minorUnits = max(minorUnits, 0)
        self.currencyCode = currencyCode.uppercased()
        self.decimalPlaces = min(max(decimalPlaces, 0), 6)
        self.detail = detail
    }

    public var id: String {
        "\(kind.rawValue).\(label).\(currencyCode)"
    }

    public var amount: Decimal {
        var divisor = Decimal(1)
        for _ in 0..<decimalPlaces {
            divisor *= 10
        }
        return minorUnits / divisor
    }

    public func formattedAmount(locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = decimalPlaces
        formatter.maximumFractionDigits = decimalPlaces
        return formatter.string(from: NSDecimalNumber(decimal: amount))
            ?? "\(currencyCode) \(NSDecimalNumber(decimal: amount).stringValue)"
    }
}

public struct ProviderUsageResult: Identifiable, Equatable, Sendable {
    public let accountID: String
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [ProviderMonetaryMetric]
    public let usageMessages: [String]
    public let fetchedAt: Date

    public init(
        accountID: String? = nil,
        providerID: ProviderID,
        title: String,
        subtitle: String,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        monetaryMetrics: [ProviderMonetaryMetric] = [],
        usageMessages: [String] = [],
        fetchedAt: Date
    ) {
        self.accountID = accountID ?? providerID.rawValue
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.monetaryMetrics = monetaryMetrics
        self.usageMessages = usageMessages
        self.fetchedAt = fetchedAt
    }

    public var id: String {
        accountID
    }

    public var highestSeverity: UsageSeverity {
        highestSeverity()
    }

    public func highestSeverity(at now: Date = Date()) -> UsageSeverity {
        bars.map { $0.effectiveSeverity(at: now) }.max() ?? .normal
    }
}
