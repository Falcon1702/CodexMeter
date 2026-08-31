import Foundation
import XCTest
@testable import UsageCore

final class UsageSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSeverityBoundaries() {
        XCTAssertEqual(UsageSeverity(remainingPercent: 100), .healthy)
        XCTAssertEqual(UsageSeverity(remainingPercent: 30), .healthy)
        XCTAssertEqual(UsageSeverity(remainingPercent: 29.999), .warning)
        XCTAssertEqual(UsageSeverity(remainingPercent: 10), .warning)
        XCTAssertEqual(UsageSeverity(remainingPercent: 9.999), .critical)
        XCTAssertEqual(UsageSeverity(remainingPercent: -1), .critical)
    }

    func testNormalizationPreservesFirstValidOrderAndLimitsToThree() {
        let snapshot = UsageSnapshot(
            generatedAt: now,
            accounts: [
                account(id: " first ", name: " Alpha ", remaining: 120, used: -2),
                account(id: "", name: "ignored", remaining: 50, used: 50),
                account(id: "first", name: "duplicate", remaining: 20, used: 80),
                account(id: "second", name: "", remaining: 21, used: 79),
                account(id: "third", name: "C", remaining: 7, used: 93),
                account(id: "fourth", name: "D", remaining: 80, used: 20),
            ]
        )

        let normalized = snapshot.normalized()

        XCTAssertEqual(normalized.accounts.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(normalized.accounts.map(\.displayName), ["Alpha", "B", "C"])
        XCTAssertEqual(normalized.accounts[0].remainingPercent, 100)
        XCTAssertEqual(normalized.accounts[0].usedPercent, 0)
        XCTAssertEqual(normalized.adaptiveLayout, .three)
    }

    func testNormalizationSupportsExplicitLowerMaximumAndEmptyLayout() {
        let snapshot = UsageSnapshot(
            generatedAt: now,
            accounts: [
                account(id: "a", name: "A", remaining: 50, used: 50),
                account(id: "b", name: "B", remaining: 40, used: 60),
            ]
        )

        XCTAssertEqual(snapshot.normalized(maxAccounts: 1).accounts.map(\.id), ["a"])
        XCTAssertEqual(snapshot.normalized(maximumAccounts: 0).adaptiveLayout, .empty)
        XCTAssertEqual(AdaptiveAccountLayout(accountCount: 1), .one)
        XCTAssertEqual(AdaptiveAccountLayout(accountCount: 2), .two)
        XCTAssertEqual(AdaptiveAccountLayout(accountCount: 99), .three)
    }

    func testDisplayPercentageRoundsAfterClamping() {
        XCTAssertEqual(
            account(id: "a", name: "A", remaining: 68.4, used: 31.6)
                .displayRemainingPercent,
            68
        )
        XCTAssertEqual(
            account(id: "a", name: "A", remaining: 68.5, used: 31.5)
                .displayRemainingPercent,
            69
        )
        XCTAssertEqual(
            account(id: "a", name: "A", remaining: 105, used: 0)
                .displayRemainingPercent,
            100
        )
    }

    func testCountdownUsesWatchCompactFormatAndRoundsPartialMinutesUp() {
        XCTAssertEqual(
            ResetCountdownFormatter.string(
                until: now.addingTimeInterval((3 * 60 + 18) * 60),
                from: now
            ),
            "3h 18"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(
                until: now.addingTimeInterval(27 * 60),
                now: now
            ),
            "0h 27"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(
                until: now.addingTimeInterval(2 * 24 * 60 * 60 + 3 * 60 * 60),
                from: now
            ),
            "2d 3h"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(
                until: now.addingTimeInterval(61),
                from: now
            ),
            "0h 02"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(until: now, from: now),
            "jetzt"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(until: now.addingTimeInterval(-1), from: now),
            "jetzt"
        )
    }

    func testCodecReadsSanitizedContractWithFractionalAndWholeSecondDates() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2027-01-15T08:00:00.125Z",
          "accounts": [{
            "id": "account-a",
            "displayName": "A",
            "remainingPercent": 68.25,
            "usedPercent": 31.75,
            "resetsAt": "2027-01-15T09:42:00Z",
            "windowDurationMinutes": 300,
            "windowLabel": "5h",
            "resetCredits": 0,
            "stale": false
          }]
        }
        """

        let decoded = try UsageSnapshotCodec.decode(Data(json.utf8))

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.accounts.single?.id, "account-a")
        XCTAssertEqual(decoded.accounts.single?.severity, .healthy)
        XCTAssertEqual(decoded.accounts.single?.remainingPercent, 68.25)
        XCTAssertEqual(decoded.accounts.single?.usedPercent, 31.75)
        XCTAssertEqual(decoded.accounts.single?.windowDurationMinutes, 300)
        XCTAssertNil(decoded.accounts.single?.serviceBrand)

        let encoded = try UsageSnapshotCodec.encode(decoded)
        let roundTripped = try UsageSnapshotCodec.decode(encoded)
        XCTAssertEqual(roundTripped, decoded)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("T08:00:00.125Z"))
    }

    func testCodecDecodesLegacyAccountWithoutServiceBrandAsUnselected() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2027-01-15T08:00:00Z",
          "accounts": [{
            "id": "legacy-account",
            "displayName": "A",
            "remainingPercent": 50,
            "usedPercent": 50,
            "resetsAt": "2027-01-15T09:00:00Z",
            "windowDurationMinutes": 300,
            "windowLabel": "5h",
            "resetCredits": 0,
            "stale": false
          }]
        }
        """

        let decoded = try UsageSnapshotCodec.decode(Data(json.utf8))

        XCTAssertEqual(decoded.accounts.single?.id, "legacy-account")
        XCTAssertNil(decoded.accounts.single?.serviceBrand)
    }

    func testCodecTreatsUnknownServiceBrandAsUnselected() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2027-01-15T08:00:00Z",
          "accounts": [{
            "id": "account-a",
            "displayName": "A",
            "remainingPercent": 68,
            "usedPercent": 32,
            "resetsAt": "2027-01-15T09:42:00Z",
            "windowDurationMinutes": 300,
            "windowLabel": "5h",
            "resetCredits": 0,
            "stale": false,
            "serviceBrand": "future-service"
          }]
        }
        """

        let decoded = try UsageSnapshotCodec.decode(Data(json.utf8))

        XCTAssertNil(decoded.accounts.single?.serviceBrand)
    }

    func testCodecRoundTripsEveryServiceBrand() throws {
        XCTAssertEqual(
            UsageServiceBrand.allCases.map(\.displayName),
            ["Codex", "Hermes", "OpenClaw", "Buzz"]
        )

        for brand in UsageServiceBrand.allCases {
            let snapshot = UsageSnapshot(
                generatedAt: now,
                accounts: [
                    account(
                        id: brand.rawValue,
                        name: brand.displayName,
                        remaining: 50,
                        used: 50,
                        serviceBrand: brand
                    ),
                ]
            )

            let encoded = try UsageSnapshotCodec.encode(snapshot)
            let decoded = try UsageSnapshotCodec.decode(encoded)

            XCTAssertEqual(decoded.accounts.single?.serviceBrand, brand)
        }
    }

    func testNormalizationPreservesServiceBrand() {
        let snapshot = UsageSnapshot(
            generatedAt: now,
            accounts: [
                account(
                    id: " account-a ",
                    name: " A ",
                    remaining: 125,
                    used: -25,
                    serviceBrand: .openClaw
                ),
            ]
        )

        let normalized = snapshot.normalized()

        XCTAssertEqual(normalized.accounts.single?.serviceBrand, .openClaw)
    }

    func testCodecRejectsUnsupportedSchemaVersionWhenDecoding() {
        let json = """
        {
          "schemaVersion": 2,
          "generatedAt": "2027-01-15T08:00:00.000Z",
          "accounts": []
        }
        """

        XCTAssertThrowsError(try UsageSnapshotCodec.decode(Data(json.utf8))) { error in
            XCTAssertEqual(
                error as? UsageSnapshotCodecError,
                .unsupportedSchemaVersion(expected: 1, actual: 2)
            )
        }
    }

    func testCodecRejectsUnsupportedSchemaVersionWhenEncoding() {
        let snapshot = UsageSnapshot(schemaVersion: 0, generatedAt: now, accounts: [])

        XCTAssertThrowsError(try UsageSnapshotCodec.encode(snapshot)) { error in
            XCTAssertEqual(
                error as? UsageSnapshotCodecError,
                .unsupportedSchemaVersion(expected: 1, actual: 0)
            )
        }
    }

    private func account(
        id: String,
        name: String,
        remaining: Double,
        used: Double,
        resetsAt: Date? = nil,
        serviceBrand: UsageServiceBrand? = nil
    ) -> UsageAccount {
        UsageAccount(
            id: id,
            displayName: name,
            remainingPercent: remaining,
            usedPercent: used,
            resetsAt: resetsAt ?? now.addingTimeInterval(3_600),
            windowDurationMinutes: 300,
            windowLabel: "5h",
            resetCredits: 0,
            stale: false,
            serviceBrand: serviceBrand
        )
    }
}

private extension Collection {
    var single: Element? {
        count == 1 ? first : nil
    }
}
