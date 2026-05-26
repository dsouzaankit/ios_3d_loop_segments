import SwiftUI

/// Invisible anchor in the view hierarchy for `becomeFirstResponder()` (lock-screen media controls).
struct NowPlayingFirstResponderAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> RemoteResponderUIView {
        let view = RemoteResponderUIView()
        view.isUserInteractionEnabled = false
        NowPlayingFirstResponder.attach(view)
        return view
    }

    func updateUIView(_ uiView: RemoteResponderUIView, context: Context) {}
}
