import Combine
import Foundation
import UsageCore
import UserNotifications
import WidgetKit

@MainActor
final class WatchDashboardModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var notificationError: String?

    private var started = false
    private var updateTask: Task<Void, Never>?
    private let notifications = WatchResetNotificationCoordinator.shared

    init() {
        snapshot = WatchSnapshotStore.load()
    }

    deinit {
        updateTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        WatchConnectivityReceiver.shared.activate()
        refreshFromStore()
        Task { [weak self] in
            guard let self else { return }
            self.notificationStatus = await self.notifications.authorizationStatus()
        }
        updateTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .watchUsageSnapshotDidChange
            ) {
                guard !Task.isCancelled else { return }
                self?.snapshot = WatchSnapshotStore.load()
            }
        }
    }

    func refreshFromStore() {
        snapshot = WatchSnapshotStore.load()
        WidgetCenter.shared.reloadTimelines(
            ofKind: WatchOverlaySharedConstants.widgetKind
        )
    }

    func enableNotifications() async {
        do {
            _ = try await notifications.requestAuthorization()
            notificationStatus = await notifications.authorizationStatus()
            notificationError = nil
        } catch {
            notificationStatus = await notifications.authorizationStatus()
            notificationError = "Reset-Hinweise konnten nicht aktiviert werden."
        }
    }
}
