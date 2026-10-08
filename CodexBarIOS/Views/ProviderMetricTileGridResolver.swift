import Foundation

struct MetricLayoutCopyDestination: Identifiable, Equatable {
    let id: String
    let title: String
    let availableMetricIDs: [String]
    let hasCustomLayout: Bool
}

enum ProviderMetricTileResolvedWidth: Equatable, Sendable {
    case half
    case full
}

extension MetricVisualizationStyle {
    var showsStandaloneMetricTileValue: Bool {
        self != .semicircularDial
    }
}

struct ProviderMetricTileGridItem: Identifiable, Equatable, Sendable {
    let metric: ProviderUsageMetric
    let width: ProviderMetricTileResolvedWidth

    var id: String { metric.id }
}

struct ProviderMetricTileGridRow: Identifiable, Equatable, Sendable {
    let leading: ProviderMetricTileGridItem
    let trailing: ProviderMetricTileGridItem?

    var id: String {
        [leading.id, trailing?.id].compactMap { $0 }.joined(separator: "|")
    }
}

enum ProviderMetricTileGridResolver {
    static func resolvedWidth(
        preference: MetricTileWidthPreference,
        kind: ProviderUsageMetricKind,
        visualizationStyle: MetricVisualizationStyle,
        usesRegularHorizontalSizeClass: Bool,
        collapsesToSingleColumn: Bool
    ) -> ProviderMetricTileResolvedWidth {
        if collapsesToSingleColumn {
            return .full
        }

        switch preference {
        case .half:
            return .half
        case .full:
            return .full
        case .automatic:
            break
        }

        switch kind {
        case .creditsRemaining, .monetary:
            return .half
        case .usageBar, .unavailableUsage:
            switch visualizationStyle {
            case .circularRing, .semicircularDial, .largeNumeric:
                return .half
            case .automatic:
                return usesRegularHorizontalSizeClass ? .half : .full
            case .linearBar, .segmentedBar:
                return .full
            }
        }
    }

    static func rows(
        metrics: [ProviderUsageMetric],
        orderedMetricIDs: [String],
        widthForMetric: (String) -> MetricTileWidthPreference,
        visualizationStyleForMetric: (String) -> MetricVisualizationStyle,
        usesRegularHorizontalSizeClass: Bool,
        collapsesToSingleColumn: Bool
    ) -> [ProviderMetricTileGridRow] {
        let metricsByID = Dictionary(metrics.map { ($0.id, $0) }) { first, _ in first }
        var seen = Set<String>()
        let orderedMetrics = orderedMetricIDs.compactMap { metricID -> ProviderUsageMetric? in
            guard seen.insert(metricID).inserted else {
                return nil
            }
            return metricsByID[metricID]
        } + metrics.filter { seen.insert($0.id).inserted }

        let items = orderedMetrics.map { metric in
            ProviderMetricTileGridItem(
                metric: metric,
                width: resolvedWidth(
                    preference: widthForMetric(metric.id),
                    kind: metric.kind,
                    visualizationStyle: visualizationStyleForMetric(metric.id),
                    usesRegularHorizontalSizeClass: usesRegularHorizontalSizeClass,
                    collapsesToSingleColumn: collapsesToSingleColumn
                )
            )
        }

        var rows: [ProviderMetricTileGridRow] = []
        var unmatchedHalf: ProviderMetricTileGridItem?
        for item in items {
            switch item.width {
            case .full:
                if let pendingHalf = unmatchedHalf {
                    rows.append(ProviderMetricTileGridRow(leading: pendingHalf, trailing: nil))
                }
                unmatchedHalf = nil
                rows.append(ProviderMetricTileGridRow(leading: item, trailing: nil))
            case .half:
                if let pendingHalf = unmatchedHalf {
                    rows.append(ProviderMetricTileGridRow(leading: pendingHalf, trailing: item))
                    unmatchedHalf = nil
                } else {
                    unmatchedHalf = item
                }
            }
        }
        if let unmatchedHalf {
            rows.append(ProviderMetricTileGridRow(leading: unmatchedHalf, trailing: nil))
        }
        return rows
    }
}

enum ProviderMetricTileOrderResolver {
    static func moving(
        _ metricID: String,
        toward targetMetricID: String,
        in metricIDs: [String]
    ) -> [String]? {
        guard
            metricID != targetMetricID,
            let sourceIndex = metricIDs.firstIndex(of: metricID),
            let targetIndex = metricIDs.firstIndex(of: targetMetricID)
        else {
            return nil
        }

        var reorderedMetricIDs = metricIDs
        reorderedMetricIDs.remove(at: sourceIndex)
        reorderedMetricIDs.insert(
            metricID,
            at: min(targetIndex, reorderedMetricIDs.endIndex)
        )
        return reorderedMetricIDs
    }
}
