import Foundation
import Testing

@testable import TwinPanesCore

/// Reopening a session that crashed (M3c step 6). A crash is played by copying the
/// session's folder aside before the session closes (which would delete it).
@MainActor
@Suite struct SessionRecoveryTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionRecoveryTests-\(UUID().uuidString)")
    let url: URL
    var root: URL { folder.appendingPathComponent("Sessions") }
    var crashed: URL { folder.appendingPathComponent("Crashed") }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<100).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func type(_ session: EditorSession, _ byte: UInt8, at offset: UInt64) throws {
        try session.overwrite(
            Data([byte]), at: offset, selectionBefore: offset..<(offset + 1),
            selectionAfter: offset..<(offset + 1))
    }

    /// Copies the session's folder aside as a crash would leave it.
    func crash(_ session: EditorSession) throws -> SessionFolder {
        let made = try #require(session.folder)
        let place = crashed.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let copy = place.appendingPathComponent(made.url.lastPathComponent)
        try FileManager.default.copyItem(at: made.url, to: copy)
        return SessionFolder(url: copy)
    }

    @Test func aCrashedSessionComesBackDirtyWithItsEdits() async throws {
        defer { cleanUp() }
        let session = try EditorSession(url: url, sessionsRoot: root)
        try type(session, 0xAA, at: 1)
        try await session.save()
        try type(session, 0xBB, at: 2)
        let left = try crash(session)
        let expected = try session.snapshot.read(0..<100)

        #expect(SessionFolder.sweep(left.url.deletingLastPathComponent()) == [left])
        let recovered = try EditorSession(recovering: left)
        #expect(try recovered.snapshot.read(0..<100) == expected)
        #expect(recovered.isDirty && !recovered.canUndo)
        #expect(recovered.url.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
        #expect(recovered.folder == left)
        // The saved version is what's on disk; saving again writes only the new edit.
        let saved = EditSnapshot(
            tree: recovered.savedTree, original: recovered.buffer.original,
            add: recovered.buffer.add)
        #expect(try saved.read(0..<100) == Data(contentsOf: url))
        try type(recovered, 0xCC, at: 3)
        try await recovered.save()
        #expect(try Data(contentsOf: url)[1..<4] == Data([0xAA, 0xBB, 0xCC]))
        // It went on journaling: a second crash brings all of it back.
        let again = try EditorSession(recovering: try crash(recovered))
        #expect(try again.snapshot.read(0..<100) == recovered.snapshot.read(0..<100))
        #expect(!again.isDirty)
    }

    /// A record cut short by the crash is dropped; everything before it comes back.
    @Test func aTornJournalTailIsDropped() throws {
        defer { cleanUp() }
        let session = try EditorSession(url: url, sessionsRoot: root)
        try type(session, 0xAA, at: 1)
        let left = try crash(session)
        let handle = try FileHandle(forWritingTo: left.file(SessionJournal.fileName))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([40, 0, 0, 0, 1, 2]))  // half a record
        try handle.close()
        let recovered = try EditorSession(recovering: left)
        #expect(try recovered.snapshot.read(0..<3) == Data([0, 0xAA, 2]))
        try type(recovered, 0xBB, at: 2)  // appended after the cut, not after the garbage
        let again = try EditorSession(recovering: try crash(recovered))
        #expect(try again.snapshot.read(0..<3) == Data([0, 0xAA, 0xBB]))
    }

    /// The file is gone: the edits still come back, from the clone; Save As keeps them.
    @Test func editsSurviveTheFileGoingAway() async throws {
        defer { cleanUp() }
        let session = try EditorSession(url: url, sessionsRoot: root)
        try type(session, 0xAA, at: 1)
        let left = try crash(session)
        try FileManager.default.removeItem(at: url)
        let recovered = try EditorSession(recovering: left)
        #expect(try recovered.snapshot.read(0..<3) == Data([0, 0xAA, 2]))
        let elsewhere = folder.appendingPathComponent("rescued.bin")
        try await recovered.saveAs(to: elsewhere)
        #expect(try Data(contentsOf: elsewhere)[0..<3] == Data([0, 0xAA, 2]))
    }
}
