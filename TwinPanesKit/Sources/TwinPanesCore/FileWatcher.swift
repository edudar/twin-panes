import Darwin
import Foundation

/// Watches one file for writes, renames and deletion with a vnode `DispatchSource`
/// (docs/plans/M3c.md, D-c), on the main queue. A replace gives the path a new inode, so
/// the owner re-arms it with `watch(_:)` after handling an event.
@MainActor
final class FileWatcher {
    // Touched on the main actor only, and by deinit, which nothing else can run beside.
    nonisolated(unsafe) private var source: (any DispatchSourceFileSystemObject)?
    private let onEvent: @MainActor () -> Void

    init(onEvent: @escaping @MainActor () -> Void) { self.onEvent = onEvent }

    deinit { source?.cancel() }

    /// Starts watching the file now at `url` (stopping any earlier watch); a file that
    /// isn't there isn't watched.
    func watch(_ url: URL) {
        stop()
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib], queue: .main)
        let onEvent = self.onEvent
        source.setEventHandler { MainActor.assumeIsolated { onEvent() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
