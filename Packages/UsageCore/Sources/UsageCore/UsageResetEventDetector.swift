import Foundation

public struct ResetEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case quotaReset
        case resetCreditIncrease
    }

    public var accountID: String
    public var displayName: String
    public var kind: Kind
    public var detectedAt: Date
    public var previousResetsAt: Date?
    public var currentResetsAt: Date?
    public var previousRemainingPercent: Double?
    public var currentRemainingPercent: Double?
    public var previousResetCredits: Int?
    public var currentResetCredits: Int?

    public init(
        accountID: String,
        displayName: String,
        kind: Kind,
        detectedAt: Date,
        previousResetsAt: Date? = nil,
        currentResetsAt: Date? = nil,
        previousRemainingPercent: Double? = nil,
        currentRemainingPercent: Double? = nil,
        previousResetCredits: Int? = nil,
        currentResetCredits: Int? = nil
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.kind = kind
        self.detectedAt = detectedAt
        self.previousResetsAt = previousResetsAt
        self.currentResetsAt = currentResetsAt
        self.previousRemainingPercent = previousRemainingPercent
        self.currentRemainingPercent = currentRemainingPercent
        self.previousResetCredits = previousResetCredits
        self.currentResetCredits = currentResetCredits
    }

    /// Stable identity for persistence, delivery acknowledgement, and deduplication.
    ///
    /// New quota events use their reset-window transition and credit events use
    /// their credit transition. `detectedAt` is retained only for decoding legacy
    /// events that predate those identity fields.
    public var stableID: String {
        let accountComponent = "\(accountID.utf8.count):\(accountID)"

        switch kind {
        case .quotaReset:
            if let previousResetsAt, let currentResetsAt {
                return [
                    "reset-v2",
                    accountComponent,
                    kind.rawValue,
                    Self.milliseconds(previousResetsAt),
                    Self.milliseconds(currentResetsAt),
                ].joined(separator: "|")
            }
        case .resetCreditIncrease:
            if let previousResetCredits, let currentResetCredits {
                return [
                    "reset-v2",
                    accountComponent,
                    kind.rawValue,
                    String(previousResetCredits),
                    String(currentResetCredits),
                ].joined(separator: "|")
            }
        }

        return [
            "reset-v1-legacy",
            accountComponent,
            kind.rawValue,
            Self.milliseconds(detectedAt),
        ].joined(separator: "|")
    }

    private static func milliseconds(_ date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }
}

public struct ResetEventDetector: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// A change smaller than this is treated as sampling noise or correction.
        public var minimumPercentageChange: Double
        /// Allows a fresh sample immediately before the old reset deadline to account
        /// for clock skew and polling latency.
        public var resetBoundaryGraceSeconds: TimeInterval

        public init(
            minimumPercentageChange: Double = 1,
            resetBoundaryGraceSeconds: TimeInterval = 120
        ) {
            self.minimumPercentageChange = max(minimumPercentageChange, 0)
            self.resetBoundaryGraceSeconds = max(resetBoundaryGraceSeconds, 0)
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Detects newly confirmed events in current account order.
    ///
    /// A quota reset is confirmed only when both percentage directions agree, the
    /// reset deadline advanced, and the new sample was taken at (or just before) the
    /// old boundary. Stale, out-of-order, new-account, and duplicate samples do not
    /// produce notifications.
    public func events(
        previous: UsageSnapshot,
        current: UsageSnapshot
    ) -> [ResetEvent] {
        guard current.generatedAt >= previous.generatedAt else { return [] }

        let previousAccounts = Dictionary(
            previous.normalized().accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var events: [ResetEvent] = []

        for currentAccount in current.normalized().accounts {
            guard
                let previousAccount = previousAccounts[currentAccount.id],
                !previousAccount.stale,
                !currentAccount.stale
            else {
                continue
            }

            let remainingGain = currentAccount.normalizedRemainingPercent
                - previousAccount.normalizedRemainingPercent
            let usedDrop = previousAccount.normalizedUsedPercent
                - currentAccount.normalizedUsedPercent
            let resetDeadlineAdvanced = currentAccount.resetsAt > previousAccount.resetsAt
            let sampleReachedOldBoundary = current.generatedAt
                >= previousAccount.resetsAt.addingTimeInterval(
                    -configuration.resetBoundaryGraceSeconds
                )

            if remainingGain >= configuration.minimumPercentageChange,
               usedDrop >= configuration.minimumPercentageChange,
               resetDeadlineAdvanced,
               sampleReachedOldBoundary {
                events.append(
                    ResetEvent(
                        accountID: currentAccount.id,
                        displayName: currentAccount.displayName,
                        kind: .quotaReset,
                        detectedAt: current.generatedAt,
                        previousResetsAt: previousAccount.resetsAt,
                        currentResetsAt: currentAccount.resetsAt,
                        previousRemainingPercent: previousAccount.normalizedRemainingPercent,
                        currentRemainingPercent: currentAccount.normalizedRemainingPercent
                    )
                )
            }

            if currentAccount.resetCredits > previousAccount.resetCredits {
                events.append(
                    ResetEvent(
                        accountID: currentAccount.id,
                        displayName: currentAccount.displayName,
                        kind: .resetCreditIncrease,
                        detectedAt: current.generatedAt,
                        previousResetCredits: previousAccount.resetCredits,
                        currentResetCredits: currentAccount.resetCredits
                    )
                )
            }
        }

        return events
    }

    /// App-facing spelling used by the sync pipeline.
    public func detect(
        previous: UsageSnapshot,
        current: UsageSnapshot
    ) -> [ResetEvent] {
        events(previous: previous, current: current)
    }
}

/// Compatibility aliases for early V1 call sites that used the longer names.
public typealias UsageResetEvent = ResetEvent
public typealias UsageResetEventDetector = ResetEventDetector
