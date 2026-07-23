import SwiftUI
import UIKit

/// Shared tap / confirmation haptics for SwiftUI controls.
enum AppHaptics {
    enum Kind {
        case light
        case medium
        case soft
    }

    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let notifyGen = UINotificationFeedbackGenerator()

    static func prepare() {
        lightGen.prepare()
        mediumGen.prepare()
        softGen.prepare()
        notifyGen.prepare()
    }

    static func tap(_ kind: Kind = .light) {
        switch kind {
        case .light:
            lightGen.impactOccurred(intensity: 0.85)
            lightGen.prepare()
        case .medium:
            mediumGen.impactOccurred(intensity: 0.9)
            mediumGen.prepare()
        case .soft:
            softGen.impactOccurred(intensity: 0.7)
            softGen.prepare()
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
