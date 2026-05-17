import Foundation

enum ExportAsyncTimeout {
    struct TimedOut: LocalizedError {
        let operation: String
        let seconds: Double

        var errorDescription: String? {
            "\(operation) timed out after \(Int(seconds))s"
        }
    }

    static func run<T>(
        seconds: Double,
        operation: String,
        body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut(operation: operation, seconds: seconds)
            }
            guard let result = try await group.next() else {
                throw TimedOut(operation: operation, seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}
