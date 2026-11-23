import CoreServices
import Foundation
import Synchronization

/// Watches one folder for changes to its entries with FSEvents (docs/plans/M4.md, D-f).
/// Events below the folder's own entries are ignored; what's left is coalesced over the
/// stream's latency into the set of names that changed, or into a request to list the
/// folder again when FSEvents dropped events or too much changed at once.
///
/// Changes arrive on the main actor. After `stop()` (on the main actor) none arrive.
public final class FolderWatcher: Sendable {
    public enum Change: Sendable, Equatable {
        /// These entries were created, removed, renamed or modified: read them again.
        case names(Set<String>)
        /// List the whole folder again.
        case relist
        /// The folder itself was deleted, moved or unmounted.
        case folderGone
    }

    public let folder: URL
    /// The folder's path as FSEvents reports it: `realpath`, since
    /// `resolvingSymlinksInPath` turns /private/var back into /var.
    let path: String
    let overflow: Int
    private let handler: @MainActor @Sendable (Change) -> Void
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "FolderWatcher", qos: .utility)

    private struct State: @unchecked Sendable {
        var stream: FSEventStreamRef?
        var relay: Unmanaged<Relay>?
        var stopped = false
    }

    /// What the stream's callback holds: the watcher, weakly, so the watcher can go away
    /// while the stream still runs; released on the stream's queue after it stops.
    private final class Relay {
        weak var watcher: FolderWatcher?
        init(_ watcher: FolderWatcher) { self.watcher = watcher }
    }

    /// More changed names than `overflow` in one delivery become `.relist`.
    public init(
        folder: URL, overflow: Int = 1_000,
        handler: @escaping @MainActor @Sendable (Change) -> Void
    ) {
        self.folder = folder
        path = Self.realPath(folder.path) ?? folder.path
        self.overflow = overflow
        self.handler = handler
    }

    deinit { stop() }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Starts the stream; false if FSEvents refused it.
    @discardableResult
    public func start(latency: TimeInterval = 0.2) -> Bool {
        let relay = Unmanaged.passRetained(Relay(self))
        var context = FSEventStreamContext(
            version: 0, info: relay.toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                nil, Self.callback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            relay.release()
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            relay.release()
            return false
        }
        state.withLock {
            $0.stream = stream
            $0.relay = relay
        }
        return true
    }

    /// Stops the stream; no change is delivered afterwards.
    public func stop() {
        let (stream, relay) = state.withLock { state in
            state.stopped = true
            defer { (state.stream, state.relay) = (nil, nil) }
            return (state.stream, state.relay)
        }
        guard let stream, let relay else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        // After any callback still running on the stream's serial queue.
        nonisolated(unsafe) let box = relay
        queue.async { box.release() }
    }

    private var isStopped: Bool { state.withLock { $0.stopped } }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        guard let watcher = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue().watcher
        else { return }
        let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let flags = (0..<count).map { flags[$0] }
        if let change = watcher.change(paths: paths, flags: flags) { watcher.deliver(change) }
    }

    /// What one delivery of events means for the folder; nil if nothing of it.
    func change(paths: [String], flags: [FSEventStreamEventFlags]) -> Change? {
        var names = Set<String>()
        var relist = false
        for (path, flag) in zip(paths, flags) {
            let flag = Int(flag)
            if flag & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount) != 0 {
                return .folderGone
            }
            if flag & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
                != 0
            {
                relist = true
            } else if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                // "Rescan this path and below": only the folder's business when the path
                // is the folder or above it, not one of its subfolders.
                let scan = path.hasSuffix("/") ? String(path.dropLast()) : path
                if self.path == scan || self.path.hasPrefix(scan + "/") || scan.isEmpty {
                    relist = true
                }
            }
            let url = URL(fileURLWithPath: path)
            if path == self.path {
                if !FileManager.default.fileExists(atPath: self.path) { return .folderGone }
            } else if url.deletingLastPathComponent().path == self.path {
                names.insert(url.lastPathComponent)
            }
        }
        if relist || names.count > overflow { return .relist }
        return names.isEmpty ? nil : .names(names)
    }

    private func deliver(_ change: Change) {
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                if !isStopped { handler(change) }
            }
        }
    }
}
