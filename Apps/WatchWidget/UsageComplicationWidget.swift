import SwiftUI
import WidgetKit

@main
struct WatchOverlayWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageComplicationWidget()
    }
}

struct UsageComplicationWidget: Widget {
    static let kind = WatchOverlaySharedConstants.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider()) { entry in
            UsageComplicationView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("Codex Usage")
        .description("Zeigt verbleibende Nutzung und Reset-Zeit für bis zu drei Accounts.")
        .contentMarginsDisabled()
        .supportedFamilies([.accessoryRectangular])
    }
}
