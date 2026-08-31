import Foundation

public enum ResetCountdownFormatter {
    /// Compact watch-oriented rendering: `2d 3h`, `3h 18`, `0h 27`, or `jetzt`.
    /// Partial minutes round up so a future reset never appears to have elapsed.
    public static func string(until resetDate: Date, from referenceDate: Date) -> String {
        let interval = resetDate.timeIntervalSince(referenceDate)
        guard interval > 0 else { return "jetzt" }

        let totalMinutes = max(1, Int(ceil(interval / 60)))
        let days = totalMinutes / (24 * 60)
        let remainingMinutesAfterDays = totalMinutes % (24 * 60)
        let hours = remainingMinutesAfterDays / 60
        let minutes = remainingMinutesAfterDays % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        return "\(hours)h \(String(format: "%02d", minutes))"
    }

    /// App-facing spelling used by timeline and notification code.
    public static func string(until resetDate: Date, now: Date) -> String {
        string(until: resetDate, from: now)
    }
}
