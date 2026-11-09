import Foundation

extension URL {
    /// The URL as safe to write to a log. Export logs are served on the LAN without a login,
    /// and a pasted source link can carry a password or a signed token. Keeps scheme, host,
    /// port and path; drops user info, query and fragment. `?…` marks a query that was removed.
    var redactedForLog: String {
        guard var parts = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "\(scheme ?? "url")://(unreadable URL)"
        }
        let hadQuery = parts.percentEncodedQuery != nil
        parts.user = nil
        parts.password = nil
        parts.percentEncodedQuery = nil
        parts.fragment = nil
        return (parts.string ?? "\(scheme ?? "url")://\(host ?? "")") + (hadQuery ? "?…" : "")
    }
}
