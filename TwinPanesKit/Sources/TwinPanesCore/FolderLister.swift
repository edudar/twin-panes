import Darwin
import Foundation
import Synchronization

/// Lists one folder off the main actor and hands the entries over in batches
/// (docs/plans/M4.md, D-a), so a big folder shows its first rows at once and never
/// stalls the UI. Hidden entries are always included; the listing model filters them.
///
/// Once `cancel()` has been called on the main actor, nothing more is delivered: every
/// event checks the flag on the main actor just before it's handed over. A new
/// navigation cancels the old lister, so a late batch can never reach the new folder.
public final class FolderLister: Sendable {
    public enum Event: Sendable, Equatable {
        /// Entries in the order the file system gives them; unsorted.
        case batch([DirectoryEntry])
        /// The whole folder has been delivered.
        case done
        case failed(DirectoryReaderError)
    }

    private struct State {
        var started = false
        var cancelled = false
    }

    public let folder: URL
    let batchSize: Int
    let maxBatchSize: Int
    let interval: Duration
    private let state = Mutex(State())
    private let group = DispatchGroup()

    /// A batch goes out at its size or when `interval` has passed since the last one,
    /// whichever comes first. The first is `batchSize`, so the first rows show at once;
    /// each next one may be four times bigger, up to `maxBatchSize`, so a huge folder
    /// arrives in a few deliveries rather than a stream of them queueing on the main
    /// actor (docs/plans/M4.md, step 13).
    public init(
        folder: URL, batchSize: Int = 500, maxBatchSize: Int = 20_000,
        interval: Duration = .milliseconds(50)
    ) {
        self.folder = folder.standardizedFileURL
        let clampedBatch = max(1, batchSize)
        self.batchSize = clampedBatch
        self.maxBatchSize = max(clampedBatch, maxBatchSize)
        self.interval = interval
    }

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Starts listing; `deliver` gets the events, in order, on the main actor.
    public func start(deliver: @escaping @MainActor @Sendable (Event) -> Void) {
        let shouldStart = state.withLock { state in
            guard !state.started, !state.cancelled else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            run { event in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if !self.isCancelled { deliver(event) }
                    }
                }
            }
        }
    }

    /// Stops the listing; call on the main actor so no further event arrives.
    public func cancel() { state.withLock { $0.cancelled = true } }

    /// Calls `body` on the main queue once the background work has ended and every event
    /// it sent has been handled (or dropped). For tests and teardown.
    public func whenFinished(_ body: @escaping @MainActor @Sendable () -> Void) {
        group.notify(queue: .main) { MainActor.assumeIsolated { body() } }
    }

    private func run(_ send: (Event) -> Void) {
        if let error = Self.check(folder) { return send(.failed(error)) }
        var enumerationError: (any Error)?
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: DirectoryReader.keys,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else { return send(.failed(Self.check(folder) ?? .failed(folder, "can’t enumerate"))) }
        var batch: [DirectoryEntry] = []
        let clock = ContinuousClock()
        var last = clock.now
        var size = batchSize
        while true {
            if isCancelled { return }
            let done = autoreleasepool { () -> Bool in
                guard let url = enumerator.nextObject() as? URL else { return true }
                batch.append(DirectoryReader.entry(url))
                return false
            }
            if done { break }
            if batch.count >= size || clock.now - last >= interval {
                send(.batch(batch))
                let (next, overflow) = size.multipliedReportingOverflow(by: 4)
                size = overflow ? maxBatchSize : min(next, maxBatchSize)
                batch.removeAll(keepingCapacity: true)
                last = clock.now
            }
        }
        if isCancelled { return }
        if let enumerationError {
            return send(
                .failed(
                    Self.check(folder) ?? .failed(folder, enumerationError.localizedDescription)))
        }
        if !batch.isEmpty { send(.batch(batch)) }
        send(.done)
    }

    /// Why `folder` can't be listed, or nil if it can.
    public static func check(_ folder: URL) -> DirectoryReaderError? {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd >= 0 {
            Darwin.close(fd)
            return nil
        }
        switch errno {
        case ENOENT: return .notFound(folder)
        case ENOTDIR: return .notAFolder(folder)
        case EACCES, EPERM: return .needsAccess(folder)
        case let code: return .failed(folder, String(cString: strerror(code)))
        }
    }
}
