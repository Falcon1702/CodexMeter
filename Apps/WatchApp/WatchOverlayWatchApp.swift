import SwiftUI
import UserNotifications
import WatchKit

final class WatchExtensionDelegate: NSObject, WKExtensionDelegate {
    func applicationDidFinishLaunching() {
        WatchForegroundNotificationDelegate.shared.install()
        WatchConnectivityReceiver.shared.activate()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchConnectivityReceiver.shared.retainBackgroundTask(connectivityTask)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

final class WatchForegroundNotificationDelegate: NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    static let shared = WatchForegroundNotificationDelegate()

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

@main
struct WatchOverlayWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchExtensionDelegate.self)
    private var extensionDelegate
    @StateObject private var model = WatchDashboardModel()

    var body: some Scene {
        WindowGroup {
            WatchDashboardView()
                .environmentObject(model)
                .task {
                    model.start()
                }
        }
    }
}
