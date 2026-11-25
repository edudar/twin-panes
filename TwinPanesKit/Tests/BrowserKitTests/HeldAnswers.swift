import TwinPanesCore

/// Holds an operation at its conflict until the test answers.
@MainActor
final class HeldAnswers {
    private var waiting: CheckedContinuation<ConflictAnswer, Never>?
    private var askedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> ConflictAnswer {
        await withCheckedContinuation { continuation in
            waiting = continuation
            for waiter in askedWaiters { waiter.resume() }
            askedWaiters = []
        }
    }

    /// Returns once an operation is waiting for an answer.
    func asked() async {
        if waiting != nil { return }
        await withCheckedContinuation { askedWaiters.append($0) }
    }

    func answer(_ answer: ConflictAnswer) {
        waiting?.resume(returning: answer)
        waiting = nil
    }
}
