import CoreServices
import Foundation
import Testing

@testable import TwinPanesCore

/// How FolderWatcher turns FSEvents deliveries into changes (docs/plans/M4.md, D-f,
/// step 8), on synthetic events.
@Suite struct FolderWatcherCoalescingTests {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "FolderWatcherCoalescingTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// The coalescing rules, on synthetic events.
    @Test func droppedEventsOrTooManyNamesMeanListingAgain() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = FolderWatcher(folder: dir, overflow: 3) { _ in }
        let path = watcher.path
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        let names = (0..<3).map { "\(path)/f\($0)" }
        #expect(
            watcher.change(paths: names, flags: [file, file, file]) == .names(["f0", "f1", "f2"]))
        #expect(
            watcher.change(paths: names + ["\(path)/f3"], flags: Array(repeating: file, count: 4))
                == .relist)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(watcher.change(paths: [path], flags: [dropped]) == .relist)
        #expect(watcher.change(paths: ["/"], flags: [dropped]) == .relist)  // an ancestor
        // Below it: only the subfolder itself is read again.
        #expect(watcher.change(paths: ["\(path)/sub/"], flags: [dropped]) == .names(["sub"]))
        let kernel = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
        #expect(watcher.change(paths: ["/elsewhere"], flags: [kernel]) == .relist)
        #expect(watcher.change(paths: ["\(path)/sub/x"], flags: [file]) == nil)
        let root = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        #expect(watcher.change(paths: [path], flags: [root]) == .folderGone)
    }
}
