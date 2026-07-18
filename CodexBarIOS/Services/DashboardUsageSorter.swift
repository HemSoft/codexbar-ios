import Foundation

public enum DashboardUsageSorter {
    public static func orderedResults(
        _ results: [ProviderUsageResult],
        mode: DashboardOrderingMode,
        manualOrder: [String],
        now: Date = Date()
    ) -> [ProviderUsageResult] {
        let manualIndexes = Dictionary(
            uniqueKeysWithValues: manualOrder.enumerated().map { index, accountID in
                (accountID, index)
            }
        )

        return results.enumerated()
            .sorted { lhs, rhs in
                switch mode {
                case .manual:
                    return manualSort(lhs, rhs, manualIndexes: manualIndexes)
                case .smart:
                    return smartSort(lhs, rhs, manualIndexes: manualIndexes, now: now)
                }
            }
            .map(\.element)
    }

    private static func manualSort(
        _ lhs: EnumeratedSequence<[ProviderUsageResult]>.Element,
        _ rhs: EnumeratedSequence<[ProviderUsageResult]>.Element,
        manualIndexes: [String: Int]
    ) -> Bool {
        let lhsOrder = manualIndexes[lhs.element.id] ?? Int.max
        let rhsOrder = manualIndexes[rhs.element.id] ?? Int.max
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }

        return lhs.offset < rhs.offset
    }

    private static func smartSort(
        _ lhs: EnumeratedSequence<[ProviderUsageResult]>.Element,
        _ rhs: EnumeratedSequence<[ProviderUsageResult]>.Element,
        manualIndexes: [String: Int],
        now: Date
    ) -> Bool {
        let lhsScore = SmartOrderingScore(result: lhs.element, originalOffset: lhs.offset, manualIndexes: manualIndexes, now: now)
        let rhsScore = SmartOrderingScore(result: rhs.element, originalOffset: rhs.offset, manualIndexes: manualIndexes, now: now)
        return lhsScore < rhsScore
    }
}

private struct SmartOrderingScore: Comparable {
    let severityRank: Int
    let balanceRank: BalanceRank
    let projectedLimitHitAt: Date?
    let projectedFractionRank: Double
    let manualIndex: Int
    let originalOffset: Int

    init(
        result: ProviderUsageResult,
        originalOffset: Int,
        manualIndexes: [String: Int],
        now: Date
    ) {
        let freshBars = result.freshBars
        severityRank = -result.highestSeverity(at: now).rawValue
        balanceRank = BalanceRank(creditsRemaining: result.creditsRemaining)
        projectedLimitHitAt = freshBars.compactMap { $0.projectedLimitHitAt(now: now) }.min()
        projectedFractionRank = -(freshBars.map { max($0.fractionUsed, $0.projectedFraction(at: now) ?? 0) }.max() ?? 0)
        manualIndex = manualIndexes[result.id] ?? Int.max
        self.originalOffset = originalOffset
    }

    static func < (lhs: SmartOrderingScore, rhs: SmartOrderingScore) -> Bool {
        if lhs.severityRank != rhs.severityRank {
            return lhs.severityRank < rhs.severityRank
        }

        if lhs.balanceRank != rhs.balanceRank {
            return lhs.balanceRank < rhs.balanceRank
        }

        if lhs.projectedLimitHitAt != rhs.projectedLimitHitAt {
            switch (lhs.projectedLimitHitAt, rhs.projectedLimitHitAt) {
            case let (lhsHit?, rhsHit?):
                return lhsHit < rhsHit
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
        }

        if lhs.projectedFractionRank != rhs.projectedFractionRank {
            return lhs.projectedFractionRank < rhs.projectedFractionRank
        }

        if lhs.manualIndex != rhs.manualIndex {
            return lhs.manualIndex < rhs.manualIndex
        }

        return lhs.originalOffset < rhs.originalOffset
    }
}

private enum BalanceRank: Comparable {
    case balance(Double)
    case none

    init(creditsRemaining: Double?) {
        if let creditsRemaining {
            self = .balance(max(creditsRemaining, 0))
        } else {
            self = .none
        }
    }

    static func < (lhs: BalanceRank, rhs: BalanceRank) -> Bool {
        switch (lhs, rhs) {
        case let (.balance(lhsCredits), .balance(rhsCredits)):
            return lhsCredits < rhsCredits
        case (.balance, .none):
            return true
        case (.none, .balance):
            return false
        case (.none, .none):
            return false
        }
    }
}

private extension UsageBar {
    func projectedLimitHitAt(now: Date) -> Date? {
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

        let elapsed = now.timeIntervalSince(projectionPeriodStart)
        guard elapsed > 0 else {
            return nil
        }

        let ratePerSecond = projectionCurrent / elapsed
        guard ratePerSecond > 0 else {
            return nil
        }

        let hitAt = projectionPeriodStart.addingTimeInterval(projectionLimit / ratePerSecond)
        guard hitAt <= projectionPeriodEnd else {
            return nil
        }

        return hitAt
    }
}
