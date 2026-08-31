import WidgetKit
import UsageCore
import WatchUI

struct UsageTimelineEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageTimelineEntry {
        UsageTimelineEntry(
            date: UsagePreviewData.generatedAt,
            snapshot: UsagePreviewData.snapshot()
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (UsageTimelineEntry) -> Void
    ) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(UsageTimelineEntry(date: .now, snapshot: WatchSnapshotStore.load()))
        }
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<UsageTimelineEntry>) -> Void
    ) {
        let now = Date()
        let snapshot = WatchSnapshotStore.load()
        let schedule = UsageTimelineSchedule(now: now, snapshot: snapshot)
        let freshnessDeadline = UsageRefreshPolicy.widgetCacheDeadline(
            from: now,
            scheduledReloadDate: schedule.reloadDate
        )
        let entries = schedule.entryDates
            .filter { $0 <= freshnessDeadline }
            .map {
                UsageTimelineEntry(date: $0, snapshot: snapshot)
            }

        // Every entry contains the snapshot that was current when this provider
        // ran. Keeping an hour of those entries makes percent and branding look
        // current while they are actually stale if WidgetKit coalesces an
        // explicit reload. Force a fresh App Group read after at most five
        // minutes; minute entries inside that window still update the countdown.
        completion(Timeline(entries: entries, policy: .after(freshnessDeadline)))
    }

}
