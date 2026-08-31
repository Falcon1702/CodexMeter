import UsageCore
import WatchUI
import WidgetKit

struct PhoneUsageTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct PhoneUsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> PhoneUsageTimelineEntry {
        PhoneUsageTimelineEntry(
            date: UsagePreviewData.generatedAt,
            snapshot: UsagePreviewData.snapshot()
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (PhoneUsageTimelineEntry) -> Void
    ) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(
                PhoneUsageTimelineEntry(
                    date: .now,
                    snapshot: PhoneWidgetShared.loadSnapshot()
                )
            )
        }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<PhoneUsageTimelineEntry>) -> Void
    ) {
        let now = Date()
        let snapshot = PhoneWidgetShared.loadSnapshot()
        let schedule = UsageTimelineSchedule(now: now, snapshot: snapshot)
        let cacheDeadline = UsageRefreshPolicy.widgetCacheDeadline(
            from: now,
            scheduledReloadDate: schedule.reloadDate
        )
        let entries = schedule.entryDates
            .filter { $0 <= cacheDeadline }
            .map {
                PhoneUsageTimelineEntry(date: $0, snapshot: snapshot)
            }
        completion(Timeline(entries: entries, policy: .after(cacheDeadline)))
    }
}
