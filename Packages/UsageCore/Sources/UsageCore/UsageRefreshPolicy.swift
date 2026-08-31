import Foundation

/// Shared refresh timing for the iPhone app and both WidgetKit extensions.
///
/// `backgroundRefreshEarliestInterval` is only a request to iOS. The system
/// owns the actual launch time and may run the task substantially later.
public enum UsageRefreshPolicy {
    public static let foregroundRefreshInterval: TimeInterval = 5 * 60
    public static let widgetCacheReloadInterval: TimeInterval = 5 * 60
    public static let backgroundRefreshEarliestInterval: TimeInterval = 15 * 60

    public static func backgroundEarliestBeginDate(after date: Date) -> Date {
        date.addingTimeInterval(backgroundRefreshEarliestInterval)
    }

    public static func widgetCacheDeadline(
        from date: Date,
        scheduledReloadDate: Date
    ) -> Date {
        min(
            scheduledReloadDate,
            date.addingTimeInterval(widgetCacheReloadInterval)
        )
    }
}
