@preconcurrency import WatchConnectivity
import Foundation
import UsageCore

final class WatchSyncCoordinator: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchSyncCoordinator()

    private enum PayloadKey {
        static let transferKind = "watchOverlayTransferKind"
    }

    private enum PayloadTransferKind {
        static let snapshotOnly = "snapshot-only-v1"
        static let resetEvents = "reset-events-v1"
    }

    private struct PendingTransfer {
        let schemaVersion: Int
        let data: Data
        let resetEvents: [ResetEvent]
        let priority: Bool
    }

    private let stateLock = NSLock()
    private var pendingTransfer: PendingTransfer?
    private var inFlightEventIDs = Set<String>()
    private let outbox = ResetEventOutboxStore.shared

    private var session: WCSession? {
        WCSession.isSupported() ? .default : nil
    }

    func activate() {
        guard let session, session.activationState == .notActivated else { return }
        session.delegate = self
        session.activate()
    }

    func send(
        _ snapshot: UsageSnapshot,
        resetEvents: [ResetEvent] = [],
        priority: Bool
    ) {
        guard let session else { return }
        do {
            let persistedEvents = try outbox.load()
            let freshTransfer = PendingTransfer(
                schemaVersion: snapshot.schemaVersion,
                data: try UsageSnapshotCodec.encode(snapshot),
                resetEvents: mergedEvents(persistedEvents, resetEvents),
                priority: priority
            )
            let transfer = takePending(mergingInto: freshTransfer)
            guard session.activationState == .activated else {
                storePending(transfer)
                activate()
                return
            }
            transmit(transfer, through: session)
        } catch {
            // The on-disk outbox remains authoritative and is retried on the next send.
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated, error == nil,
              let pending = takePending()
        else {
            return
        }
        transmit(pending, through: session)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.activationState == .activated,
              let pending = takePending()
        else {
            return
        }
        transmit(pending, through: session)
    }

    func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        let events = decodeResetEvents(from: userInfoTransfer.userInfo)
        let identifiers = Set(events.map(\.stableID))
        releaseInFlight(identifiers)

        guard error == nil else {
            queueCachedSnapshotForRetry(priority: true)
            return
        }

        do {
            try outbox.remove(identifiers: identifiers)
            if let snapshot = PhoneSnapshotStore.load() {
                // Clears delivered events from application context and immediately
                // starts the next batch if the persistent outbox still has entries.
                send(snapshot, priority: false)
            }
        } catch {
            // Delivery succeeded but durable acknowledgement failed. Keeping the
            // event causes a safe duplicate retry; the watch deduplicates it.
            queueCachedSnapshotForRetry(priority: false)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    private func transmit(_ transfer: PendingTransfer, through session: WCSession) {
        guard let allEventsData = try? JSONEncoder().encode(transfer.resetEvents) else {
            storePending(transfer)
            return
        }

        let payload: [String: Any] = [
            "schemaVersion": transfer.schemaVersion,
            "usageSnapshot": transfer.data,
            "resetEvents": allEventsData,
        ]
        do {
            try session.updateApplicationContext(payload)
        } catch {
            storePending(transfer)
            return
        }

        guard session.isPaired, session.isWatchAppInstalled else { return }
        let eventsToTransfer = reserveEventsForTransfer(transfer.resetEvents)
        let transferKind = WatchSnapshotTransferPolicy.transferKind(
            requiresVisibleSnapshotDelivery: transfer.priority,
            hasResetEvents: !eventsToTransfer.isEmpty,
            isComplicationEnabled: session.isComplicationEnabled,
            remainingComplicationTransfers: session.remainingComplicationUserInfoTransfers
        )
        guard transferKind != .applicationContextOnly else {
            return
        }
        guard let eventData = try? JSONEncoder().encode(eventsToTransfer) else {
            releaseInFlight(Set(eventsToTransfer.map(\.stableID)))
            storePending(transfer)
            return
        }

        var eventPayload = payload
        eventPayload["resetEvents"] = eventData
        eventPayload[PayloadKey.transferKind] = eventsToTransfer.isEmpty
            ? PayloadTransferKind.snapshotOnly
            : PayloadTransferKind.resetEvents

        cancelSupersededSnapshotOnlyTransfers(through: session)
        switch transferKind {
        case .applicationContextOnly:
            break
        case .currentComplicationUserInfo:
            session.transferCurrentComplicationUserInfo(eventPayload)
        case .queuedUserInfo:
            session.transferUserInfo(eventPayload)
        }
    }

    private func cancelSupersededSnapshotOnlyTransfers(through session: WCSession) {
        for outstanding in session.outstandingUserInfoTransfers where
            outstanding.userInfo[PayloadKey.transferKind] as? String
                == PayloadTransferKind.snapshotOnly
        {
            outstanding.cancel()
        }
    }

    private func storePending(_ transfer: PendingTransfer) {
        stateLock.lock()
        let priority = transfer.priority || (pendingTransfer?.priority ?? false)
        let resetEvents = mergedEvents(
            pendingTransfer?.resetEvents ?? [],
            transfer.resetEvents
        )
        pendingTransfer = PendingTransfer(
            schemaVersion: transfer.schemaVersion,
            data: transfer.data,
            resetEvents: resetEvents,
            priority: priority
        )
        stateLock.unlock()
    }

    private func takePending() -> PendingTransfer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let transfer = pendingTransfer
        pendingTransfer = nil
        return transfer
    }

    private func takePending(mergingInto newer: PendingTransfer) -> PendingTransfer {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let pending = pendingTransfer else { return newer }
        pendingTransfer = nil
        return PendingTransfer(
            schemaVersion: newer.schemaVersion,
            data: newer.data,
            resetEvents: mergedEvents(pending.resetEvents, newer.resetEvents),
            priority: pending.priority || newer.priority
        )
    }

    private func reserveEventsForTransfer(_ events: [ResetEvent]) -> [ResetEvent] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let available = events.filter {
            !inFlightEventIDs.contains($0.stableID)
        }
        inFlightEventIDs.formUnion(available.map(\.stableID))
        return available
    }

    private func releaseInFlight(_ identifiers: Set<String>) {
        stateLock.lock()
        inFlightEventIDs.subtract(identifiers)
        stateLock.unlock()
    }

    private func queueCachedSnapshotForRetry(priority: Bool) {
        guard let snapshot = PhoneSnapshotStore.load(),
              let data = try? UsageSnapshotCodec.encode(snapshot),
              let events = try? outbox.load()
        else {
            return
        }
        storePending(
            PendingTransfer(
                schemaVersion: snapshot.schemaVersion,
                data: data,
                resetEvents: events,
                priority: priority
            )
        )
    }

    private func decodeResetEvents(from payload: [String: Any]) -> [ResetEvent] {
        guard let data = payload["resetEvents"] as? Data else { return [] }
        return (try? JSONDecoder().decode([ResetEvent].self, from: data)) ?? []
    }

    private func mergedEvents(
        _ olderEvents: [ResetEvent],
        _ newerEvents: [ResetEvent]
    ) -> [ResetEvent] {
        var seen = Set<String>()
        return (olderEvents + newerEvents).filter {
            seen.insert($0.stableID).inserted
        }
    }
}
