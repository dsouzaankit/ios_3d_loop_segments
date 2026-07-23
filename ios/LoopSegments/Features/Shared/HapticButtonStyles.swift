import SwiftUI

/// Default environment style: system chrome via inner `.automatic`, haptic on successful tap.
struct AppHapticPrimitiveButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            AppHaptics.tap(for: configuration.role)
            configuration.trigger()
        } label: {
            configuration.label
        }
        // ButtonStyle overrides this PrimitiveButtonStyle in the environment — no recursion,
        // and list / toolbar buttons keep system appearance.
        .buttonStyle(.automatic)
    }
}

/// System bordered chrome + light tap haptic.
struct HapticBorderedButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            AppHaptics.tap(.light)
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(.bordered)
    }
}

/// System plain chrome + soft tap haptic (list / navigation rows).
struct HapticPlainButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            AppHaptics.tap(.soft)
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(.plain)
    }
}

extension PrimitiveButtonStyle where Self == AppHapticPrimitiveButtonStyle {
    static var appHaptic: AppHapticPrimitiveButtonStyle { AppHapticPrimitiveButtonStyle() }
}

extension PrimitiveButtonStyle where Self == HapticBorderedButtonStyle {
    static var hapticBordered: HapticBorderedButtonStyle { HapticBorderedButtonStyle() }
}

extension PrimitiveButtonStyle where Self == HapticPlainButtonStyle {
    static var hapticPlain: HapticPlainButtonStyle { HapticPlainButtonStyle() }
}
