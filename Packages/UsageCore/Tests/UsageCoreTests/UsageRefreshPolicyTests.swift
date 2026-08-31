import XCTest
@testable import UsageCore

final class UsageRefreshPolicyTests: XCTestCase {
    func testBackgroundRequestStartsNoEarlierThanFifteenMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            UsageRefreshPolicy.backgroundEarliestBeginDate(after: now),
            now.addingTimeInterval(15 * 60)
        )
    }

    func testWidgetCacheDeadlineCapsAOneHourScheduleAtFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            UsageRefreshPolicy.widgetCacheDeadline(
                from: now,
                scheduledReloadDate: now.addingTimeInterval(60 * 60)
            ),
            now.addingTimeInterval(5 * 60)
        )
    }

    func testWidgetCacheDeadlineKeepsAnEarlierScheduledReload() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let earlier = now.addingTimeInterval(60)

        XCTAssertEqual(
            UsageRefreshPolicy.widgetCacheDeadline(
                from: now,
                scheduledReloadDate: earlier
            ),
            earlier
        )
    }
}
