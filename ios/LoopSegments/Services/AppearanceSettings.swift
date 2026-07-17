import Foundation

/// App + LAN appearance. Night mode is on by default.
enum AppearanceSettings {
    static let nightModeKey = "appearance_night_mode_enabled"

    /// Default `true` when the key has never been set.
    static var isNightModeEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: nightModeKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: nightModeKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: nightModeKey)
            NotificationCenter.default.post(name: .appearanceNightModeDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let appearanceNightModeDidChange = Notification.Name("appearanceNightModeDidChange")
}
