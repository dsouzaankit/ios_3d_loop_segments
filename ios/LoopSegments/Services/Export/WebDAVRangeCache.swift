import Foundation

/// In-memory byte cache for prefetch (MP4 head + tail). Read-only during AVFoundation streaming.
final class WebDAVRangeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var contentLength: Int64?
    private var spans: [(start: Int64, end: Int64, data: Data)] = []
    /// Prefetch only. Loader must not grow this during export or large files OOM-jetsam.
    private let maxStoredBytes: Int

    init(maxStoredBytes: Int = 4 * 1024 * 1024) {
        self.maxStoredBytes = maxStoredBytes
    }

    func storeContentLength(_ length: Int64) {
        guard length > 0 else { return }
        lock.lock()
        if let existing = contentLength, existing >= length {
            lock.unlock()
            return
        }
        contentLength = length
        lock.unlock()
    }

    func contentLengthValue() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return contentLength
    }

    private func storedByteCountLocked() -> Int {
        spans.reduce(0) { $0 + $1.data.count }
    }

    /// `isIndexTail` — always keep MP4 `moov` at EOF even if cache is full (dropping it breaks track discovery).
    func storeRange(offset: Int64, data: Data, isIndexTail: Bool = false) {
        guard !data.isEmpty else { return }
        let end = offset + Int64(data.count) - 1
        lock.lock()
        defer { lock.unlock() }
        if !isIndexTail, storedByteCountLocked() + data.count > maxStoredBytes {
            return
        }
        if isIndexTail, storedByteCountLocked() + data.count > maxStoredBytes {
            spans.removeAll()
        }
        spans.append((offset, end, data))
    }

    func storedSpans() -> [(start: Int64, data: Data)] {
        lock.lock()
        let copy = spans.map { (start: $0.start, data: $0.data) }
        lock.unlock()
        return copy
    }

    func dataForRequest(offset: Int64, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard length > 0 else { return Data() }
        let reqEnd = offset + Int64(length) - 1
        var out = Data()
        out.reserveCapacity(length)
        var cursor = offset
        while cursor <= reqEnd {
            guard let span = spans.first(where: { cursor >= $0.start && cursor <= $0.end }) else {
                return nil
            }
            let index = Int(cursor - span.start)
            let take = min(Int(reqEnd - cursor) + 1, span.data.count - index)
            out.append(span.data.subdata(in: index ..< index + take))
            cursor += Int64(take)
        }
        return out.count == length ? out : nil
    }
}
