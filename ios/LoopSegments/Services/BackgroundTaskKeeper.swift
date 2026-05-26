import UIKit

/// Extends allowed runtime while segment export runs (screen can lock briefly).
enum BackgroundTaskKeeper {
    private static var taskId: UIBackgroundTaskIdentifier = .invalid
    private static var renewalTask: Task<Void, Never>?
    /// Renew before iOS typically expires a single background task (~30s).
    private static let renewalIntervalSeconds: UInt64 = 25

    static func begin() {
        end()
        startTask()
        startRenewalLoop()
    }

    static func end() {
        renewalTask?.cancel()
        renewalTask = nil
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
    }

    private static func startRenewalLoop() {
        renewalTask?.cancel()
        renewalTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: renewalIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                renewTask()
            }
        }
    }

    private static func startTask() {
        taskId = UIApplication.shared.beginBackgroundTask(withName: "SegmentExport") {
            Task { @MainActor in
                renewTask()
            }
        }
    }

    private static func renewTask() {
        let previous = taskId
        let next = UIApplication.shared.beginBackgroundTask(withName: "SegmentExport") {
            Task { @MainActor in
                renewTask()
            }
        }
        if previous != .invalid {
            UIApplication.shared.endBackgroundTask(previous)
        }
        taskId = next
    }
}
