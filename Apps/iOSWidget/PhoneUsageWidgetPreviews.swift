import SwiftUI
import WatchUI
import WidgetKit

#Preview("Homescreen klein", as: .systemSmall) {
    PhoneUsageWidget()
} timeline: {
    PhoneUsageTimelineEntry(
        date: UsagePreviewData.generatedAt,
        snapshot: UsagePreviewData.snapshot(accountCount: 3)
    )
}

#Preview("Homescreen mittel", as: .systemMedium) {
    PhoneUsageWidget()
} timeline: {
    PhoneUsageTimelineEntry(
        date: UsagePreviewData.generatedAt,
        snapshot: UsagePreviewData.snapshot(accountCount: 3)
    )
}

#Preview("Sperrbildschirm", as: .accessoryRectangular) {
    PhoneUsageWidget()
} timeline: {
    PhoneUsageTimelineEntry(
        date: UsagePreviewData.generatedAt,
        snapshot: UsagePreviewData.snapshot(accountCount: 3)
    )
}
