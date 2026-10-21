import BackgroundTasks
import Foundation

/// iOS decides whether and when to run background refresh. A foreground check
/// is always performed as the reliable catch-up path; no exact-time guarantee.
@MainActor
final class BackupScheduler {
    static let shared = BackupScheduler()
    static let identifier = "com.threemoments.diary.backup"
    weak var backup: BackupService?
    private var registered = false

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                self.schedule()
                let work = Task { @MainActor in await self.backup?.backupIfDue() }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }

    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        // Simulator, system settings, or system budget can reject submission.
        // This never replaces the foreground catch-up check.
        try? BGTaskScheduler.shared.submit(request)
    }
}
