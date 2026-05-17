import Foundation

/// In-memory byte cache so AVFoundation resource requests can finish within ~30s.
final class WebDAVRangeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var contentLength: Int64?
    private var spans: [(start: Int64, end: Int64, data: Data)] = []

    func storeContentLength(_ length: Int64) {
        lock.lock()
        contentLength = length
        lock.unlock()
    }

    func contentLengthValue() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return contentLength
    }

    func storeRange(offset: Int64, data: Data) {
        guard !data.isEmpty else { return }
        let end = offset + Int64(data.count) - 1
        lock.lock()
        spans.append((offset, end, data))
        lock.unlock()
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
