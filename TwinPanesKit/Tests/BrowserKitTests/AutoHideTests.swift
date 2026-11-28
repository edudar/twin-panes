import Synchronization
import Testing

@testable import BrowserKit

/// The activity popover's linger before it hides (D53).
@MainActor
@Suite struct AutoHideTests {
    /// A sleep the test ends by hand; cancelling its task ends it with an error.
    final class HeldSleep: Sendable {
        private struct State {
            var requested: [Duration] = []
            var waiting: CheckedContinuation<Void, any Error>?
            var isReleased = false
            var isCancelled = false
        }
        private let state = Mutex(State())

        var requested: [Duration] { state.withLock { $0.requested } }

        func sleep(_ duration: Duration) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let ending = state.withLock { state -> Result<Void, any Error>? in
                        state.requested.append(duration)
                        if state.isCancelled { return .failure(CancellationError()) }
                        if state.isReleased { return .success(()) }
                        state.waiting = continuation
                        return nil
                    }
                    if let ending { continuation.resume(with: ending) }
                }
            } onCancel: {
                state.withLock { state in
                    state.isCancelled = true
                    return state.waiting.take()
                }?.resume(throwing: CancellationError())
            }
        }

        func release() {
            state.withLock { state in
                state.isReleased = true
                return state.waiting.take()
            }?.resume()
        }
    }

    let held = HeldSleep()
    let hides = Counter()

    @MainActor final class Counter {
        var count = 0
    }

    func makeAutoHide(linger: Duration = .seconds(3)) -> AutoHide {
        AutoHide(linger: linger, sleep: { [held] in try await held.sleep($0) }) {
            [hides] in hides.count += 1
        }
    }

    @Test func hidesOnceAfterTheLinger() async {
        let autoHide = makeAutoHide()
        autoHide.schedule()
        #expect(autoHide.isScheduled)
        let linger = autoHide.pendingTask
        held.release()
        await linger?.value
        #expect(held.requested == [.seconds(3)])
        #expect(hides.count == 1)
        #expect(!autoHide.isScheduled)
    }

    @Test func schedulingAgainKeepsTheLingerInProgress() async {
        let autoHide = makeAutoHide()
        autoHide.schedule()
        let linger = autoHide.pendingTask
        autoHide.schedule()
        #expect(autoHide.pendingTask == linger)
        held.release()
        await linger?.value
        #expect(hides.count == 1)
    }

    @Test func aZeroLingerHidesAtOnce() {
        let autoHide = makeAutoHide(linger: .zero)
        autoHide.schedule()
        #expect(hides.count == 1)
        #expect(!autoHide.isScheduled)
        #expect(held.requested.isEmpty)
    }

    @Test func cancellingStopsTheHide() async throws {
        let autoHide = makeAutoHide()
        autoHide.schedule()
        let linger = try #require(autoHide.pendingTask)
        autoHide.cancel()
        #expect(!autoHide.isScheduled)
        try #require(linger.isCancelled)  // else the held sleep never ends
        await linger.value
        #expect(hides.count == 0)
    }

    @Test func releasingCancelsTheLinger() throws {
        var autoHide: AutoHide? = makeAutoHide()
        autoHide?.schedule()
        let linger = try #require(autoHide?.pendingTask)
        autoHide = nil
        #expect(linger.isCancelled)
    }

    @Test func aLingerCanStartAgainAfterItHid() async {
        let autoHide = makeAutoHide()
        autoHide.schedule()
        held.release()
        await autoHide.pendingTask?.value
        autoHide.schedule()
        await autoHide.pendingTask?.value
        #expect(hides.count == 2)
        #expect(held.requested == [.seconds(3), .seconds(3)])
    }
}
