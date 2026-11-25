import Foundation
import Testing

@testable import TwinPanesCore

/// The app-wide queue of file operations (docs/plans/M6.md, D-e, step 10).
@MainActor
@Suite struct FileOperationQueueTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileOperationQueueTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = ScriptedFileOperationSystem()

    var source: URL { root.appendingPathComponent("src", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }

    /// src/ a.txt, b.txt, c.txt; dest/ empty
    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt"] {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }
        system.useTrash(root.appendingPathComponent("Trash", isDirectory: true))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func src(_ name: String) -> URL { source.appendingPathComponent(name) }

    static let never: FileOperationQueue.Asker = { _, _ in ConflictAnswer(.stop) }

    /// A second copy waits for the first; a trash runs at once beside it.
    @Test func copiesTakeTurnsAndTrashDoesnt() async {
        defer { cleanUp() }
        let gate = DispatchSemaphore(value: 0)
        system.reportChunks(1) { path, _ in if path.hasSuffix("a.txt") { gate.wait() } }
        let queue = FileOperationQueue(fileSystem: system)
        let first = queue.add(.copy([src("a.txt")], into: destination), scopes: [], ask: Self.never)
        let second = queue.add(
            .copy([src("b.txt")], into: destination), scopes: [], ask: Self.never)
        let trash = queue.add(.trash([src("c.txt")]), scopes: [], ask: Self.never)
        guard case .queued = second.state else {
            Issue.record("the second copy waits: \(second.state)")
            gate.signal()
            return
        }
        _ = await trash.finished()
        #expect(first.result == nil && second.result == nil)
        gate.signal()
        _ = await second.finished()
        #expect(first.result != nil && second.result?.failures.isEmpty == true)
        #expect(system.copied.map { ($0 as NSString).lastPathComponent } == ["a.txt", "b.txt"])
    }

    @Test func aConflictWaitsForTheAnswer() async throws {
        defer { cleanUp() }
        try Data("old".utf8).write(to: destination.appendingPathComponent("a.txt"))
        let queue = FileOperationQueue(fileSystem: system)
        var stateWhenAsked: QueuedOperation.State?
        let operation = queue.add(.copy([src("a.txt")], into: destination), scopes: []) {
            operation, _ in
            stateWhenAsked = operation.state
            return ConflictAnswer(.replace)
        }
        guard case .copied(let outcome) = await operation.finished() else {
            Issue.record("a copy's result")
            return
        }
        guard case .waitingForAnswer = stateWhenAsked else {
            Issue.record("asked while waiting: \(String(describing: stateWhenAsked))")
            return
        }
        #expect(outcome.replaced.count == 1)
    }

    /// The tab that asked may be gone: the operation keeps its access until it ends.
    @Test func scopesAreHeldUntilTheEnd() async {
        defer { cleanUp() }
        let queue = FileOperationQueue(fileSystem: system)
        weak var held: SecurityScope?
        let operation: QueuedOperation = {
            let scope = SecurityScope(url: source)
            held = scope
            return queue.add(.trash([src("a.txt")]), scopes: [scope], ask: Self.never)
        }()
        if operation.result == nil { #expect(held != nil) }
        _ = await operation.finished()
        #expect(held == nil)
    }

    /// Many small files reach the main actor as a few progress updates, the last one
    /// complete.
    @Test func progressIsThrottled() async throws {
        defer { cleanUp() }
        let many = root.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<2_000 {
            FileManager.default.createFile(
                atPath: many.appendingPathComponent("f\(index)").path, contents: Data([1]))
        }
        let queue = FileOperationQueue(fileSystem: system, progressInterval: .milliseconds(50))
        var updates = 0
        let token = queue.observe { updates += 1 }
        let clock = ContinuousClock()
        let start = clock.now
        let operation = queue.add(.copy([many], into: destination), scopes: [], ask: Self.never)
        _ = await operation.finished()
        let elapsed = clock.now - start
        withExtendedLifetime(token) {}
        // Two changes for starting and ending, plus at most one update per interval.
        #expect(updates <= 4 + Int(elapsed / .milliseconds(50)), "\(updates) in \(elapsed)")
        #expect(operation.progress.itemsDone == 2_001)
    }

    @Test func cancellingStopsTheOperation() async {
        defer { cleanUp() }
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        system.reportChunks(1) { path, _ in
            guard path.hasSuffix("a.txt") else { return }
            started.signal()
            gate.wait()
        }
        let queue = FileOperationQueue(fileSystem: system)
        let operation = queue.add(
            .copy([src("a.txt"), src("b.txt")], into: destination), scopes: [], ask: Self.never)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                started.wait()
                continuation.resume()
            }
        }
        operation.cancel()
        gate.signal()
        let result = await operation.finished()
        #expect(result.wasCancelled)
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("b.txt").path))
    }
}
