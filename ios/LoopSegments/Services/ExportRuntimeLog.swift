import Foundation

/// Mirrors selected lines into the active `export_latest.txt` while export runs.
enum ExportRuntimeLog {
    private static let lock = NSLock()
    private static var sink: ((String) -> Void)?

    static func setMirror(_ handler: ((String) -> Void)?) {
        lock.lock()
        sink = handler
        lock.unlock()
    }

    static func mirror(_ message: String) {
        SearchDebugLog.log(message)
        lock.lock()
        let handler = sink
        lock.unlock()
        handler?(message)
    }
}
