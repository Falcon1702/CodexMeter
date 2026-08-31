import Foundation
import XCTest
@testable import UsageCore

final class UsageTimelineScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMissingSnapshotRetriesAfterFifteenMinutes() {
        let schedule = UsageTimelineSchedule(now: now, snapshot: nil)

        XCTAssertEqual(schedule.entryDates, [now])
        XCTAssertEqual(schedule.reloadDate, now.addingTimeInterval(15 * 60))
    }

    func testEmptySnapshotRetriesAfterFifteenMinutes() {
        let schedule = UsageTimelineSchedule(
            now: now,
            snapshot: snapshot(resetOffsets: [])
        )

        XCTAssertEqual(schedule.entryDates, [now])
        XCTAssertEqual(schedule.reloadDate, now.addingTimeInterval(15 * 60))
    }

    func testSnapshotWithoutFutureResetRetriesAfterFifteenMinutes() {
        let schedule = UsageTimelineSchedule(
            now: now,
            snapshot: snapshot(resetOffsets: [-60, 0])
        )

        XCTAssertEqual(schedule.entryDates, [now])
        XCTAssertEqual(schedule.reloadDate, now.addingTimeInterval(15 * 60))
    }

    func testDistantResetUsesFiveMinuteCadenceAndOneHourReloadCap() {
        let schedule = UsageTimelineSchedule(
            now: now,
            snapshot: snapshot(resetOffsets: [2 * 60 * 60])
        )
        let expectedDates = stride(from: 0.0, through: 60 * 60, by: 5 * 60)
            .map(now.addingTimeInterval)

        XCTAssertEqual(schedule.entryDates, expectedDates)
        XCTAssertEqual(schedule.reloadDate, now.addingTimeInterval(60 * 60))
    }

    func testCadenceStartsExactlyThirtyMinutesBeforeReset() {
        let resetOffset: TimeInterval = 32 * 60
        let schedule = UsageTimelineSchedule(
            now: now,
            snapshot: snapshot(resetOffsets: [resetOffset])
        )
        let expectedOffsets = [0, 2 * 60]
            + Array(stride(from: 3 * 60, through: resetOffset, by: 60))
            + [resetOffset + 60]

        XCTAssertEqual(
            schedule.entryDates,
            expectedOffsets.map { now.addingTimeInterval(TimeInterval($0)) }
        )
        XCTAssertEqual(schedule.reloadDate, now.addingTimeInterval(resetOffset + 60))
    }

    func testEarliestResetDeterminesReloadAcrossAccounts() {
        let schedule = UsageTimelineSchedule(
            now: now,
            snapshot: snapshot(resetOffsets: [45 * 60, 10 * 60])
        )

        XCTAssertEqual(schedule.entryDates.last, now.addingTimeInterval(11 * 60))
        XCTAssertEqual(schedule.reloadDate, now.addingTimeInterval(11 * 60))
        XCTAssertTrue(schedule.entryDates.contains(now.addingTimeInterval(10 * 60)))
    }

    private func snapshot(resetOffsets: [TimeInterval]) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: now,
            accounts: resetOffsets.enumerated().map { index, offset in
                UsageAccount(
                    id: "account-\(index)",
                    displayName: String(UnicodeScalar(65 + index)!),
                    remainingPercent: 50,
                    usedPercent: 50,
                    resetsAt: now.addingTimeInterval(offset),
                    windowDurationMinutes: 300,
                    windowLabel: "5h",
                    resetCredits: 0,
                    stale: false
                )
            }
        )
    }
}
