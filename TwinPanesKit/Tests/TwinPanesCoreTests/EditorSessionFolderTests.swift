import Darwin
import Foundation
import Testing

@testable import TwinPanesCore

/// The real file system, except that it can't clone (another volume).
private struct NoCloneFileSystem: FileSystem {
    let real = RealFileSystem()
    func replacementDirectory(for url: URL) throws -> URL {
        try real.replacementDirectory(for: url)
    }
    func clone(_ source: URL, to destination: URL) throws {
        throw FileSystemError("clone", source.path, errno: ENOTSUP)
    }
    func copy(_ source: URL, to destination: URL) throws { try real.copy(source, to: destination) }
    func availableCapacity(for url: URL) -> UInt64? { real.availableCapacity(for: url) }
    func openForWriting(_ url: URL) throws -> Int32 { try real.openForWriting(url) }
    func create(_ url: URL) throws -> Int32 { try real.create(url) }
    func move(_ source: URL, to destination: URL) throws { try real.move(source, to: destination) }
    func write(_ data: Data, to descriptor: Int32, at offset: UInt64, path: String) throws {
        try real.write(data, to: descriptor, at: offset, path: path)
    }
    func truncate(_ descriptor: Int32, to length: UInt64, path: String) throws {
        try real.truncate(descriptor, to: length, path: path)
    }
    func fullSync(_ descriptor: Int32, path: String) throws {
        try real.fullSync(descriptor, path: path)
    }
    func close(_ descriptor: Int32) { real.close(descriptor) }
    func replaceItem(at url: URL, with staged: URL) throws {
        try real.replaceItem(at: url, with: staged)
    }
    func removeItem(at url: URL) { real.removeItem(at: url) }
}

/// The session folder and clone made at the first edit (M3c step 3).
@MainActor
@Suite struct EditorSessionFolderTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("EditorSessionFolderTests-\(UUID().uuidString)")
    let url: URL
    var root: URL { folder.appendingPathComponent("Sessions") }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<64).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func session() throws -> EditorSession { try EditorSession(url: url, sessionsRoot: root) }

    func type(_ session: EditorSession, _ byte: UInt8, at offset: UInt64) throws {
        try session.overwrite(
            Data([byte]), at: offset, selectionBefore: offset..<(offset + 1),
            selectionAfter: offset..<(offset + 1))
    }

    /// Rewrites the file in place, as another app might, with a different mtime.
    func rewrite(_ byte: UInt8) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: byte, count: 64))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
    }

    @Test func viewingMakesNoFolderAndTheFirstEditClones() throws {
        defer { cleanUp() }
        let session = try session()
        #expect(session.folder == nil && session.buffer.add == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try type(session, 0xAA, at: 5)
        let made = try #require(session.folder)
        #expect(try made.manifest().identity == FileIdentity(url: url))
        #expect(try made.manifest().path == url.path)
        #expect(SessionFolder(url: session.buffer.original.url.deletingLastPathComponent()) == made)
        #expect(!session.isNarrowed && session.buffer.add != nil)
        #expect(try session.snapshot.read(4..<7) == Data([4, 0xAA, 6]))
    }

    /// Done-when for M3c: an outside rewrite doesn't change the bytes under the edits.
    @Test func editsSitOnTheCloneNotTheFile() throws {
        defer { cleanUp() }
        let session = try session()
        try type(session, 0xAA, at: 5)
        try rewrite(0xEE)
        #expect(try session.snapshot.read(4..<7) == Data([4, 0xAA, 6]))
    }

    /// A clean session whose file changed before the first edit starts from the new bytes.
    @Test func aFileChangedBeforeTheFirstEditIsReloaded() throws {
        defer { cleanUp() }
        let session = try session()
        try rewrite(0x11)
        try type(session, 0xAA, at: 5)
        #expect(try session.snapshot.read(4..<7) == Data([0x11, 0xAA, 0x11]))
        #expect(try session.folder?.manifest().identity == FileIdentity(url: url))
        _ = session.undo()
        #expect(try !session.isDirty && session.snapshot.read(5..<6) == Data([0x11]))
    }

    @Test func closingDeletesTheFolder() throws {
        defer { cleanUp() }
        let closing = try session()
        try type(closing, 1, at: 1)
        let made = try #require(closing.folder)
        closing.close()
        #expect(!FileManager.default.fileExists(atPath: made.url.path) && closing.folder == nil)
        var dropped: EditorSession? = try session()
        try type(dropped!, 2, at: 2)
        let again = try #require(dropped?.folder)
        dropped = nil  // a session that goes away closes too
        #expect(!FileManager.default.fileExists(atPath: again.url.path))
        #expect(SessionFolder.sweep(root).isEmpty)
    }

    /// With its clone, a session saves a hard-linked file in place (strategy B); a crash
    /// half way through such a save is rolled back when the session is recovered.
    @Test func hardLinkedFilesSaveInPlaceAndRollBack() async throws {
        defer { cleanUp() }
        let link = folder.appendingPathComponent("link.bin")
        try FileManager.default.linkItem(at: url, to: link)
        let session = try session()
        try type(session, 0xAA, at: 5)
        try await session.save()
        #expect(try Data(contentsOf: link)[5] == 0xAA && !session.isDirty)

        try type(session, 0xBB, at: 6)
        let made = try #require(session.folder)
        try SaveJournal.begin(
            made.file(SaveJournal.fileName), file: url, identity: FileIdentity(url: url),
            ranges: [6..<7], fileSystem: RealFileSystem())
        let handle = try FileHandle(forWritingTo: url)  // the write, then the "crash"
        try handle.seek(toOffset: 6)
        try handle.write(contentsOf: Data([0xBB]))
        try handle.close()
        let copy = folder.appendingPathComponent("crashed")
        try FileManager.default.copyItem(at: made.url, to: copy)
        let recovered = try EditorSession(recovering: SessionFolder(url: copy))
        #expect(try Data(contentsOf: url)[6] == 6)  // rolled back
        #expect(try recovered.snapshot.read(5..<7) == Data([0xAA, 0xBB]) && recovered.isDirty)
    }

    /// Narrowed (no clone): edits and saves work, but nothing is journaled and the folder
    /// is already marked closed, so a crash can't bring back wrong bytes.
    @Test func withoutACloneTheSessionIsNarrowedAndKeepsNoJournal() async throws {
        defer { cleanUp() }
        let session = try EditorSession(
            url: url, saver: Saver(fileSystem: NoCloneFileSystem()), sessionsRoot: root)
        try type(session, 0xAA, at: 5)
        let made = try #require(session.folder)
        #expect(session.isNarrowed && made.isClosed && session.journal == nil)
        #expect(!FileManager.default.fileExists(atPath: made.file(SessionJournal.fileName).path))
        try await session.save()
        #expect(try Data(contentsOf: url)[5] == 0xAA)
        #expect(SessionFolder.sweep(root).isEmpty)  // the next launch drops it
    }
}
