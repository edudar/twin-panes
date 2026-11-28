import Synchronization

/// The activity popover's hide after a linger (D53): `schedule()` runs `hide` once, `linger`
/// later, unless `cancel()` comes first or the `AutoHide` is released. No AppKit, so the
/// timing is testable without a window; whether to hide at all stays with the popover.
///
/// Main actor. `hide` runs on the main actor; a zero or negative linger runs it at once.
@MainActor
final class AutoHide {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let linger: Duration
    private let sleep: Sleep
    private let hide: @MainActor () -> Void
    /// Behind a lock so `deinit`, which isn't isolated to the main actor, can cancel it.
    private let pending = Mutex<Task<Void, Never>?>(nil)

    /// `sleep` waits out the linger and throws once its task is cancelled.
    init(
        linger: Duration, sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        hide: @escaping @MainActor () -> Void
    ) {
        self.linger = linger
        self.sleep = sleep
        self.hide = hide
    }

    deinit {
        pending.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    var isScheduled: Bool { pending.withLock { $0 != nil } }

    /// The linger in progress, for tests that wait for it to end.
    var pendingTask: Task<Void, Never>? { pending.withLock { $0 } }

    /// Starts the linger; one already running keeps its original end.
    func schedule() {
        guard linger > .zero else {
            cancel()
            hide()
            return
        }
        guard !isScheduled else { return }
        let (linger, sleep) = (linger, sleep)
        let task = Task { [weak self] in
            do { try await sleep(linger) } catch { return }  // cancelled: no hide
            guard !Task.isCancelled else { return }
            self?.finish()
        }
        pending.withLock { $0 = task }
    }

    /// Stops the linger in progress, if any; `hide` doesn't run for it.
    func cancel() {
        pending.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func finish() {
        pending.withLock { $0 = nil }
        hide()
    }
}
