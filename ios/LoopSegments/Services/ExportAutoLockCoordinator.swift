import UIKit

/// Keeps the screen on while the Export screen is visible or an export is running (`isIdleTimerDisabled`).
/// System Auto-Lock cannot be read or set by the app; deep links to Auto-Lock often fail on iOS 18+.
@MainActor
enum ExportAutoLockCoordinator {
    static let manualPath = "Settings → Display & Brightness → Auto-Lock"
    /// Works from Shortcuts on many iOS versions; tried first when opening Settings.
    static let autoLockSettingsURLString = "prefs:root=DISPLAY&path=AUTOLOCK"

    private static var exportPageVisible = false
    private static var exportRunning = false

    static func setExportPageVisible(_ visible: Bool) {
        exportPageVisible = visible
        applyIdleTimer()
    }

    static func exportDidStart() {
        exportRunning = true
        applyIdleTimer()
    }

    static func exportDidEnd() {
        exportRunning = false
        applyIdleTimer()
    }

    private static func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = exportPageVisible || exportRunning
    }

    /// Best-effort open Settings near Display / Auto-Lock. Returns false if nothing accepted the URL.
    /// Callers should still show `manualPath` — sub-paths are unreliable on recent iOS.
    @discardableResult
    static func openAutoLockSettings() async -> Bool {
        let candidates = [
            autoLockSettingsURLString,
            "App-Prefs:root=DISPLAY&path=AUTOLOCK",
            "App-Prefs:root=DISPLAY&path=AutoLock",
            "prefs:root=Display&path=AutoLock",
            "App-Prefs:root=DISPLAY",
            "prefs:root=DISPLAY",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if await openURL(url) {
                return true
            }
        }
        return false
    }

    private static func openURL(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { accepted in
                continuation.resume(returning: accepted)
            }
        }
    }
}
