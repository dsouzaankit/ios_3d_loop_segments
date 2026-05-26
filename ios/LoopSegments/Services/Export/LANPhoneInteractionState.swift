import SwiftUI

/// Whether the phone will accept LAN pause/stop triggers (foreground + unlocked interaction).
enum LANPhoneInteractionState {
    private static let lock = NSLock()
    private static var scenePhaseSnapshot: ScenePhase = .active

    @MainActor
    static func update(scenePhase: ScenePhase) {
        lock.lock()
        scenePhaseSnapshot = scenePhase
        lock.unlock()
    }

    static var acceptsPauseStopTriggers: Bool {
        lock.lock()
        defer { lock.unlock() }
        return scenePhaseSnapshot == .active
    }

    static var pauseStopDisabledReason: String {
        lock.lock()
        let phase = scenePhaseSnapshot
        lock.unlock()
        switch phase {
        case .active:
            return ""
        case .inactive:
            return "Pause and stop are disabled while the phone is locked or Loop Segments is inactive. Unlock the phone and open the app in the foreground."
        case .background:
            return "Pause and stop are disabled while Loop Segments is in the background. Bring the app to the foreground (unlock the phone if needed)."
        @unknown default:
            return "Pause and stop are disabled until Loop Segments is open in the foreground on the phone."
        }
    }

    static func statusPayload() -> [String: Any] {
        let enabled = acceptsPauseStopTriggers
        return [
            "pauseStopEnabled": enabled,
            "pauseStopDisabledReason": enabled ? "" : pauseStopDisabledReason,
        ]
    }
}
