import UIKit

/// Extends allowed runtime while segment export runs (screen can lock briefly).
enum BackgroundTaskKeeper {
    private static var taskId: UIBackgroundTaskIdentifier = .invalid

    static func begin() {
        end()
        taskId = UIApplication.shared.beginBackgroundTask(withName: "SegmentExport") {
            end()
        }
    }

    static func end() {
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
    }
}
