import CoreServices
import Foundation
import Testing

@testable import TwinPanesCore

/// FSEvents on one folder (docs/plans/M4.md, D-f, step 8).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct FolderWatcherTests {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderWatcherTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    @MainActor final class Seen {
        var changes: [FolderWatcher.Change] = []
        var names: Set<String> {
            changes.reduce(into: []) { if case .names(let n) = $1 { $0.formUnion(n) } }
        }
        var waiting: (check: (Seen) -> Bool, done: CheckedContinuation<Void, Never>)?

        func add(_ change: FolderWatcher.Change) {
            changes.append(change)
            if let waiting, waiting.check(self) {
                self.waiting = nil
                waiting.done.resume()
            }
        }

        /// Returns once `check` holds, or fails the test after 10 s rather than hang.
        func until(
            _ check: @escaping (Seen) -> Bool, sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            if check(self) { return }
            let deadline = Task { @MainActor in
                try await Task.sleep(for: .seconds(10))
                guard let waiting = self.waiting else { return }
                self.waiting = nil
                Issue.record(
                    "no such change within 10 s: \(self.changes)", sourceLocation: sourceLocation)
                waiting.done.resume()
            }
            await withCheckedContinuation { waiting = (check, $0) }
            deadline.cancel()
        }
    }

    func watch(_ folder: URL? = nil) -> (FolderWatcher, Seen) {
        let seen = Seen()
        let watcher = FolderWatcher(folder: folder ?? dir) { seen.add($0) }
        #expect(watcher.start(latency: 0.05))
        return (watcher, seen)
    }

    @Test func createDeleteAndRenameAreReported() async throws {
        defer { cleanUp() }
        let (watcher, seen) = watch()
        defer { watcher.stop() }
        let file = dir.appendingPathComponent("new.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        await seen.until { $0.names.contains("new.txt") }
        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("moved.txt"))
        await seen.until { $0.names.contains("moved.txt") }
        let before = seen.changes.count
        try FileManager.default.removeItem(at: dir.appendingPathComponent("moved.txt"))
        await seen.until {
            $0.changes.dropFirst(before).contains {
                if case .names(let names) = $0 { return names.contains("moved.txt") }
                return false
            }
        }
        #expect(seen.names.isSuperset(of: ["new.txt", "moved.txt"]))
    }

    /// Changes inside a subfolder aren't the folder's; a second watcher on the subfolder
    /// shows the event really happened.
    @Test func aSubfolderChangeIsNotReported() async throws {
        defer { cleanUp() }
        let (watcher, seen) = watch()
        let (inner, innerSeen) = watch(dir.appendingPathComponent("sub"))
        defer {
            watcher.stop()
            inner.stop()
        }
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("sub/deep.txt").path, contents: nil)
        await innerSeen.until { $0.names.contains("deep.txt") }
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("marker").path, contents: nil)
        await seen.until { $0.names.contains("marker") }
        #expect(!seen.names.contains("deep.txt"))
    }

    @Test func nothingArrivesAfterStop() async throws {
        defer { cleanUp() }
        let (stopped, stoppedSeen) = watch()
        let (other, otherSeen) = watch()
        defer { other.stop() }
        stopped.stop()
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("late").path, contents: nil)
        await otherSeen.until { $0.names.contains("late") }
        #expect(stoppedSeen.changes.isEmpty)
    }

    /// A watcher stopped before its background start never runs; one left running
    /// reports changes once it says it has started.
    @Test func startingInTheBackground() async throws {
        defer { cleanUp() }
        let seen = Seen()
        let stopped = FolderWatcher(folder: dir) { seen.add($0) }
        let wasRunning = await withCheckedContinuation { done in
            stopped.stop()
            stopped.startSoon(latency: 0.05) { done.resume(returning: $0) }
        }
        #expect(!wasRunning)
        let later = Seen()
        let running = FolderWatcher(folder: dir) { later.add($0) }
        #expect(
            await withCheckedContinuation { done in
                running.startSoon(latency: 0.05) { done.resume(returning: $0) }
            })
        defer { running.stop() }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("bg").path, contents: nil)
        await later.until { !$0.names.isEmpty }
        #expect(seen.changes.isEmpty)
    }

    @Test func deletingTheFolderReportsItGone() async throws {
        let (watcher, seen) = watch()
        defer { watcher.stop() }
        try FileManager.default.removeItem(at: dir)
        await seen.until { $0.changes.contains(.folderGone) }
    }

    @Test func childUnmountReportsEntryNotFolderGone() {
        defer { cleanUp() }
        let watcher = FolderWatcher(folder: dir) { _ in }
        let change = watcher.change(
            paths: [watcher.path + "/Backup"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)])
        #expect(change == .names(["Backup"]))
    }

    @Test func selfAndAncestorUnmountReportFolderGone() {
        defer { cleanUp() }
        let watcher = FolderWatcher(folder: dir) { _ in }
        let selfUnmount = watcher.change(
            paths: [watcher.path + "/"],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)])
        #expect(selfUnmount == .folderGone)
        let parent = URL(fileURLWithPath: watcher.path).deletingLastPathComponent().path
        let ancestorUnmount = watcher.change(
            paths: [parent],
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)])
        #expect(ancestorUnmount == .folderGone)
    }

    @Test func nonCanonicalCasePathMatchesFSEventsPath() throws {
        defer { cleanUp() }
        let mixed = dir.appendingPathComponent("SubCase", isDirectory: true)
        try FileManager.default.createDirectory(at: mixed, withIntermediateDirectories: false)
        let lower = dir.appendingPathComponent("subcase", isDirectory: true)
        guard FileManager.default.fileExists(atPath: lower.path) else { return }
        let canonical = FolderWatcher(folder: mixed) { _ in }.path
        let nonCanonical = FolderWatcher(folder: lower) { _ in }.path
        #expect(nonCanonical == canonical)
    }

    @Test func trailingSlashSelfEventWhenReplacedByFileReportsFolderGone() throws {
        defer { cleanUp() }
        let target = dir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let watcher = FolderWatcher(folder: target) { _ in }
        try FileManager.default.removeItem(at: target)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let change = watcher.change(paths: [watcher.path + "/"], flags: [0])
        #expect(change == .folderGone)
    }

    @Test func doubleStartReturnsFalse() {
        defer { cleanUp() }
        let watcher = FolderWatcher(folder: dir) { _ in }
        defer { watcher.stop() }
        #expect(watcher.start(latency: 0.05))
        #expect(!watcher.start(latency: 0.05))
    }
}
