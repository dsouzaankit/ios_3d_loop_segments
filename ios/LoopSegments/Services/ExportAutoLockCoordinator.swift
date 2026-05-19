import UIKit

/// Keeps the screen on while export runs in the foreground (`isIdleTimerDisabled`).
/// System Auto-Lock cannot be changed by the app; use `openAutoLockSettings()` from the export screen if needed.
@MainActor
enum ExportAutoLockCoordinator {
    static func exportDidStart() {
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func exportDidEnd() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    static func openAutoLockSettings() {
        let candidates = [
            "App-Prefs:root=DISPLAY&path=AUTOLOCK",
            "prefs:root=DISPLAY&path=AUTOLOCK",
            "App-prefs:DISPLAY&path=AUTO_LOCK",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
        if let settings = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settings, options: [:], completionHandler: nil)
        }
    }
}
