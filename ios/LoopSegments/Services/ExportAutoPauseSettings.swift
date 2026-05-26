import Foundation

/// In-app cap: pause a long-running export at the checkpoint (resume via Start export).
enum ExportAutoPauseSettings {
    static let timeoutMinutesKey = "export_auto_pause_timeout_minutes"

    static let defaultTimeoutMinutes = 120

    /// Picker values (minutes).
    static let timeoutOptionsMinutes: [Int] = [3, 5, 15, 30, 60, 90, 120, 150]

    static var timeoutMinutes: Int {
        get {
            guard UserDefaults.standard.object(forKey: timeoutMinutesKey) != nil else {
                return defaultTimeoutMinutes
            }
            let stored = UserDefaults.standard.integer(forKey: timeoutMinutesKey)
            return timeoutOptionsMinutes.contains(stored) ? stored : defaultTimeoutMinutes
        }
        set {
            let minutes = timeoutOptionsMinutes.contains(newValue) ? newValue : defaultTimeoutMinutes
            UserDefaults.standard.set(minutes, forKey: timeoutMinutesKey)
        }
    }

    static var timeoutSeconds: TimeInterval {
        TimeInterval(timeoutMinutes) * 60
    }

    static func optionLabel(minutes: Int) -> String {
        switch minutes {
        case 3, 5, 15, 30:
            return "\(minutes) min"
        case 60:
            return "1 hour"
        case 90:
            return "1 h 30 min"
        case 120:
            return "2 hours (default)"
        case 150:
            return "2 h 30 min"
        default:
            return "\(minutes) min"
        }
    }

    static var autoPauseLogLine: String {
        let label = optionLabel(minutes: timeoutMinutes)
            .replacingOccurrences(of: " (default)", with: "")
        return "Auto-pause: \(label) reached — pausing export (resume later via Start export)."
    }
}
