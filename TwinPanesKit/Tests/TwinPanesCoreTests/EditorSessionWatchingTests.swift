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

    func session(saver: Saver = Saver()) throws -> EditorSession {
        let session = try EditorSession(
            url: url, saver: saver, sessionsRoot: folder.appendingPathComponent("Sessions"))
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
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
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
        defer {
            session.stopWatching()
            session.close()
        }
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
        defer {
            session.stopWatching()
            session.close()
        }
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
        let fs = GatedFileSystem(holding: true)
        let session = try session(saver: Saver(fileSystem: fs))
        defer {
            session.stopWatching()
            session.close()
        }
        let waiter = await wait(for: .fileChanged, from: session)
        try type(session, 0xAA, at: 5)
        let saving = Task { try await session.save() }
        await fs.entered.wait()
        try type(session, 0xBB, at: 6)  // typed mid-save: isDirty stays true when save finishes
        fs.release()
        try await saving.value
        #expect(session.isDirty && session.fileState == .unchanged && waiter.fileChanges == 0)

        fs.holding.withLock { $0 = false }
        try await session.save()
        #expect(!session.isDirty && waiter.fileChanges == 0)

        try type(session, 0xCC, at: 7)
        try rewrite(0xEE)  // the first outside change: only it is reported
        await waiter.signal.wait()
        #expect(waiter.fileChanges == 1)
    }

    @Test func aDeletedFileIsWrittenBackBySave() async throws {
        defer { cleanUp() }
        let session = try session()
        defer {
            session.stopWatching()
            session.close()
        }
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
        defer {
            session.stopWatching()
            session.close()
        }
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

    @Test func failedReloadPreservesUnsavedEditsAndCrashJournal() throws {
        defer { cleanUp() }
        let session = try session()
        defer {
            session.stopWatching()
            session.close()
        }
        try type(session, 0xAA, at: 5)
        let made = try #require(session.folder)
        #expect(session.journal != nil)

        try FileManager.default.removeItem(at: url)
        #expect(throws: ByteSourceError.self) { try session.reloadDiscardingEdits() }

        #expect(session.isDirty)
        #expect(try session.snapshot.read(4..<7) == Data([4, 0xAA, 6]))
        #expect(session.folder?.url == made.url)
        #expect(session.journal != nil)
        #expect(FileManager.default.fileExists(atPath: made.url.path))
    }
}
