import Foundation

/// Every file operation the app runs (docs/plans/M6.md, D-e). Lives on the main actor;
/// work runs off-main on a serial queue (for turn-taking ops) or a bounded pool (for
/// immediate ops), since operations block while paused or waiting for a conflict's answer.
@MainActor
public final class FileOperationQueue {
    /// Asks the user about a conflict; the operation waits for the answer.
    public typealias Asker = @MainActor (QueuedOperation, Conflict) async -> ConflictAnswer

    private let fileSystem: any FileOperationSystem
    public private(set) var operations: [QueuedOperation] = []
    private var observers: [UUID: () -> Void] = [:]
    var observerCount: Int { observers.count }
    /// How often progress may reach the main actor.
    private let progressInterval: Duration
    private let serialQueue = DispatchQueue(label: "FileOperationQueue.serial", qos: .userInitiated)
    private let immediatePool: OperationQueue = {
        let pool = OperationQueue()
        pool.name = "FileOperationQueue.immediate"
        pool.qualityOfService = .userInitiated
        pool.maxConcurrentOperationCount = 4
        return pool
    }()

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
            Task { @MainActor [weak self] in _ = self?.observers.removeValue(forKey: id) }
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
            operation.onCancel = { [weak self, weak operation] in
                guard let self, let operation else { return }
                self.cancelQueued(operation)
            }
            waiting.append((operation, ask))
        }
        return operation
    }

    /// The copy or move running now; the others wait in `waiting`, in order.
    private var turnHolder: QueuedOperation?
    private var waiting: [(QueuedOperation, Asker)] = []

    private func cancelQueued(_ operation: QueuedOperation) {
        guard case .queued = operation.state else { return }
        waiting.removeAll { $0.0 === operation }
        let result: OperationResult
        switch operation.request {
        case .copy:
            var outcome = CopyOutcome()
            outcome.wasCancelled = true
            result = .copied(outcome)
        case .move, .putBack:
            var outcome = MoveOutcome()
            outcome.wasCancelled = true
            result = .moved(outcome)
        default:
            return
        }
        finish(operation, with: result)
    }

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
        let resolve = ConflictBridge(control: control) { [weak self, weak operation] conflict in
            guard let self, let operation, !operation.control.isCancelled else {
                return ConflictAnswer(.stop)
            }
            operation.state = .waitingForAnswer
            self.changed()
            let answer = await ask(operation, conflict)
            operation.onCancelWhileWaiting = nil
            if case .waitingForAnswer = operation.state {
                operation.state = .running
                self.changed()
            }
            return answer
        }
        operation.onCancel = { [weak resolve] in resolve?.cancel() }
        let work: @Sendable () -> Void = {
            let result = Self.run(
                request, fileSystem: fileSystem, control: control,
                resolve: resolve.answer(for:), progress: reporter.report)
            reporter.flush()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(operation, with: result) }
            }
        }
        if request.waitsItsTurn {
            serialQueue.async(execute: work)
        } else {
            immediatePool.addOperation(work)
        }
    }

    /// Runs `request` to the end on this thread; the queue's operations and tests use it.
    nonisolated static func run(
        _ request: OperationRequest, fileSystem: any FileOperationSystem,
        control: OperationControl, resolve: (Conflict) -> ConflictAnswer,
        progress: (OperationProgress) -> Void
    ) -> OperationResult {
        switch request {
        case .copy(let sources, let destination):
            let planner = OperationPlanner(fileSystem: fileSystem)
            let walks = sources.map { planner.walk($0, isCancelled: { control.isCancelled }) }
            var outcome = TreeCopier(fileSystem: fileSystem).copy(
                walks, into: destination, control: control, resolve: resolve,
                progress: progress)
            // Transient move-bookkeeping; clearing avoids retaining 100k URLs in history.
            outcome.finished = [:]
            outcome.merged = []
            return .copied(outcome)
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
        case .rename(let item, let name):
            return .renamed(
                Result { () throws(NameRefusal) in
                    try ItemNamer(fileSystem: fileSystem).rename(item, to: name)
                })
        case .makeFolder(let name, let folder):
            return .madeFolder(
                Result { () throws(NameRefusal) in
                    try ItemNamer(fileSystem: fileSystem).makeFolder(named: name, in: folder)
                })
        case .putBack(let items):
            return .moved(
                PutBack(fileSystem: fileSystem).putBack(
                    items, control: control, resolve: resolve, progress: progress))
        }
    }

    private func finish(_ operation: QueuedOperation, with result: OperationResult) {
        operation.state = .finished(result)
        operation.scopes = []
        operation.onCancel = nil
        operation.onCancelWhileWaiting = nil
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

    /// Removes `id` from `operations` once it has finished; no-op if still running.
    public func removeFinished(_ id: QueuedOperation.ID) {
        guard let index = operations.firstIndex(where: { $0.id == id && $0.result != nil }) else {
            return
        }
        operations.remove(at: index)
        changed()
    }
}

/// Hands an operation's progress to the main actor at most once per `interval`, delivering
/// the first tick immediately and the latest value thereafter (docs/plans/M6.md, D-e).
private final class ProgressReporter: @unchecked Sendable {
    // Unchecked: `latest`, `isScheduled`, and `lastDelivered` are only touched under `lock`.
    private let lock = NSLock()
    private var latest: OperationProgress?
    private var isScheduled = false
    private var lastDelivered: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let interval: Duration
    private let deliver: @MainActor (OperationProgress) -> Void

    init(interval: Duration, deliver: @escaping @MainActor (OperationProgress) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func report(_ progress: OperationProgress) {
        lock.lock()
        latest = progress
        guard !isScheduled else {
            lock.unlock()
            return
        }
        isScheduled = true
        let now = clock.now
        let delay = lastDelivered.flatMap { now - $0 < interval ? interval - (now - $0) : nil }
        if delay == nil { lastDelivered = now }
        lock.unlock()
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / .seconds(1)) {
                self.deliverLatest()
            }
        } else {
            DispatchQueue.main.async { self.deliverLatest() }
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
        if progress != nil { lastDelivered = clock.now }
        lock.unlock()
        guard let progress else { return }
        MainActor.assumeIsolated { deliver(progress) }
    }
}

/// Lets an operation's thread wait for the user's answer to a conflict, asked on the
/// main actor, or wake immediately if the operation is cancelled.
private final class ConflictBridge: @unchecked Sendable {
    // Unchecked: `pending` is only touched under `lock`; `control` and `ask` are Sendable.
    private let lock = NSLock()
    private let control: OperationControl
    private let ask: @MainActor (Conflict) async -> ConflictAnswer
    private var pending: (ready: DispatchSemaphore, answer: ConflictAnswer, resolved: Bool)?

    init(control: OperationControl, ask: @escaping @MainActor (Conflict) async -> ConflictAnswer) {
        self.control = control
        self.ask = ask
    }

    /// Blocks the operation's thread until the main actor has the answer or cancels.
    func answer(for conflict: Conflict) -> ConflictAnswer {
        let ready = DispatchSemaphore(value: 0)
        lock.lock()
        if control.isCancelled {
            lock.unlock()
            return ConflictAnswer(.stop)
        }
        pending = (ready, ConflictAnswer(.stop), false)
        lock.unlock()
        Task { @MainActor in
            let result = control.isCancelled ? ConflictAnswer(.stop) : await ask(conflict)
            self.resolve(ready: ready, with: result)
        }
        ready.wait()
        lock.lock()
        let answer = pending?.answer ?? ConflictAnswer(.stop)
        pending = nil
        lock.unlock()
        return answer
    }

    func cancel() {
        lock.lock()
        guard let current = pending, !current.resolved else {
            lock.unlock()
            return
        }
        pending = (current.ready, ConflictAnswer(.stop), true)
        lock.unlock()
        current.ready.signal()
    }

    private func resolve(ready: DispatchSemaphore, with answer: ConflictAnswer) {
        lock.lock()
        guard let current = pending, current.ready === ready, !current.resolved else {
            lock.unlock()
            return
        }
        pending = (ready, answer, true)
        lock.unlock()
        ready.signal()
    }
}
