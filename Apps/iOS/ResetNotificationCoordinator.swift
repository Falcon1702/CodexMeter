import Foundation
import UsageCore
import UserNotifications

actor ResetNotificationCoordinator {
    static let shared = ResetNotificationCoordinator()

    private struct PersistentState: Codable {
        var pending: [ResetEvent] = []
        var handledAt: [String: TimeInterval] = [:]
    }

    private let filename = "reset-notification-outbox-v1.json"
    private let maximumHandledEntries = 200
    private let handledRetention: TimeInterval = 30 * 24 * 60 * 60
    private var isDraining = false

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        let granted = try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        try await drain()
        return granted
    }

    /// Persists new events before attempting delivery. Notification-center errors
    /// leave the event pending for the next refresh or process launch.
    func enqueueAndDeliver(_ events: [ResetEvent]) async throws {
        if !events.isEmpty {
            var state = try loadState()
            pruneHandled(&state)
            let handled = Set(state.handledAt.keys)
            state.pending = merge(
                state.pending,
                events.filter { !handled.contains(notificationIdentifier(for: $0)) }
            )
            try saveState(state)
        }
        try await drain()
    }

    func retryPending() async throws {
        try await drain()
    }

    private func drain() async throws {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

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

        if !canPresent {
            // A denied or not-yet-requested permission must not create a burst of
            // stale alerts when permission is granted later.
            var state = try loadState()
            let now = Date().timeIntervalSince1970
            for event in state.pending {
                state.handledAt[notificationIdentifier(for: event)] = now
            }
            state.pending.removeAll()
            pruneHandled(&state)
            try saveState(state)
            return
        }

        let deliveredIDs = Set(await center.deliveredNotifications().map(\.request.identifier))
        let pendingRequestIDs = Set(await center.pendingNotificationRequests().map(\.identifier))
        var knownNotificationIDs = deliveredIDs.union(pendingRequestIDs)
        var attempted = Set<String>()

        while let event = try loadState().pending.first(where: {
            !attempted.contains(notificationIdentifier(for: $0))
        }) {
            let identifier = notificationIdentifier(for: event)
            attempted.insert(identifier)

            if knownNotificationIDs.contains(identifier) {
                try markHandled(identifier)
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
                try markHandled(identifier)
            } catch {
                // Persisted pending state remains untouched for the next retry.
            }
        }
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

    private func markHandled(_ identifier: String) throws {
        var state = try loadState()
        state.pending.removeAll {
            notificationIdentifier(for: $0) == identifier
        }
        state.handledAt[identifier] = Date().timeIntervalSince1970
        pruneHandled(&state)
        try saveState(state)
    }

    private func merge(_ older: [ResetEvent], _ newer: [ResetEvent]) -> [ResetEvent] {
        var seen = Set<String>()
        return (older + newer).filter {
            seen.insert(notificationIdentifier(for: $0)).inserted
        }
    }

    private func notificationIdentifier(for event: ResetEvent) -> String {
        "ios-\(event.stableID)"
    }

    private func pruneHandled(_ state: inout PersistentState) {
        let cutoff = Date().addingTimeInterval(-handledRetention).timeIntervalSince1970
        state.handledAt = state.handledAt.filter { $0.value >= cutoff }
        if state.handledAt.count > maximumHandledEntries {
            state.handledAt = Dictionary(
                uniqueKeysWithValues: state.handledAt
                    .sorted { $0.value > $1.value }
                    .prefix(maximumHandledEntries)
                    .map { ($0.key, $0.value) }
            )
        }
    }

    private func loadState() throws -> PersistentState {
        guard let url = PhoneSnapshotStore.fileURL(named: filename) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistentState()
        }
        return try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: url))
    }

    private func saveState(_ state: PersistentState) throws {
        guard let url = PhoneSnapshotStore.fileURL(named: filename) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
}

final class ForegroundNotificationDelegate: NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    static let shared = ForegroundNotificationDelegate()

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
