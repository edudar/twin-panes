import Foundation

/// What the user asked an operation to do.
public enum OperationRequest: Sendable, Equatable {
    case copy([URL], into: URL)
    case move([URL], into: URL)
    case trash([URL])
    case delete([URL])

    /// Copies and moves wait their turn; trash and delete are quick and run at once
    /// (docs/plans/M6.md, D-e).
    var waitsItsTurn: Bool {
        switch self {
        case .copy, .move: true
        case .trash, .delete: false
        }
    }
}

/// What an operation did, once it ended.
public enum OperationResult: Sendable {
    case copied(CopyOutcome)
    case moved(MoveOutcome)
    case trashed(TrashOutcome)
    case removed(RemoveOutcome)

    public var failures: [FileSystemError] {
        switch self {
        case .copied(let outcome): outcome.failures
        case .moved(let outcome): outcome.failures
        case .trashed(let outcome): outcome.failures
        case .removed(let outcome): outcome.failures
        }
    }

    public var wasCancelled: Bool {
        switch self {
        case .copied(let outcome): outcome.wasCancelled
        case .moved(let outcome): outcome.wasCancelled
        case .trashed(let outcome): outcome.wasCancelled
        case .removed(let outcome): outcome.wasCancelled
        }
    }
}

/// One operation in the queue, as its progress row shows it.
@MainActor
public final class QueuedOperation: Identifiable {
    public enum State: Sendable {
        case queued, running, waitingForAnswer
        case finished(OperationResult)
    }

    public let id = UUID()
    public let request: OperationRequest
    public internal(set) var state = State.queued
    public internal(set) var progress = OperationProgress()
    let control = OperationControl()
    /// Held until the operation ends, whatever happens to the tab that asked (§5).
    var scopes: [SecurityScope]
    var waiters: [CheckedContinuation<OperationResult, Never>] = []

    init(request: OperationRequest, scopes: [SecurityScope]) {
        self.request = request
        self.scopes = scopes
    }

    public var isPaused: Bool { control.isPaused }
    public func pause() { control.pause() }
    public func resume() { control.resume() }
    public func cancel() { control.cancel() }

    public var result: OperationResult? {
        if case .finished(let result) = state { return result }
        return nil
    }

    /// Returns once the operation has ended.
    public func finished() async -> OperationResult {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// A handle that stops an observation when it's released.
public final class ObservationToken: Sendable {
    private let cancel: @Sendable () -> Void
    init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
