import XCTest
@testable import UsageCore

final class WatchSnapshotTransferPolicyTests: XCTestCase {
    func testUnchangedSnapshotWithoutEventsOnlyUpdatesApplicationContext() {
        XCTAssertEqual(
            WatchSnapshotTransferPolicy.transferKind(
                requiresVisibleSnapshotDelivery: false,
                hasResetEvents: false,
                isComplicationEnabled: true,
                remainingComplicationTransfers: 10
            ),
            .applicationContextOnly
        )
    }

    func testVisibleChangeUsesComplicationFastPathWhenBudgetIsAvailable() {
        XCTAssertEqual(
            WatchSnapshotTransferPolicy.transferKind(
                requiresVisibleSnapshotDelivery: true,
                hasResetEvents: false,
                isComplicationEnabled: true,
                remainingComplicationTransfers: 1
            ),
            .currentComplicationUserInfo
        )
    }

    func testVisibleChangeUsesQueuedFallbackWhenComplicationBudgetIsEmpty() {
        XCTAssertEqual(
            WatchSnapshotTransferPolicy.transferKind(
                requiresVisibleSnapshotDelivery: true,
                hasResetEvents: false,
                isComplicationEnabled: true,
                remainingComplicationTransfers: 0
            ),
            .queuedUserInfo
        )
    }

    func testVisibleChangeUsesQueuedFallbackWhenComplicationIsDisabled() {
        XCTAssertEqual(
            WatchSnapshotTransferPolicy.transferKind(
                requiresVisibleSnapshotDelivery: true,
                hasResetEvents: false,
                isComplicationEnabled: false,
                remainingComplicationTransfers: 0
            ),
            .queuedUserInfo
        )
    }

    func testResetEventsUseDurableQueueWithoutSpendingFastPathAlone() {
        XCTAssertEqual(
            WatchSnapshotTransferPolicy.transferKind(
                requiresVisibleSnapshotDelivery: false,
                hasResetEvents: true,
                isComplicationEnabled: true,
                remainingComplicationTransfers: 10
            ),
            .queuedUserInfo
        )
    }
}
