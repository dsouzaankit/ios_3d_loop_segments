import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        Group {
            if session.credentials != nil {
                BrowserView()
            } else {
                AuthView()
            }
        }
    }
}
