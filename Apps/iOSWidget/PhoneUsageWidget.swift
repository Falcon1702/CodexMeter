import SwiftUI
import WidgetKit

@main
struct PhoneUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PhoneWidgetShared.widgetKind,
            provider: PhoneUsageTimelineProvider()
        ) { entry in
            PhoneUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex Usage")
        .description("Zeigt Nutzung und Reset-Zeit für bis zu drei Codex-Accounts.")
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
