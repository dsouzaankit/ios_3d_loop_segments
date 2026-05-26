import UIKit

/// Hidden first responder so lock-screen / Control Center Now Playing receives remote commands.
final class RemoteResponderUIView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

@MainActor
enum NowPlayingFirstResponder {
    private static weak var responderView: RemoteResponderUIView?

    static func attach(_ view: RemoteResponderUIView) {
        responderView = view
    }

    static func activate() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        if let responderView, !responderView.isFirstResponder {
            responderView.becomeFirstResponder()
        }
    }

    static func deactivate() {
        responderView?.resignFirstResponder()
    }
}
