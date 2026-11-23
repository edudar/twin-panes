import Darwin
import Foundation
import Synchronization
import Testing

@testable import TwinPanesCore

/// The real file system, but a save can be held at its flush until `release()`, or
/// made to fail there. Counts the staged files it opens (one per save).
private final class GatedFileSystem: FileSystem {
    let real = RealFileSystem()
    let holding: Bool
    let failing = Mutex(false)
    let saves = Mutex(0)
    let entered = SearchSignal()
    private let gate = DispatchSemaphore(value: 0)

    init(holding: Bool = false) { self.holding = holding }

    func release() { gate.signal() }

    func replacementDirectory(for url: URL) throws -> URL {
        try real.replacementDirectory(for: url)
    }
    func clone(_ source: URL, to destination: URL) throws {
        try real.clone(source, to: destination)
    }
    func copy(_ source: URL, to destination: URL) throws { try real.copy(source, to: destination) }
    func availableCapacity(for url: URL) -> UInt64? { real.availableCapacity(for: url) }
    func openForWriting(_ url: URL) throws -> Int32 {
        saves.withLock { $0 += 1 }
        return try real.openForWriting(url)
    }
    func write(_ data: Data, to descriptor: Int32, at offset: UInt64, path: String) throws {
        try real.write(data, to: descriptor, at: offset, path: path)
    }
    func truncate(_ descriptor: Int32, to length: UInt64, path: String) throws {
        try real.truncate(descriptor, to: length, path: path)
    }
    func fullSync(_ descriptor: Int32, path: String) throws {
        if holding {
            entered.signal()
            gate.wait()  // on the save queue, not a Swift concurrency thread
        }
        if failing.withLock({ $0 }) { throw FileSystemError("flush", path, errno: EIO) }
        try real.fullSync(descriptor, path: path)
    }
    func close(_ descriptor: Int32) { real.close(descriptor) }
    func replaceItem(at url: URL, with staged: URL) throws {
        try real.replaceItem(at: url, with: staged)
    }
    func removeItem(at url: URL) { real.removeItem(at: url) }
}

@MainActor
@Suite struct EditorSessionSavingTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("EditorSessionSavingTests-\(UUID().uuidString)")
    let url: URL

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<64).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    fileprivate func session(_ fs: GatedFileSystem = GatedFileSystem()) throws -> EditorSession {
        try EditorSession(
            url: url, addDirectory: folder.appendingPathComponent("add"),
            saver: Saver(fileSystem: fs))
    }

    func type(_ session: EditorSession, _ byte: UInt8, at offset: UInt64) throws {
        try session.overwrite(
            Data([byte]), at: offset, selectionBefore: offset..<(offset + 1),
            selectionAfter: offset..<(offset + 1))
    }

    func disk(_ offset: Int) throws -> UInt8 { try Data(contentsOf: url)[offset] }

    final class Changes { var list: [EditorSession.Change] = [] }

    @Test func savesAndUndoAfterASaveRestoresTheOriginal() async throws {
        defer { cleanUp() }
        let session = try session()
        let changes = Changes()
        session.observe(changes) { changes.list.append($0) }
        let opened = session.identity
        try type(session, 0xAA, at: 5)
        try await session.save()
        #expect(try !session.isDirty && !session.isSaving && disk(5) == 0xAA)
        #expect(try session.identity != opened && session.identity == FileIdentity(url: url))
        #expect(changes.list == [.edited, .saving, .saved, .saving])

        _ = session.undo()
        #expect(session.isDirty)
        try await session.save()
        #expect(try !session.isDirty && disk(5) == 5)
    }

    /// Done-when for M3b: typing during a save keeps the new edits, and the tab stays
    /// dirty with them; the file holds what was current when the save started.
    @Test func typingDuringASaveKeepsTheNewEdits() async throws {
        defer { cleanUp() }
        let fs = GatedFileSystem(holding: true)
        let session = try session(fs)
        try type(session, 0xAA, at: 5)
        let saving = Task { try await session.save() }
        await fs.entered.wait()
        #expect(session.isSaving)
        try type(session, 0xBB, at: 6)
        fs.release()
        try await saving.value
        #expect(try disk(5) == 0xAA && disk(6) == 6)
        #expect(session.isDirty && !session.isSaving)
        #expect(try session.snapshot.read(5..<7) == Data([0xAA, 0xBB]))
    }

    /// While a save runs, more saves queue once: two writes in all, the second with
    /// everything typed by the time it starts.
    @Test func savesRunOneAtATimeAndQueueOnce() async throws {
        defer { cleanUp() }
        let fs = GatedFileSystem(holding: true)
        let session = try session(fs)
        try type(session, 1, at: 1)
        let first = Task { try await session.save() }
        await fs.entered.wait()
        try type(session, 2, at: 2)
        let second = Task { try await session.save() }
        let third = Task { try await session.save() }
        await Task.yield()
        try type(session, 3, at: 3)
        fs.release()
        fs.release()
        try await first.value
        try await second.value
        try await third.value
        #expect(fs.saves.withLock { $0 } == 2)
        #expect(try disk(1) == 1 && disk(2) == 2 && disk(3) == 3)
        #expect(!session.isDirty && !session.isSaving)
    }

    @Test func aFailedSaveChangesNothing() async throws {
        defer { cleanUp() }
        let fs = GatedFileSystem()
        fs.failing.withLock { $0 = true }
        let session = try session(fs)
        let opened = session.identity
        try type(session, 0xAA, at: 5)
        await #expect(throws: FileSystemError.self) { try await session.save() }
        #expect(session.isDirty && !session.isSaving && session.identity == opened)
        #expect(try disk(5) == 5)
        fs.failing.withLock { $0 = false }
        try await session.save()
        #expect(try !session.isDirty && disk(5) == 0xAA)
    }
}
