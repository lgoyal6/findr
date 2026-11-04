import Foundation

/// Shared by the UI and background work; checking cancellation never waits on the UI thread.
final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false

    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !canceled
    }

    func cancel() {
        lock.lock()
        canceled = true
        lock.unlock()
    }
}
