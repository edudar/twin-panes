import Foundation
import Testing

@testable import TwinPanesCore

/// Outside changes to a session's file (M3c step 10).
@MainActor
@Suite(.serialized) struct EditorSessionWatchingTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("EditorSessionWatchingTests-\(UUID().uuidString)")
    let url: URL

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<64).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func session() throws -> EditorSession {
        let session = try EditorSession(
            url: url, sessionsRoot: folder.appendingPathComponent("Sessions"))
        session.startWatching()
        return session
    }

    func type(_ session: EditorSession, _ byte: UInt8, at offset: UInt64) throws {
        try session.overwrite(
            Data([byte]), at: offset, selectionBefore: offset..<(offset + 1),
            selectionAfter: offset..<(offset + 1))
    }

    func rewrite(_ byte: UInt8) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: byte, count: 64))
        try handle.close()
    }

    final class Waiter {
        let signal = SearchSignal()
        var fileChanges = 0
    }

    /// Waits for the session to report `change`; counts `.fileChanged` along the way.
    func wait(for change: EditorSession.Change, from session: EditorSession) async -> Waiter {
        let waiter = Waiter()
        session.observe(waiter) { seen in
            if seen == .fileChanged { waiter.fileChanges += 1 }
            if seen == change { waiter.signal.signal() }
        }
        return waiter
    }

    @Test func aCleanSessionReloadsSilently() async throws {
        defer { cleanUp() }
        let session = try session()
        let waiter = await wait(for: .edited, from: session)
        try rewrite(0x11)
        await waiter.signal.wait()
        #expect(try session.snapshot.read(0..<2) == Data([0x11, 0x11]) && !session.isDirty)
        #expect(waiter.fileChanges == 0 && session.fileState == .unchanged)
    }

    /// Done-when for M3c: an outside change never touches unsaved edits, and saving
    /// afterwards writes the whole version.
    @Test func unsavedEditsSurviveAnOutsideChange() async throws {
        defer { cleanUp() }
        let session = try session()
        try type(session, 0xAA, at: 5)
        let waiter = await wait(for: .fileChanged, from: session)
        try rewrite(0xEE)
        await waiter.signal.wait()
        #expect(session.fileState == .changed && session.isDirty)
        #expect(try session.snapshot.read(4..<7) == Data([4, 0xAA, 6]))
        let wanted = try session.snapshot.read(0..<64)
        try await session.save()
        #expect(try Data(contentsOf: url) == wanted && session.fileState == .unchanged)
    }

    /// Done-when for M3c: our own saves never count as outside changes.
    @Test func savingRaisesNothing() async throws {
        defer { cleanUp() }
        let session = try session()
        try type(session, 0xAA, at: 5)
        try await session.save()
        try type(session, 0xBB, at: 6)
        try await session.save()
        let waiter = await wait(for: .fileChanged, from: session)
        try type(session, 0xCC, at: 7)
        try rewrite(0xEE)  // the first outside change: only it is reported
        await waiter.signal.wait()
        #expect(waiter.fileChanges == 1)
    }

    @Test func aDeletedFileIsWrittenBackBySave() async throws {
        defer { cleanUp() }
        let session = try session()
        try type(session, 0xAA, at: 5)
        let waiter = await wait(for: .fileChanged, from: session)
        try FileManager.default.removeItem(at: url)
        await waiter.signal.wait()
        #expect(session.fileState == .deleted && session.isDirty)
        try await session.save()
        #expect(try Data(contentsOf: url)[4..<7] == Data([4, 0xAA, 6]))
        #expect(session.fileState == .unchanged && !session.isDirty)
    }

    @Test func reloadDropsTheEditsForTheFileOnDisk() async throws {
        defer { cleanUp() }
        let session = try session()
        try type(session, 0xAA, at: 5)
        let made = try #require(session.folder)
        let waiter = await wait(for: .fileChanged, from: session)
        try rewrite(0x22)
        await waiter.signal.wait()
        try session.reloadDiscardingEdits()
        #expect(try session.snapshot.read(4..<7) == Data([0x22, 0x22, 0x22]))
        #expect(!session.isDirty && !session.canUndo && session.fileState == .unchanged)
        #expect(session.folder == nil && !FileManager.default.fileExists(atPath: made.url.path))
    }
}
