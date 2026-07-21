import Foundation

struct CodexBarWidgetTile: Identifiable {
    let id: String
    let providerID: String
    let providerTitle: String
    let title: String
    let subtitle: String
    let bar: CodexBarWidgetUsageBarSnapshot?
    let creditsRemaining: Double?
    let monetaryMetric: CodexBarWidgetMonetaryMetricSnapshot?
    let severity: CodexBarWidgetSeverity

    var choiceTitle: String {
        if bar != nil || monetaryMetric != nil {
            "\(providerTitle) - \(title)"
        } else {
            title
        }
    }

    var choiceSubtitle: String {
        if let bar {
            return "\(bar.usageText) used"
        }

        if let creditsRemaining {
            return CodexBarCurrencyText.format(creditsRemaining)
        }

        if let monetaryMetric {
            return monetaryMetric.formattedAmount
        }

        return subtitle
    }

    static func unavailable(choice: CodexBarWidgetTileChoice) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "unavailable.\(choice.id)",
            providerID: "unavailable",
            providerTitle: choice.title,
            title: choice.title,
            subtitle: "Open CodexBar to refresh this tile.",
            bar: nil,
            creditsRemaining: nil,
            monetaryMetric: nil,
            severity: .warning
        )
    }

    var monetaryValueText: String? {
        if let monetaryMetric {
            return monetaryMetric.formattedAmount
        }
        return creditsRemaining.map { CodexBarCurrencyText.format($0) }
    }
}

struct CodexBarWidgetRenderedTile: Identifiable {
    let tile: CodexBarWidgetTile
    let displayMode: CodexBarWidgetTileDisplayMode

    var id: String {
        "\(tile.id).\(displayMode.rawValue)"
    }
}

extension CodexBarWidgetSnapshot {
    func selectableTiles(
        group: CodexBarWidgetGroupChoice? = nil,
        focus: CodexBarWidgetFocus = .dashboardOrder
    ) -> [CodexBarWidgetTile] {
        scopedProviders(group: group, focus: focus).flatMap { provider in
            [provider.summaryTile]
                + provider.bars.map { provider.barTile($0) }
                + provider.standaloneMonetaryMetrics.map { provider.monetaryTile($0) }
        }
    }

    func scopedProviders(
        group: CodexBarWidgetGroupChoice? = nil,
        focus: CodexBarWidgetFocus = .dashboardOrder
    ) -> [CodexBarWidgetProviderSnapshot] {
        let groupFiltered: [CodexBarWidgetProviderSnapshot]
        if let selectedGroupID = group?.id {
            groupFiltered = results.filter { provider in
                (provider.groupID ?? CodexBarWidgetGroupChoice.ungroupedID) == selectedGroupID
            }
        } else {
            groupFiltered = results
        }

        return focus.providerID.map { providerID in
            groupFiltered.filter { $0.providerID == providerID }
        } ?? groupFiltered
    }

    var groupChoices: [CodexBarWidgetGroupChoice] {
        var choices: [CodexBarWidgetGroupChoice] = []
        var seenIDs = Set<String>()

        for provider in results {
            let id = provider.groupID ?? CodexBarWidgetGroupChoice.ungroupedID
            guard seenIDs.insert(id).inserted else {
                continue
            }

            choices.append(
                CodexBarWidgetGroupChoice(
                    id: id,
                    title: widgetGroupTitle(for: provider)
                )
            )
        }

        return choices.sorted {
            if $0.id == CodexBarWidgetGroupChoice.ungroupedID {
                return false
            }

            if $1.id == CodexBarWidgetGroupChoice.ungroupedID {
                return true
            }

            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func widgetGroupTitle(for provider: CodexBarWidgetProviderSnapshot) -> String {
        let title = provider.groupName ?? "Ungrouped"
        if provider.groupID != nil,
           title.localizedCaseInsensitiveCompare("Ungrouped") == .orderedSame
        {
            return "Ungrouped (group)"
        }

        return title
    }
}

extension CodexBarWidgetProviderSnapshot {
    var summaryTile: CodexBarWidgetTile {
        let summaryMetric = summaryMonetaryMetric
        return CodexBarWidgetTile(
            id: "provider.\(accountID)",
            providerID: providerID,
            providerTitle: title,
            title: summaryMetric?.label ?? (creditsRemaining == nil ? title : "\(title) Balance"),
            subtitle: summaryMetric?.detail ?? subtitle,
            bar: representativeBar,
            creditsRemaining: creditsRemaining,
            monetaryMetric: summaryMetric,
            severity: severity
        )
    }

    private var representativeBar: CodexBarWidgetUsageBarSnapshot? {
        bars.max { lhs, rhs in
            if lhs.effectiveSeverity == rhs.effectiveSeverity {
                return lhs.effectiveFractionUsed < rhs.effectiveFractionUsed
            }

            return lhs.effectiveSeverity < rhs.effectiveSeverity
        }
    }

    func barTile(_ bar: CodexBarWidgetUsageBarSnapshot) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "bar.\(bar.id)",
            providerID: providerID,
            providerTitle: title,
            title: bar.label,
            subtitle: subtitle,
            bar: bar,
            creditsRemaining: nil,
            monetaryMetric: nil,
            severity: bar.effectiveSeverity
        )
    }

    func monetaryTile(_ metric: CodexBarWidgetMonetaryMetricSnapshot) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "money.\(accountID).\(metric.id)",
            providerID: providerID,
            providerTitle: title,
            title: metric.label,
            subtitle: metric.detail ?? subtitle,
            bar: nil,
            creditsRemaining: nil,
            monetaryMetric: metric,
            severity: severity
        )
    }
}

func summary(for tile: CodexBarWidgetTile) -> String {
    if let monetaryValueText = tile.monetaryValueText {
        return monetaryValueText
    }

    return tile.bar.map(metricText(for:)) ?? "No data"
}

func metricText(for bar: CodexBarWidgetUsageBarSnapshot) -> String {
    guard
        let projectedFraction = bar.projectedFraction,
        bar.effectiveSeverity > bar.severity
    else {
        return bar.usageText
    }

    return "Proj \(Int((projectedFraction * 100).rounded()))%"
}
