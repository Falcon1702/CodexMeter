import BackgroundTasks
import OSLog
import UIKit
import UsageCore

final class WatchOverlayAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshCoordinator.shared.register()
        return true
    }
}

final class BackgroundRefreshCoordinator: @unchecked Sendable {
    private final class CompletionHandle: @unchecked Sendable {
        private weak var task: BGAppRefreshTask?

        init(task: BGAppRefreshTask) {
            self.task = task
        }

        func complete(success: Bool) {
            task?.setTaskCompleted(success: success)
        }
    }

    static let shared = BackgroundRefreshCoordinator()
    static let taskIdentifier = "com.example.codexmeter.refresh"

    private let scheduler = BGTaskScheduler.shared
    private let logger = Logger(
        subsystem: "com.example.codexmeter",
        category: "background-refresh"
    )
    private let stateLock = NSLock()
    private var registered = false

    private init() {}

    func register() {
        stateLock.lock()
        guard !registered else {
            stateLock.unlock()
            return
        }
        registered = true
        stateLock.unlock()

        let accepted = scheduler.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.shared.handle(refreshTask)
        }

        if !accepted {
            stateLock.lock()
            registered = false
            stateLock.unlock()
            logger.error("BGAppRefreshTask registration was rejected")
        }
    }

    func schedule(after date: Date = .now) {
        stateLock.lock()
        let canSchedule = registered
        stateLock.unlock()
        guard canSchedule else {
            logger.error("BGAppRefreshTask scheduling skipped before registration")
            return
        }

        scheduler.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = UsageRefreshPolicy.backgroundEarliestBeginDate(
            after: date
        )

        do {
            try scheduler.submit(request)
            logger.notice("BGAppRefreshTask scheduled")
        } catch {
            logger.error("BGAppRefreshTask scheduling failed")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule()

        let completion = CompletionHandle(task: task)
        let operation = Task { @MainActor in
            let model = CompanionModel.shared
            model.prepareForBackgroundRefresh()
            let succeeded = await model.refreshForBackgroundTask()
            completion.complete(success: succeeded && !Task.isCancelled)
        }

        task.expirationHandler = {
            operation.cancel()
        }
    }
}
