import Foundation
import Testing

@testable import TwinPanesCore

@MainActor
@Suite struct EditorSessionTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("EditorSessionTests-\(UUID().uuidString)")
    let url: URL

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<64).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func session() throws -> EditorSession {
        try EditorSession(url: url, addDirectory: folder.appendingPathComponent("add"))
    }

    func bytes(_ session: EditorSession, _ range: Range<UInt64>) throws -> [UInt8] {
        Array(try session.snapshot.read(range))
    }

    /// Counts the changes a session reports to an owner that lives as long as the counter.
    final class Counter {
        var changes: [EditorSession.Change] = []
    }

    @Test func opensCleanWithTheFilesIdentityAndAccess() throws {
        defer { cleanUp() }
        let session = try session()
        #expect(session.length == 64 && !session.isDirty)
        #expect(session.access == .writable)
        #expect(session.identity == (try FileIdentity(url: url)))
        #expect(try bytes(session, 10..<12) == [10, 11])
        #expect(!session.canUndo && !session.canRedo)
        #expect(throws: ByteSourceError.self) {
            try EditorSession(url: folder.appendingPathComponent("missing"))
        }
    }

    @Test func editsUndoAndRedoAgainstTheSavedVersion() throws {
        defer { cleanUp() }
        let session = try session()
        let counter = Counter()
        session.observe(counter) { counter.changes.append($0) }

        try session.overwrite(Data([0xAA]), at: 4, selectionBefore: 4..<5, selectionAfter: 5..<6)
        try session.overwrite(
            Data([0xBB]), at: 5, selectionBefore: 5..<6, selectionAfter: 6..<7, coalescing: true)
        #expect(session.isDirty)
        #expect(try bytes(session, 4..<6) == [0xAA, 0xBB])
        #expect(session.undoStack.undoCount == 1)  // coalesced into one step
        #expect(counter.changes == [.edited, .edited])

        let back = try #require(session.undo())
        #expect(back.selection == 4..<5)
        #expect(!session.isDirty)  // back at the version on disk
        #expect(try bytes(session, 4..<6) == [4, 5])
        let forward = try #require(session.redo())
        #expect(forward.selection == 6..<7 && session.isDirty)
        #expect(session.redo() == nil)
        #expect(counter.changes.count == 4)
    }

    @Test func revertDropsTheEditsAndTheirHistory() throws {
        defer { cleanUp() }
        let session = try session()
        let counter = Counter()
        session.observe(counter) { counter.changes.append($0) }
        try session.overwrite(Data([1, 2]), at: 0, selectionBefore: 0..<1, selectionAfter: 2..<3)
        _ = session.undo()
        try session.overwrite(Data([3]), at: 9, selectionBefore: 9..<10, selectionAfter: 9..<10)
        session.revert()
        #expect(!session.isDirty && !session.canUndo && !session.canRedo)
        #expect(try bytes(session, 0..<2) == [0, 1] && (try bytes(session, 9..<10)) == [9])
        #expect(counter.changes.last == .edited && counter.changes.count == 4)
    }

    /// Edits that can't happen change nothing: not the bytes, the history or observers.
    @Test func refusedEditsLeaveNoTrace() throws {
        defer { cleanUp() }
        let writable = try session()
        let counter = Counter()
        writable.observe(counter) { counter.changes.append($0) }
        #expect(throws: ByteSourceError.self) {
            try writable.overwrite(
                Data([1, 2]), at: 63, selectionBefore: 63..<64, selectionAfter: 63..<64)
        }
        #expect(!writable.isDirty && !writable.canUndo && counter.changes.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let readOnly = try session()
        #expect(readOnly.access == .readOnly(.noWritePermission))
        #expect(throws: EditorSessionError.readOnly(.noWritePermission)) {
            try readOnly.overwrite(Data([1]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        }
        #expect(!readOnly.isDirty && !readOnly.canUndo)
    }

    @Test func observersAreDroppedWithTheirOwner() throws {
        defer { cleanUp() }
        let session = try session()
        var calls = 0
        var owner: Counter? = Counter()
        session.observe(owner!) { _ in calls += 1 }
        try session.overwrite(Data([1]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        owner = nil
        try session.overwrite(Data([2]), at: 1, selectionBefore: 1..<2, selectionAfter: 2..<3)
        #expect(calls == 1)
    }

    @Test func notifySkipsObserverWhoseOwnerWasReleasedByEarlierObserver() throws {
        defer { cleanUp() }
        let session = try session()
        let firstOwner = Counter()
        var secondOwner: Counter? = Counter()
        var firstCalls = 0
        var secondCalls = 0

        session.observe(firstOwner) { _ in
            firstCalls += 1
            secondOwner = nil
        }
        session.observe(secondOwner!) { _ in
            secondCalls += 1
        }

        try withExtendedLifetime(firstOwner) {
            try session.overwrite(Data([1]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        }
        #expect(firstCalls == 1 && secondCalls == 0)
    }
}
