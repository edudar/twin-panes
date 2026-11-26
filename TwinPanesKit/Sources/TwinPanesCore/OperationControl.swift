import Foundation

/// Pauses, resumes and cancels a running operation from any thread; the operation
/// checks it between items and while copying a file (docs/plans/M6.md, D-c).
public final class OperationControl: @unchecked Sendable {
    // Unchecked: every stored property is read and written under `condition`'s lock.
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    public init() {}

    public func pause() { locked { paused = true } }
    public func resume() { locked { paused = false } }
    /// Also ends a pause.
    public func cancel() { locked { cancelled = true } }
    public var isCancelled: Bool { read { cancelled } }
    public var isPaused: Bool { read { paused && !cancelled } }

    /// Blocks while paused; false once cancelled, true to go on.
    public func checkpoint() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled { condition.wait() }
        return !cancelled
    }

    private func read<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    /// Runs `body` under the lock and wakes a paused `checkpoint` to look again.
    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        return body()
    }
}
