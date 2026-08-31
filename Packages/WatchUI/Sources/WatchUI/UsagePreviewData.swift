import Foundation
import UsageCore

public enum UsagePreviewData {
    public static let generatedAt = Date(timeIntervalSince1970: 1_788_107_200)

    public static let accounts: [UsageAccount] = [
        UsageAccount(
            id: "account-a",
            displayName: "A",
            remainingPercent: 68,
            usedPercent: 32,
            resetsAt: generatedAt.addingTimeInterval(6_120),
            windowDurationMinutes: 300,
            windowLabel: "5h",
            resetCredits: 0,
            stale: false,
            serviceBrand: .codex
        ),
        UsageAccount(
            id: "account-b",
            displayName: "B",
            remainingPercent: 21,
            usedPercent: 79,
            resetsAt: generatedAt.addingTimeInterval(11_880),
            windowDurationMinutes: 300,
            windowLabel: "5h",
            resetCredits: 0,
            stale: false,
            serviceBrand: .hermes
        ),
        UsageAccount(
            id: "account-c",
            displayName: "C",
            remainingPercent: 7,
            usedPercent: 93,
            resetsAt: generatedAt.addingTimeInterval(1_620),
            windowDurationMinutes: 300,
            windowLabel: "5h",
            resetCredits: 1,
            stale: false,
            serviceBrand: .openClaw
        ),
    ]

    public static let buzzAccount = UsageAccount(
        id: "account-buzz",
        displayName: "B",
        remainingPercent: 42,
        usedPercent: 58,
        resetsAt: generatedAt.addingTimeInterval(4_920),
        windowDurationMinutes: 300,
        windowLabel: "5h",
        resetCredits: 0,
        stale: false,
        serviceBrand: .buzz
    )

    public static var unbrandedAccounts: [UsageAccount] {
        accounts.map { account in
            var copy = account
            copy.serviceBrand = nil
            return copy
        }
    }

    public static func snapshot(accountCount: Int = 3) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: generatedAt,
            accounts: Array(accounts.prefix(accountCount))
        )
    }
}
