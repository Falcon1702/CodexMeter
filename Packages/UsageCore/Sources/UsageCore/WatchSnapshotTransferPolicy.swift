public enum WatchSnapshotTransferKind: Equatable, Sendable {
    case applicationContextOnly
    case currentComplicationUserInfo
    case queuedUserInfo
}

public enum WatchSnapshotTransferPolicy {
    public static func transferKind(
        requiresVisibleSnapshotDelivery: Bool,
        hasResetEvents: Bool,
        isComplicationEnabled: Bool,
        remainingComplicationTransfers: Int
    ) -> WatchSnapshotTransferKind {
        guard requiresVisibleSnapshotDelivery || hasResetEvents else {
            return .applicationContextOnly
        }

        if requiresVisibleSnapshotDelivery,
           isComplicationEnabled,
           remainingComplicationTransfers > 0
        {
            return .currentComplicationUserInfo
        }

        return .queuedUserInfo
    }
}
