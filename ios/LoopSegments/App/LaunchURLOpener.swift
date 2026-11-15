import UIKit

/// Opens a link handed to the app as a launch argument, then quits the app.
///
/// The PC's `deploy.ps1` launches Loop Segments over USB (DVT) with
/// `-openURL sidestore://install?url=http://<PC>:8766/LoopSegments.ipa`. Over USB the PC can launch an
/// app but cannot open a link, and only the front app may open one, so this app does it: SideStore then
/// shows its Install dialog. The app quits right after, so SideStore never installs over a running copy
/// (those installs often hang).
///
/// Only a PC the phone trusts over USB can pass launch arguments; tapping the icon passes none, so a
/// normal launch is unchanged. Only the schemes below are accepted.
enum LaunchURLOpener {
    static let argumentName = "-openURL"
    /// sidestore: install; shortcuts: run a shortcut (e.g. Refresh All); localdevvpn: enable / disable the VPN
    /// (deploy.ps1 switches it back off after an install when it was off before).
    static let allowedSchemes: Set<String> = ["sidestore", "shortcuts", "localdevvpn"]

    @MainActor private static var handled = false

    /// The link to open, if the launch arguments ask for one with an allowed scheme.
    static func requestedURL(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: argumentName), index + 1 < arguments.count else {
            return nil
        }
        let raw = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            return nil
        }
        return url
    }

    /// Call when the app is active. Opens the requested link once per launch.
    /// - Parameter canQuit: false keeps the app running (an export is in flight).
    @MainActor
    static func openIfRequested(canQuit: Bool) {
        guard !handled else { return }
        handled = true
        guard let url = requestedURL(from: ProcessInfo.processInfo.arguments) else { return }
        SearchDebugLog.log("Launch link: opening \(url.scheme ?? "")://\(url.host ?? "")")
        UIApplication.shared.open(url, options: [:]) { opened in
            SearchDebugLog.log("Launch link: \(opened ? "opened" : "not opened (app missing?)")")
            guard opened, canQuit else { return }
            // Give iOS a moment to switch apps, then quit so SideStore can replace this app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                exit(0)
            }
        }
    }
}
