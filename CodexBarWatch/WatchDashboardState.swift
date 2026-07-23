import Foundation

struct WatchUsageSample: Equatable, Identifiable, Sendable {
    let id: String
    let providerName: String
    let accountLabel: String
    let usedFraction: Double

    var clampedUsedFraction: Double {
        min(max(usedFraction, 0), 1)
    }

    var percentageText: String {
        "\(Int((clampedUsedFraction * 100).rounded()))%"
    }

    var accessibilitySummary: String {
        "\(providerName), \(accountLabel), \(percentageText) used"
    }
}

struct WatchDashboardState: Equatable, Sendable {
    let title: String
    let statusText: String
    let samples: [WatchUsageSample]

    var samplesByHighestUsage: [WatchUsageSample] {
        samples.sorted {
            if $0.clampedUsedFraction == $1.clampedUsedFraction {
                return $0.providerName < $1.providerName
            }
            return $0.clampedUsedFraction > $1.clampedUsedFraction
        }
    }

    static let sample = WatchDashboardState(
        title: "CodexBar",
        statusText: "Sample data",
        samples: [
            WatchUsageSample(
                id: "codex-primary",
                providerName: "Codex",
                accountLabel: "Primary",
                usedFraction: 0.72
            ),
            WatchUsageSample(
                id: "copilot-work",
                providerName: "Copilot",
                accountLabel: "Work",
                usedFraction: 0.38
            ),
        ]
    )
}
