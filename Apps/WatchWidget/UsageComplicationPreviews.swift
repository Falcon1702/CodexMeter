import SwiftUI
import WidgetKit
import WatchUI

#Preview("Ein Account", as: .accessoryRectangular) {
    UsageComplicationWidget()
} timeline: {
    UsageTimelineEntry(
        date: UsagePreviewData.generatedAt,
        snapshot: UsagePreviewData.snapshot(accountCount: 1)
    )
}

#Preview("Zwei Accounts", as: .accessoryRectangular) {
    UsageComplicationWidget()
} timeline: {
    UsageTimelineEntry(
        date: UsagePreviewData.generatedAt,
        snapshot: UsagePreviewData.snapshot(accountCount: 2)
    )
}

#Preview("Drei Accounts", as: .accessoryRectangular) {
    UsageComplicationWidget()
} timeline: {
    UsageTimelineEntry(
        date: UsagePreviewData.generatedAt,
        snapshot: UsagePreviewData.snapshot(accountCount: 3)
    )
}
