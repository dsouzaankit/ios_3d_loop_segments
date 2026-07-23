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

/// System bordered chrome + light press haptic.
struct HapticBorderedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BorderedButtonStyle().makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { AppHaptics.tap(.light) }
            }
    }
}

/// System plain chrome + soft press haptic (list / navigation rows).
struct HapticPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlainButtonStyle().makeBody(configuration: configuration)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { AppHaptics.tap(.soft) }
            }
    }
}

extension PrimitiveButtonStyle where Self == AppHapticPrimitiveButtonStyle {
    static var appHaptic: AppHapticPrimitiveButtonStyle { AppHapticPrimitiveButtonStyle() }
}

extension ButtonStyle where Self == HapticBorderedButtonStyle {
    static var hapticBordered: HapticBorderedButtonStyle { HapticBorderedButtonStyle() }
}

extension ButtonStyle where Self == HapticPlainButtonStyle {
    static var hapticPlain: HapticPlainButtonStyle { HapticPlainButtonStyle() }
}
