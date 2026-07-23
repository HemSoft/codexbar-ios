import WidgetKit
import SwiftUI

@main
struct CodexBarIOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexBarIOSWidget()
    }
}

struct CodexBarIOSWidget: Widget {
    let kind = CodexBarWidgetConstants.widgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CodexBarWidgetConfigurationIntent.self,
            provider: CodexBarWidgetProvider()
        ) { entry in
            CodexBarWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar")
        .description("Track AI provider usage from the Home Screen and Lock Screen.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}
