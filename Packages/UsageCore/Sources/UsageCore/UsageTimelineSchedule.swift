import Foundation

/// A deterministic WidgetKit update schedule derived from a usage snapshot.
///
/// The type deliberately has no WidgetKit dependency so the cadence can be
/// shared and tested independently by every usage widget target.
public struct UsageTimelineSchedule: Equatable, Sendable {
    public let entryDates: [Date]
    public let reloadDate: Date

    /// Builds a schedule with five-minute entries while resets are distant and
    /// one-minute entries during the final 30 minutes before a reset.
    public init(now: Date, snapshot: UsageSnapshot?) {
        let fallbackReloadDate = now.addingTimeInterval(Self.maximumScheduleDuration)

        guard let snapshot, !snapshot.accounts.isEmpty else {
            self.init(
                entryDates: [now],
                reloadDate: now.addingTimeInterval(Self.missingResetRetryInterval)
            )
            return
        }

        let futureResetDates = snapshot.accounts
            .map(\.resetsAt)
            .filter { $0 > now }
            .sorted()

        guard let firstResetDate = futureResetDates.first else {
            self.init(
                entryDates: [now],
                reloadDate: now.addingTimeInterval(Self.missingResetRetryInterval)
            )
            return
        }

        let reloadDate = min(
            fallbackReloadDate,
            firstResetDate.addingTimeInterval(Self.postResetReloadDelay)
        )
        var dates = [now]
        var cursor = now

        while cursor < reloadDate {
            let nextReset = futureResetDates.first { $0 > cursor }
            let cadence = if let nextReset,
                             nextReset.timeIntervalSince(cursor) <= Self.minuteCadenceWindow {
                Self.minuteCadence
            } else {
                Self.standardCadence
            }

            var nextDate = min(cursor.addingTimeInterval(cadence), reloadDate)
            if let nextReset {
                let minuteCadenceStart = nextReset.addingTimeInterval(-Self.minuteCadenceWindow)
                if minuteCadenceStart > cursor, minuteCadenceStart < nextDate {
                    nextDate = minuteCadenceStart
                }
                if nextReset < nextDate {
                    nextDate = nextReset
                }
            }

            guard nextDate.timeIntervalSince(cursor) >= 0.5 else { break }
            dates.append(nextDate)
            cursor = nextDate
        }

        self.init(entryDates: dates, reloadDate: reloadDate)
    }

    private init(entryDates: [Date], reloadDate: Date) {
        self.entryDates = entryDates
        self.reloadDate = reloadDate
    }

    private static let minuteCadence: TimeInterval = 60
    private static let standardCadence: TimeInterval = 5 * 60
    private static let minuteCadenceWindow: TimeInterval = 30 * 60
    private static let missingResetRetryInterval: TimeInterval = 15 * 60
    private static let maximumScheduleDuration: TimeInterval = 60 * 60
    private static let postResetReloadDelay: TimeInterval = 60
}
