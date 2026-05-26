import Foundation

/// Live WebDAV folder-walk progress for Browse search UI.
struct WebDAVSearchProgress: Sendable {
    enum Phase: Sendable {
        case discoveringRoots
        case listingFolder
    }

    let phase: Phase
    let folderPath: String?
    let foldersVisited: Int
    let folderLimit: Int
    let queueDepth: Int
    let resultsFound: Int
    let elapsedSeconds: Double
    let timeoutSeconds: Double

    var displayLocation: String {
        switch phase {
        case .discoveringRoots:
            return "discovering roots"
        case .listingFolder:
            guard let folderPath else { return "…" }
            return Self.shortFolderLabel(path: folderPath)
        }
    }

    /// Single-line status for Browse + periodic `search_debug.txt` lines.
    func uiStatusLine() -> String {
        switch phase {
        case .discoveringRoots:
            var line = "WebDAV: discovering folders"
            if timeoutSeconds > 0 {
                line += " (≤\(Int(timeoutSeconds))s)"
            }
            line += " · \(Int(elapsedSeconds))s elapsed"
            return line
        case .listingFolder:
            var line = "WebDAV: \(displayLocation) · \(foldersVisited)/\(folderLimit) folders"
            if queueDepth > 0 {
                line += " · \(queueDepth) queued"
            }
            if resultsFound > 0 {
                line += " · \(resultsFound) hit\(resultsFound == 1 ? "" : "s")"
            }
            if let eta = estimatedSecondsRemaining {
                line += " · ~\(Int(ceil(eta)))s left"
            } else if timeoutSeconds > elapsedSeconds {
                let cap = Int(ceil(timeoutSeconds - elapsedSeconds))
                line += " · ≤\(cap)s left"
            }
            return line
        }
    }

    /// ETA from visit rate, capped by the search timeout budget.
    var estimatedSecondsRemaining: Double? {
        guard phase == .listingFolder, foldersVisited >= 3, folderLimit > foldersVisited else {
            return nil
        }
        let rate = elapsedSeconds / Double(foldersVisited)
        guard rate > 0.05 else { return nil }
        let byRate = rate * Double(folderLimit - foldersVisited)
        let byTimeout = timeoutSeconds - elapsedSeconds
        guard byTimeout > 0 else { return nil }
        return min(byRate, byTimeout)
    }

    static func shortFolderLabel(path: String, maxLength: Int = 40) -> String {
        let normalized = WebDAVURLBuilder.directoryListingPath(path)
        if normalized == "/" { return "/" }
        let trimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "/" }
        if trimmed.count <= maxLength { return trimmed }
        let name = (trimmed as NSString).lastPathComponent
        return "…/\(name)"
    }
}
