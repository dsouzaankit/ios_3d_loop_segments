import Foundation

/// User settings for silent lock-screen audio that keeps export runnable in the background.
enum ExportKeepAliveSettings {
    static let enabledKey = "export_keep_alive_enabled"
    static let timeoutHoursKey = "export_keep_alive_timeout_hours"
    static let preferLockScreenControlsKey = "export_keep_alive_prefer_lock_screen_controls"

    /// Off by default — user opts in (battery / App Store expectations).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// `0` = no timeout (loops until export ends or user stops **Keep Alive** on the lock screen).
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

    /// Default `false`: mix with other audio (e.g. Evermusic) and don't try to own lock-screen controls.
    static var preferLockScreenControls: Bool {
        get { UserDefaults.standard.bool(forKey: preferLockScreenControlsKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferLockScreenControlsKey) }
    }

    static let timeoutOptions: [(label: String, hours: Double)] = [
        ("Until export ends", 0),
        ("1 hour", 1),
        ("2 hours", 2),
        ("4 hours", 4),
        ("8 hours", 8),
    ]
}
