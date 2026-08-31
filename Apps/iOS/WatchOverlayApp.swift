import SwiftUI

@main
struct WatchOverlayApp: App {
    @UIApplicationDelegateAdaptor(WatchOverlayAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CompanionModel.shared

    init() {
        ForegroundNotificationDelegate.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            CompanionDashboardView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .task {
                    model.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        model.resumeAfterForeground()
                    } else if newPhase == .background {
                        BackgroundRefreshCoordinator.shared.schedule()
                    }
                }
        }
    }
}
