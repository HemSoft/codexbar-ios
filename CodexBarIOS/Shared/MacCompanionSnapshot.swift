import Foundation

public struct MacCompanionMenuSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let menuTitle: String
    public let headline: String
    public let detail: String
    public let rows: [MacCompanionMenuRow]

    public init(snapshot: CodexBarWidgetSnapshot) {
        self.generatedAt = snapshot.generatedAt
        let rows = snapshot.results.map(MacCompanionMenuRow.init(provider:))
            .sorted(by: Self.sortRows)
        self.rows = rows

        if let first = rows.first {
            self.menuTitle = "\(first.shortTitle) \(first.value)"
            self.headline = first.title
            self.detail = first.subtitle
        } else {
            self.menuTitle = "CodexBar"
            self.headline = "No usage data"
            self.detail = "Open CodexBar to refresh"
        }
    }

    private static func sortRows(_ lhs: MacCompanionMenuRow, _ rhs: MacCompanionMenuRow) -> Bool {
        if lhs.severity != rhs.severity {
            return lhs.severity > rhs.severity
        }

        switch (lhs.balanceRemaining, rhs.balanceRemaining) {
        case let (lhs?, rhs?):
            if lhs != rhs {
                return lhs < rhs
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if lhs.usageFraction != rhs.usageFraction {
                return lhs.usageFraction > rhs.usageFraction
            }
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

public struct MacCompanionMenuRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let shortTitle: String
    public let subtitle: String
    public let value: String
    public let severity: CodexBarWidgetSeverity
    public let balanceRemaining: Double?
    public let usageFraction: Double

    public init(provider: CodexBarWidgetProviderSnapshot) {
        self.id = provider.accountID
        self.title = provider.title
        self.shortTitle = Self.shortTitle(provider.title)
        self.subtitle = provider.groupName ?? provider.subtitle
        self.severity = provider.severity
        self.balanceRemaining = provider.creditsRemaining
        self.usageFraction = provider.bars.map(\.effectiveFractionUsed).max() ?? 0

        if let creditsRemaining = provider.creditsRemaining {
            self.value = Self.currencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? "$0.00"
        } else if let bar = provider.bars.max(by: { $0.effectiveFractionUsed < $1.effectiveFractionUsed }) {
            self.value = bar.usageText
        } else {
            self.value = "No data"
        }
    }

    private static func shortTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "ChatGPT / ", with: "")
            .replacingOccurrences(of: "GitHub ", with: "")
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
