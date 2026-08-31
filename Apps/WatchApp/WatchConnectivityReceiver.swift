@preconcurrency import WatchConnectivity
import Foundation
import UsageCore
import UserNotifications
import WidgetKit
import WatchKit

extension Notification.Name {
    static let watchUsageSnapshotDidChange = Notification.Name("watchUsageSnapshotDidChange")
}

final class WatchConnectivityReceiver: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchConnectivityReceiver()

    private let snapshotLock = NSLock()
    private let backgroundTaskLock = NSLock()
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private let maximumEventAge: TimeInterval = 24 * 60 * 60
    private let futureEventTolerance: TimeInterval = 5 * 60
    private let resetInbox = WatchResetEventInboxStore.shared

    func activate() {
        Task {
            await WatchResetNotificationCoordinator.shared.drainPending()
        }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        guard session.activationState == .notActivated else { return }
        session.activate()
    }

    func retainBackgroundTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        backgroundTaskLock.lock()
        backgroundTasks.append(task)
        task.expirationHandler = { [weak self, weak task] in
            guard let self, let task else { return }
            self.completeBackgroundTask(task)
        }
        backgroundTaskLock.unlock()

        activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        if error != nil {
            completeAllBackgroundTasks()
        } else {
            completeBackgroundTasksIfReady(session)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        defer { completeBackgroundTasksIfReady(session) }
        persist(payload: applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        defer { completeBackgroundTasksIfReady(session) }
        persist(payload: userInfo)
    }

    private func completeBackgroundTasksIfReady(_ session: WCSession) {
        guard !session.hasContentPending else { return }
        completeAllBackgroundTasks()
    }

    private func completeAllBackgroundTasks() {
        backgroundTaskLock.lock()
        let retainedTasks = backgroundTasks
        backgroundTasks.removeAll()
        backgroundTaskLock.unlock()

        for task in retainedTasks {
            task.expirationHandler = nil
            task.setTaskCompletedWithSnapshot(false)
        }
    }

    private func completeBackgroundTask(
        _ task: WKWatchConnectivityRefreshBackgroundTask
    ) {
        backgroundTaskLock.lock()
        let retainedTask: WKWatchConnectivityRefreshBackgroundTask?
        if let index = backgroundTasks.firstIndex(where: { $0 === task }) {
            retainedTask = backgroundTasks.remove(at: index)
        } else {
            retainedTask = nil
        }
        backgroundTaskLock.unlock()

        guard let retainedTask else { return }
        retainedTask.expirationHandler = nil
        retainedTask.setTaskCompletedWithSnapshot(false)
    }

    private func persist(payload: [String: Any]) {
        guard let data = payload["usageSnapshot"] as? Data,
              let snapshot = try? UsageSnapshotCodec.decode(data)
        else {
            return
        }

        let storedSnapshot = WatchSnapshotStore.load()
        let knownAccountIDs = Set(
            (storedSnapshot?.accounts ?? []).map(\.id) + snapshot.accounts.map(\.id)
        )
        let resetEvents = validResetEvents(
            decodeResetEvents(from: payload),
            knownAccountIDs: knownAccountIDs,
            now: Date()
        )

        let didStoreSnapshot = storeIfNotOlder(snapshot)
        if didStoreSnapshot {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchOverlaySharedConstants.widgetKind)
            NotificationCenter.default.post(name: .watchUsageSnapshotDidChange, object: nil)
        }

        // Event delivery is independent of snapshot ordering: a queued payload may
        // contain a still-relevant reset even when its snapshot is already obsolete.
        if !resetEvents.isEmpty {
            do {
                // This durable write completes inside the WC callback. The phone may
                // acknowledge transport immediately after the callback returns.
                try resetInbox.append(resetEvents)
                Task {
                    await WatchResetNotificationCoordinator.shared.drainPending()
                }
            } catch {
                // Without durable local storage, acknowledging at the transport
                // layer cannot safely be upgraded into a notification guarantee.
            }
        }
    }

    private func storeIfNotOlder(_ incoming: UsageSnapshot) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }

        if let stored = WatchSnapshotStore.load(),
           incoming.generatedAt < stored.generatedAt {
            return false
        }

        do {
            try WatchSnapshotStore.save(incoming)
            return true
        } catch {
            return false
        }
    }

    private func decodeResetEvents(from payload: [String: Any]) -> [ResetEvent] {
        guard let data = payload["resetEvents"] as? Data else { return [] }
        return (try? JSONDecoder().decode([ResetEvent].self, from: data)) ?? []
    }

    private func validResetEvents(
        _ events: [ResetEvent],
        knownAccountIDs: Set<String>,
        now: Date
    ) -> [ResetEvent] {
        let oldestAcceptedDate = now.addingTimeInterval(-maximumEventAge)
        let newestAcceptedDate = now.addingTimeInterval(futureEventTolerance)
        return events.filter { event in
            guard knownAccountIDs.contains(event.accountID),
                  event.detectedAt >= oldestAcceptedDate,
                  event.detectedAt <= newestAcceptedDate
            else {
                return false
            }

            switch event.kind {
            case .quotaReset:
                return event.currentRemainingPercent.map { 0 ... 100 ~= $0 } ?? true
            case .resetCreditIncrease:
                return event.currentResetCredits.map { $0 >= 0 } ?? true
            }
        }
    }
}

final class WatchResetEventInboxStore: @unchecked Sendable {
    static let shared = WatchResetEventInboxStore()

    private let filename = "watch-reset-event-inbox-v1.json"
    private let maximumEntries = 100
    private let lock = NSLock()

    func load() throws -> [ResetEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func append(_ events: [ResetEvent]) throws {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        let merged = (try loadUnlocked() + events).filter {
            seen.insert($0.stableID).inserted
        }
        try saveUnlocked(Array(merged.suffix(maximumEntries)))
    }

    func remove(identifiers: Set<String>) throws {
        guard !identifiers.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = try loadUnlocked().filter {
            !identifiers.contains($0.stableID)
        }
        try saveUnlocked(remaining)
    }

    private func loadUnlocked() throws -> [ResetEvent] {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ResetEvent].self, from: Data(contentsOf: url))
    }

    private func saveUnlocked(_ events: [ResetEvent]) throws {
        let url = try fileURL()
        try JSONEncoder().encode(events).write(to: url, options: .atomic)
    }

    private func fileURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WatchOverlaySharedConstants.appGroupIdentifier
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return container.appendingPathComponent(filename)
    }
}

actor WatchResetNotificationCoordinator {
    static let shared = WatchResetNotificationCoordinator()

    private let ledgerKey = "watchResetNotificationLedgerV1"
    private let maximumLedgerEntries = 100
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private let maximumPendingAge: TimeInterval = 24 * 60 * 60
    private let inbox = WatchResetEventInboxStore.shared
    private var isDraining = false
    private var drainRequested = false

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        await drainPending()
        return granted
    }

    /// Drains the durable inbox through one serialized notification pipeline.
    /// Reentrant calls only request another pass, so context and user-info cannot
    /// race each other into duplicate presentations.
    func drainPending() async {
        guard !isDraining else {
            drainRequested = true
            return
        }
        isDraining = true
        repeat {
            drainRequested = false
            await drainPass()
        } while drainRequested
        isDraining = false
    }

    private func drainPass() async {
        discardExpiredInboxEvents(now: Date())
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        let canPresent = switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
        guard canPresent else {
            // Pending events remain durable and are retried after permission is
            // granted. Expiration prevents a later burst of stale notifications.
            return
        }

        var ledger = loadLedger()
        prune(&ledger, now: Date())
        saveLedger(ledger)
        let deliveredIDs = Set(await center.deliveredNotifications().map(\.request.identifier))
        let pendingRequestIDs = Set(await center.pendingNotificationRequests().map(\.identifier))
        var knownNotificationIDs = deliveredIDs.union(pendingRequestIDs)
        var attempted = Set<String>()

        while let event = try? inbox.load().first(where: {
            !attempted.contains($0.notificationIdentifier)
        }) {
            let identifier = event.notificationIdentifier
            attempted.insert(identifier)

            if ledger[identifier] != nil || knownNotificationIDs.contains(identifier) {
                markHandled(identifier, event: event, ledger: &ledger)
                continue
            }

            let request = UNNotificationRequest(
                identifier: identifier,
                content: notificationContent(for: event),
                trigger: nil
            )
            do {
                try await center.add(request)
                knownNotificationIDs.insert(identifier)
                markHandled(identifier, event: event, ledger: &ledger)
            } catch {
                // The inbox entry remains durable for app-start or permission retry.
            }
        }
    }

    private func markHandled(
        _ identifier: String,
        event: ResetEvent,
        ledger: inout [String: TimeInterval]
    ) {
        ledger[identifier] = Date().timeIntervalSince1970
        prune(&ledger, now: Date())
        saveLedger(ledger)
        try? inbox.remove(identifiers: [event.stableID])
    }

    private func discardExpiredInboxEvents(now: Date) {
        guard let events = try? inbox.load() else { return }
        let cutoff = now.addingTimeInterval(-maximumPendingAge)
        let expiredIDs = Set(
            events.filter { $0.detectedAt < cutoff }.map(\.stableID)
        )
        try? inbox.remove(identifiers: expiredIDs)
    }

    private func notificationContent(for event: ResetEvent) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .quotaReset:
            content.title = "Codex-Limit zurückgesetzt"
            if let remaining = event.currentRemainingPercent {
                content.body = "\(event.displayName): \(Int(remaining.rounded()))% wieder verfügbar."
            } else {
                content.body = "\(event.displayName): Das Nutzungsfenster ist wieder frei."
            }
        case .resetCreditIncrease:
            content.title = "Codex Reset-Credit verfügbar"
            if let credits = event.currentResetCredits {
                content.body = "\(event.displayName): Jetzt \(credits) Reset-Credit\(credits == 1 ? "" : "s") verfügbar."
            } else {
                content.body = "\(event.displayName): Ein neuer Reset-Credit ist verfügbar."
            }
        }
        content.sound = .default
        return content
    }

    private func loadLedger() -> [String: TimeInterval] {
        sharedDefaults.dictionary(forKey: ledgerKey) as? [String: TimeInterval] ?? [:]
    }

    private func saveLedger(_ ledger: [String: TimeInterval]) {
        let newestEntries = ledger
            .sorted { $0.value > $1.value }
            .prefix(maximumLedgerEntries)
        let persistedLedger = Dictionary<String, TimeInterval>(
            uniqueKeysWithValues: newestEntries.map { ($0.key, $0.value) }
        )
        sharedDefaults.set(persistedLedger, forKey: ledgerKey)
    }

    private func prune(_ ledger: inout [String: TimeInterval], now: Date) {
        let cutoff = now.addingTimeInterval(-retentionInterval).timeIntervalSince1970
        ledger = ledger.filter { $0.value >= cutoff }
    }

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: WatchOverlaySharedConstants.appGroupIdentifier) ?? .standard
    }
}

private extension ResetEvent {
    var notificationIdentifier: String {
        "watch-\(stableID)"
    }
}
