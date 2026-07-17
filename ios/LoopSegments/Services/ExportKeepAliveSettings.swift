import Foundation

/// User settings for silent lock-screen audio that keeps export runnable in the background.
enum ExportKeepAliveSettings {
    static let enabledKey = "export_keep_alive_enabled"
    static let timeoutHoursKey = "export_keep_alive_timeout_hours"
    static let preferLockScreenControlsKey = "export_keep_alive_prefer_lock_screen_controls"

    /// Default `true` when the key has never been set (fresh install / reinstall).
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// `0` = no timeout during export (loops until user stops **Keep Alive** on the lock screen, then up to **sessionDurationSeconds** when export ends or the app is foregrounded).
    static var timeoutHours: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: timeoutHoursKey) as? Double
            return stored ?? 0
        }
        set { UserDefaults.standard.set(newValue, forKey: timeoutHoursKey) }
    }

    static var timeoutSeconds: TimeInterval? {
        let hours = timeoutHours
        guard hours > 0 else { return nil }
        return hours * 3600
    }

    /// Default `false` (**mix mode**): `.playback` + mix with others. When `true`, exclusive playback and lock-screen Now Playing card.
    static var preferLockScreenControls: Bool {
        get { UserDefaults.standard.bool(forKey: preferLockScreenControlsKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferLockScreenControlsKey) }
    }

    /// Auto-stop after the app is foregrounded or export leaves the running state (finish, pause, cancel).
    static let sessionDurationSeconds: TimeInterval = 60 * 60

    static let timeoutOptions: [(label: String, hours: Double)] = [
        ("Until export ends", 0),
        ("1 hour", 1),
        ("2 hours", 2),
        ("4 hours", 4),
        ("8 hours", 8),
    ]
}
