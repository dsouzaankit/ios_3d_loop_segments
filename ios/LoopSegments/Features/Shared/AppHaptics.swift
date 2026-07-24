import SwiftUI
import UIKit

/// Shared tap / confirmation haptics for SwiftUI controls.
enum AppHaptics {
    enum Kind {
        case light
        case medium
        case soft
    }

    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private static let notifyGen = UINotificationFeedbackGenerator()

    static func prepare() {
        mediumGen.prepare()
        rigidGen.prepare()
        notifyGen.prepare()
    }

    /// Default is a clear medium impact (soft/light aliases map here so list taps are feelable).
    static func tap(_ kind: Kind = .medium) {
        switch kind {
        case .light, .soft:
            mediumGen.impactOccurred(intensity: 1.0)
            mediumGen.prepare()
        case .medium:
            rigidGen.impactOccurred(intensity: 1.0)
            rigidGen.prepare()
        }
    }

    static func tap(for role: ButtonRole?) {
        if role == .destructive {
            tap(.medium)
        } else {
            tap(.light)
        }
    }

    static func success() {
        notifyGen.notificationOccurred(.success)
        notifyGen.prepare()
    }
}
