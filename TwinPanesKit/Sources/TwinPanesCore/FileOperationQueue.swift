import Foundation

/// Every file operation the app runs (docs/plans/M6.md, D-e). Lives on the main actor;
/// each operation's work runs on its own dispatch queue, since it blocks while paused
/// or waiting for a conflict's answer.
@MainActor
public final class FileOperationQueue {
    /// Asks the user about a conflict; the operation waits for the answer.
    public typealias Asker = @MainActor (QueuedOperation, Conflict) async -> ConflictAnswer

    private let fileSystem: any FileOperationSystem
    public private(set) var operations: [QueuedOperation] = []
    private var observers: [UUID: () -> Void] = [:]
    /// How often progress may reach the main actor.
    private let progressInterval: Duration

    public init(
        fileSystem: any FileOperationSystem, progressInterval: Duration = .milliseconds(100)
    ) {
        self.fileSystem = fileSystem
        self.progressInterval = progressInterval
    }

    /// Calls `handler` on every change: an operation added, started, ended, or its
    /// progress moved. Keep the token; dropping it stops the calls.
    public func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        return ObservationToken { [weak self] in
            MainActor.assumeIsolated { _ = self?.observers.removeValue(forKey: id) }
        }
    }

    /// Queues `request`; it starts at once unless it waits its turn behind a copy or move.
    @discardableResult
    public func add(
        _ request: OperationRequest, scopes: [SecurityScope], ask: @escaping Asker
    ) -> QueuedOperation {
        let operation = QueuedOperation(request: request, scopes: scopes)
        operations.append(operation)
        changed()
        if !request.waitsItsTurn {
            start(operation, ask: ask)
        } else if turnHolder == nil {
            turnHolder = operation
            start(operation, ask: ask)
        } else {
            waiting.append((operation, ask))
        }
        return operation
    }

    /// The copy or move running now; the others wait in `waiting`, in order.
    private var turnHolder: QueuedOperation?
    private var waiting: [(QueuedOperation, Asker)] = []

    private func start(_ operation: QueuedOperation, ask: @escaping Asker) {
        operation.state = .running
        changed()
        let request = operation.request
        let control = operation.control
        let fileSystem = fileSystem
        let reporter = ProgressReporter(interval: progressInterval) { [weak self, weak operation] in
            guard let operation, operation.result == nil else { return }
            operation.progress = $0
            self?.changed()
        }
        let resolve = ConflictBridge { [weak operation] conflict in
            guard let operation else { return ConflictAnswer(.stop) }
            operation.state = .waitingForAnswer
            self.changed()
            let answer = await ask(operation, conflict)
            operation.state = .running
            self.changed()
            return answer
        }
        DispatchQueue(label: "FileOperationQueue.operation", qos: .userInitiated).async {
            let result = Self.run(
                request, fileSystem: fileSystem, control: control,
                resolve: resolve.answer(for:), progress: reporter.report)
            reporter.flush()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(operation, with: result) }
            }
        }
    }

    private nonisolated static func run(
        _ request: OperationRequest, fileSystem: any FileOperationSystem,
        control: OperationControl, resolve: (Conflict) -> ConflictAnswer,
        progress: (OperationProgress) -> Void
    ) -> OperationResult {
        switch request {
        case .copy(let sources, let destination):
            let planner = OperationPlanner(fileSystem: fileSystem)
            let walks = sources.map { planner.walk($0, isCancelled: { control.isCancelled }) }
            return .copied(
                TreeCopier(fileSystem: fileSystem).copy(
                    walks, into: destination, control: control, resolve: resolve,
                    progress: progress))
        case .move(let sources, let destination):
            return .moved(
                TreeMover(fileSystem: fileSystem).move(
                    sources, into: destination, control: control, resolve: resolve,
                    progress: progress))
        case .trash(let items):
            return .trashed(
                Trasher(fileSystem: fileSystem).trash(items, control: control, progress: progress))
        case .delete(let items):
            return .removed(
                TreeRemover(fileSystem: fileSystem).remove(
                    items, control: control, progress: progress))
        case .putBack(let items):
            return .moved(
                PutBack(fileSystem: fileSystem).putBack(
                    items, control: control, resolve: resolve, progress: progress))
        }
    }

    private func finish(_ operation: QueuedOperation, with result: OperationResult) {
        operation.state = .finished(result)
        operation.scopes = []
        for waiter in operation.waiters { waiter.resume(returning: result) }
        operation.waiters = []
        changed()
        guard operation === turnHolder else { return }
        turnHolder = nil
        if !waiting.isEmpty {
            let (next, ask) = waiting.removeFirst()
            turnHolder = next
            start(next, ask: ask)
        }
    }

    private func changed() {
        for observer in observers.values { observer() }
    }
}

/// Hands an operation's progress to the main actor at most once per `interval`, the
/// latest value each time, never one call per file (docs/plans/M6.md, D-e).
private final class ProgressReporter: @unchecked Sendable {
    // Unchecked: `latest` and `isScheduled` are only touched under `lock`.
    private let lock = NSLock()
    private var latest: OperationProgress?
    private var isScheduled = false
    private let interval: Duration
    private let deliver: @MainActor (OperationProgress) -> Void

    init(interval: Duration, deliver: @escaping @MainActor (OperationProgress) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func report(_ progress: OperationProgress) {
        lock.lock()
        latest = progress
        let schedule = !isScheduled
        isScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval / .seconds(1)) {
            self.deliverLatest()
        }
    }

    /// Delivers what's left, once the operation is done.
    func flush() {
        DispatchQueue.main.async { self.deliverLatest() }
    }

    private func deliverLatest() {
        lock.lock()
        let progress = latest
        latest = nil
        isScheduled = false
        lock.unlock()
        guard let progress else { return }
        MainActor.assumeIsolated { deliver(progress) }
    }
}

/// Lets an operation's thread wait for the user's answer to a conflict, asked on the
/// main actor.
private final class ConflictBridge: Sendable {
    private let ask: @MainActor (Conflict) async -> ConflictAnswer

    init(ask: @escaping @MainActor (Conflict) async -> ConflictAnswer) { self.ask = ask }

    /// Blocks the operation's thread until the main actor has the answer.
    func answer(for conflict: Conflict) -> ConflictAnswer {
        let ready = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        Task { @MainActor in
            box.answer = await ask(conflict)
            ready.signal()
        }
        ready.wait()
        return box.answer
    }
}

private final class AnswerBox: @unchecked Sendable {
    // Unchecked: written on the main actor before the semaphore is signalled, read on
    // the operation's thread after it's waited for.
    var answer = ConflictAnswer(.stop)
}
