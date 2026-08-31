import Foundation
import XCTest
@testable import UsageCore

final class UsageResetEventDetectorTests: XCTestCase {
    private let oldGeneratedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testDetectsConfirmedQuotaResetAtOldBoundary() {
        let oldReset = oldGeneratedAt.addingTimeInterval(60 * 60)
        let previous = snapshot(
            generatedAt: oldGeneratedAt,
            account: account(remaining: 7, used: 93, resetsAt: oldReset)
        )
        let currentGeneratedAt = oldReset.addingTimeInterval(30)
        let current = snapshot(
            generatedAt: currentGeneratedAt,
            account: account(
                remaining: 100,
                used: 0,
                resetsAt: oldReset.addingTimeInterval(5 * 60 * 60)
            )
        )

        XCTAssertEqual(
            ResetEventDetector().detect(previous: previous, current: current),
            [
                ResetEvent(
                    accountID: "account-a",
                    displayName: "A",
                    kind: .quotaReset,
                    detectedAt: currentGeneratedAt,
                    previousResetsAt: oldReset,
                    currentResetsAt: oldReset.addingTimeInterval(5 * 60 * 60),
                    previousRemainingPercent: 7,
                    currentRemainingPercent: 100
                ),
            ]
        )
    }

    func testDoesNotClaimQuotaResetBeforeBoundaryOrWithoutAdvancedDeadline() {
        let oldReset = oldGeneratedAt.addingTimeInterval(60 * 60)
        let previous = snapshot(
            generatedAt: oldGeneratedAt,
            account: account(remaining: 20, used: 80, resetsAt: oldReset)
        )
        let earlyCorrection = snapshot(
            generatedAt: oldGeneratedAt.addingTimeInterval(10 * 60),
            account: account(
                remaining: 25,
                used: 75,
                resetsAt: oldReset.addingTimeInterval(5 * 60 * 60)
            )
        )
        let deadlineUnchanged = snapshot(
            generatedAt: oldReset,
            account: account(remaining: 100, used: 0, resetsAt: oldReset)
        )

        let detector = UsageResetEventDetector()
        XCTAssertTrue(detector.events(previous: previous, current: earlyCorrection).isEmpty)
        XCTAssertTrue(detector.events(previous: previous, current: deadlineUnchanged).isEmpty)
    }

    func testRequiresBothPercentageDirectionsToAgree() {
        let oldReset = oldGeneratedAt.addingTimeInterval(60 * 60)
        let previous = snapshot(
            generatedAt: oldGeneratedAt,
            account: account(remaining: 7, used: 93, resetsAt: oldReset)
        )
        let inconsistent = snapshot(
            generatedAt: oldReset,
            account: account(
                remaining: 100,
                used: 93,
                resetsAt: oldReset.addingTimeInterval(5 * 60 * 60)
            )
        )

        XCTAssertTrue(
            UsageResetEventDetector().events(previous: previous, current: inconsistent).isEmpty
        )
    }

    func testDetectsResetCreditIncreaseIndependently() {
        let oldReset = oldGeneratedAt.addingTimeInterval(60 * 60)
        let previous = snapshot(
            generatedAt: oldGeneratedAt,
            account: account(remaining: 40, used: 60, resetsAt: oldReset, credits: 1)
        )
        let currentGeneratedAt = oldGeneratedAt.addingTimeInterval(60)
        let current = snapshot(
            generatedAt: currentGeneratedAt,
            account: account(remaining: 40, used: 60, resetsAt: oldReset, credits: 3)
        )

        XCTAssertEqual(
            UsageResetEventDetector().events(previous: previous, current: current),
            [
                ResetEvent(
                    accountID: "account-a",
                    displayName: "A",
                    kind: .resetCreditIncrease,
                    detectedAt: currentGeneratedAt,
                    previousResetCredits: 1,
                    currentResetCredits: 3
                ),
            ]
        )
    }

    func testStaleOutOfOrderNewAndRepeatedSamplesDoNotNotify() {
        let oldReset = oldGeneratedAt.addingTimeInterval(60 * 60)
        let previous = snapshot(
            generatedAt: oldGeneratedAt,
            account: account(remaining: 7, used: 93, resetsAt: oldReset, credits: 0)
        )
        let changedAccount = account(
            remaining: 100,
            used: 0,
            resetsAt: oldReset.addingTimeInterval(5 * 60 * 60),
            credits: 1
        )
        let detector = UsageResetEventDetector()

        var staleAccount = changedAccount
        staleAccount.stale = true
        let stale = snapshot(generatedAt: oldReset, account: staleAccount)
        XCTAssertTrue(detector.events(previous: previous, current: stale).isEmpty)

        let outOfOrder = snapshot(
            generatedAt: oldGeneratedAt.addingTimeInterval(-1),
            account: changedAccount
        )
        XCTAssertTrue(detector.events(previous: previous, current: outOfOrder).isEmpty)

        var newAccount = changedAccount
        newAccount.id = "new-account"
        let unknown = snapshot(generatedAt: oldReset, account: newAccount)
        XCTAssertTrue(detector.events(previous: previous, current: unknown).isEmpty)

        let unchanged = snapshot(generatedAt: oldReset, account: changedAccount)
        let repeated = snapshot(
            generatedAt: oldReset.addingTimeInterval(60),
            account: changedAccount
        )
        XCTAssertTrue(detector.events(previous: unchanged, current: repeated).isEmpty)
    }

    func testCustomNoiseThresholdIsHonored() {
        let oldReset = oldGeneratedAt.addingTimeInterval(60 * 60)
        let previous = snapshot(
            generatedAt: oldGeneratedAt,
            account: account(remaining: 20, used: 80, resetsAt: oldReset)
        )
        let current = snapshot(
            generatedAt: oldReset,
            account: account(
                remaining: 20.5,
                used: 79.5,
                resetsAt: oldReset.addingTimeInterval(5 * 60 * 60)
            )
        )

        let detector = UsageResetEventDetector(
            configuration: .init(minimumPercentageChange: 1)
        )
        XCTAssertTrue(detector.events(previous: previous, current: current).isEmpty)
    }

    func testQuotaStableIDUsesResetBoundariesNotDetectionTime() {
        let previousReset = oldGeneratedAt.addingTimeInterval(60 * 60)
        let currentReset = previousReset.addingTimeInterval(5 * 60 * 60)
        let first = ResetEvent(
            accountID: "account-a",
            displayName: "A",
            kind: .quotaReset,
            detectedAt: previousReset,
            previousResetsAt: previousReset,
            currentResetsAt: currentReset,
            previousRemainingPercent: 7,
            currentRemainingPercent: 100
        )
        let detectedLater = ResetEvent(
            accountID: "account-a",
            displayName: "Account A",
            kind: .quotaReset,
            detectedAt: previousReset.addingTimeInterval(90),
            previousResetsAt: previousReset,
            currentResetsAt: currentReset,
            previousRemainingPercent: 8,
            currentRemainingPercent: 99
        )

        XCTAssertEqual(first.stableID, detectedLater.stableID)
    }

    func testCreditStableIDUsesCreditTransitionNotDetectionTime() {
        let first = ResetEvent(
            accountID: "account-a",
            displayName: "A",
            kind: .resetCreditIncrease,
            detectedAt: oldGeneratedAt,
            previousResetCredits: 1,
            currentResetCredits: 2
        )
        let detectedLater = ResetEvent(
            accountID: "account-a",
            displayName: "A",
            kind: .resetCreditIncrease,
            detectedAt: oldGeneratedAt.addingTimeInterval(300),
            previousResetCredits: 1,
            currentResetCredits: 2
        )

        XCTAssertEqual(first.stableID, detectedLater.stableID)
    }

    func testLegacyStableIDFallsBackToDetectionTime() {
        let first = ResetEvent(
            accountID: "account-a",
            displayName: "A",
            kind: .quotaReset,
            detectedAt: oldGeneratedAt
        )
        let detectedLater = ResetEvent(
            accountID: "account-a",
            displayName: "A",
            kind: .quotaReset,
            detectedAt: oldGeneratedAt.addingTimeInterval(1)
        )

        XCTAssertNotEqual(first.stableID, detectedLater.stableID)
    }

    private func snapshot(
        generatedAt: Date,
        account: UsageAccount
    ) -> UsageSnapshot {
        UsageSnapshot(generatedAt: generatedAt, accounts: [account])
    }

    private func account(
        remaining: Double,
        used: Double,
        resetsAt: Date,
        credits: Int = 0
    ) -> UsageAccount {
        UsageAccount(
            id: "account-a",
            displayName: "A",
            remainingPercent: remaining,
            usedPercent: used,
            resetsAt: resetsAt,
            windowDurationMinutes: 300,
            windowLabel: "5h",
            resetCredits: credits,
            stale: false
        )
    }
}
