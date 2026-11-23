import Foundation
import Testing

@testable import TwinPanesCore

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
}
