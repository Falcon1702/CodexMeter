import Foundation

/// Sanitized, token-free payload shared by the bridge, companion app, and watch.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var accounts: [UsageAccount]

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        accounts: [UsageAccount]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    /// Returns a presentation-safe snapshot for the 1–3 account complication.
    ///
    /// Source order is retained. Blank identifiers and later duplicates are discarded,
    /// each account is clamped to valid percentage ranges, and only the first three
    /// valid accounts are retained.
    public func normalized(maximumAccounts: Int = 3) -> UsageSnapshot {
        let limit = min(max(maximumAccounts, 0), 3)
        guard limit > 0 else {
            return UsageSnapshot(
                schemaVersion: schemaVersion,
                generatedAt: generatedAt,
                accounts: []
            )
        }

        var seenIDs = Set<String>()
        var normalizedAccounts: [UsageAccount] = []
        normalizedAccounts.reserveCapacity(limit)

        for sourceAccount in accounts {
            let account = sourceAccount.normalized()
            guard !account.id.isEmpty, seenIDs.insert(account.id).inserted else {
                continue
            }

            let fallbackLabel = String(UnicodeScalar(65 + normalizedAccounts.count)!)
            normalizedAccounts.append(
                account.withDisplayNameFallback(fallbackLabel)
            )

            if normalizedAccounts.count == limit {
                break
            }
        }

        return UsageSnapshot(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            accounts: normalizedAccounts
        )
    }

    /// App-facing spelling used by the companion and widget targets.
    public func normalized(maxAccounts: Int) -> UsageSnapshot {
        normalized(maximumAccounts: maxAccounts)
    }

    public var adaptiveLayout: AdaptiveAccountLayout {
        AdaptiveAccountLayout(accountCount: normalized().accounts.count)
    }
}

public enum UsageServiceBrand: String, Codable, CaseIterable, Sendable {
    case codex
    case hermes
    case openClaw
    case buzz

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .hermes: "Hermes"
        case .openClaw: "OpenClaw"
        case .buzz: "Buzz"
        }
    }
}

public struct UsageAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var remainingPercent: Double
    public var usedPercent: Double
    public var resetsAt: Date
    public var windowDurationMinutes: Int
    public var windowLabel: String
    public var resetCredits: Int
    public var stale: Bool
    public var serviceBrand: UsageServiceBrand?

    public init(
        id: String,
        displayName: String,
        remainingPercent: Double,
        usedPercent: Double,
        resetsAt: Date,
        windowDurationMinutes: Int,
        windowLabel: String,
        resetCredits: Int,
        stale: Bool,
        serviceBrand: UsageServiceBrand? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes
        self.windowLabel = windowLabel
        self.resetCredits = resetCredits
        self.stale = stale
        self.serviceBrand = serviceBrand
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case remainingPercent
        case usedPercent
        case resetsAt
        case windowDurationMinutes
        case windowLabel
        case resetCredits
        case stale
        case serviceBrand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        remainingPercent = try container.decode(Double.self, forKey: .remainingPercent)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        resetsAt = try container.decode(Date.self, forKey: .resetsAt)
        windowDurationMinutes = try container.decode(Int.self, forKey: .windowDurationMinutes)
        windowLabel = try container.decode(String.self, forKey: .windowLabel)
        resetCredits = try container.decode(Int.self, forKey: .resetCredits)
        stale = try container.decode(Bool.self, forKey: .stale)

        // The bridge V1 contract and existing on-device caches predate service
        // branding. Unknown future values are presentation metadata only and
        // must not make the otherwise valid usage snapshot unreadable.
        serviceBrand = (try? container.decode(String.self, forKey: .serviceBrand))
            .flatMap(UsageServiceBrand.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(remainingPercent, forKey: .remainingPercent)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(resetsAt, forKey: .resetsAt)
        try container.encode(windowDurationMinutes, forKey: .windowDurationMinutes)
        try container.encode(windowLabel, forKey: .windowLabel)
        try container.encode(resetCredits, forKey: .resetCredits)
        try container.encode(stale, forKey: .stale)
        try container.encodeIfPresent(serviceBrand, forKey: .serviceBrand)
    }

    public var severity: UsageSeverity {
        UsageSeverity(remainingPercent: normalizedRemainingPercent)
    }

    public var normalizedRemainingPercent: Double {
        remainingPercent.clamped(to: 0 ... 100)
    }

    public var normalizedUsedPercent: Double {
        usedPercent.clamped(to: 0 ... 100)
    }

    /// Whole-number value used by the complication's dominant percentage label.
    public var displayRemainingPercent: Int {
        Int(normalizedRemainingPercent.rounded())
    }

    public func resetCountdown(from referenceDate: Date) -> String {
        ResetCountdownFormatter.string(until: resetsAt, from: referenceDate)
    }

    fileprivate func normalized() -> UsageAccount {
        UsageAccount(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            remainingPercent: normalizedRemainingPercent,
            usedPercent: normalizedUsedPercent,
            resetsAt: resetsAt,
            windowDurationMinutes: max(windowDurationMinutes, 0),
            windowLabel: windowLabel.trimmingCharacters(in: .whitespacesAndNewlines),
            resetCredits: max(resetCredits, 0),
            stale: stale,
            serviceBrand: serviceBrand
        )
    }

    fileprivate func withDisplayNameFallback(_ fallback: String) -> UsageAccount {
        guard displayName.isEmpty else { return self }
        var copy = self
        copy.displayName = fallback
        return copy
    }
}

public enum AdaptiveAccountLayout: Int, Codable, Equatable, Sendable {
    case empty = 0
    case one = 1
    case two = 2
    case three = 3

    public init(accountCount: Int) {
        switch accountCount {
        case ...0: self = .empty
        case 1: self = .one
        case 2: self = .two
        default: self = .three
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
