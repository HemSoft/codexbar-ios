import SwiftUI
import WidgetKit

@main
struct CodexBarWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexBarWatchUsageWidget()
    }
}

struct CodexBarWatchUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: WatchComplicationConstants.widgetKind,
            intent: WatchComplicationConfigurationIntent.self,
            provider: WatchComplicationTimelineProvider()
        ) { entry in
            WatchComplicationView(entry: entry)
        }
        .configurationDisplayName("CodexBar Usage")
        .description("See selected AI-provider usage and freshness at a glance.")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryCorner,
        ])
    }
}
