import Darwin
import Foundation
import Synchronization
import Testing

@testable import TwinPanesCore

/// The real file system, except where a test makes a step fail.
private final class FaultyFileSystem: FileSystem {
    let real = RealFileSystem()
    /// Which flush fails (1 = the first), if any.
    let failSyncAt: Int?, failClone: Bool, capacity: UInt64?
    let opened = Mutex<[URL]>([])
    let syncs = Mutex(0)

    init(failSyncAt: Int? = nil, failClone: Bool = false, capacity: UInt64? = nil) {
        (self.failSyncAt, self.failClone, self.capacity) = (failSyncAt, failClone, capacity)
    }

    func replacementDirectory(for url: URL) throws -> URL {
        try real.replacementDirectory(for: url)
    }
    func clone(_ source: URL, to destination: URL) throws {
        if failClone { throw FileSystemError("clone", source.path, errno: ENOTSUP) }
        try real.clone(source, to: destination)
    }
    func copy(_ source: URL, to destination: URL) throws { try real.copy(source, to: destination) }
    func availableCapacity(for url: URL) -> UInt64? { capacity ?? real.availableCapacity(for: url) }
    func openForWriting(_ url: URL) throws -> Int32 {
        opened.withLock { $0.append(url) }
        return try real.openForWriting(url)
    }
    func create(_ url: URL) throws -> Int32 { try real.create(url) }
    func move(_ source: URL, to destination: URL) throws { try real.move(source, to: destination) }
    func write(_ data: Data, to descriptor: Int32, at offset: UInt64, path: String) throws {
        try real.write(data, to: descriptor, at: offset, path: path)
    }
    func truncate(_ descriptor: Int32, to length: UInt64, path: String) throws {
        try real.truncate(descriptor, to: length, path: path)
    }
    func fullSync(_ descriptor: Int32, path: String) throws {
        let count = syncs.withLock {
            $0 += 1; return $0
        }
        if count == failSyncAt { throw FileSystemError("flush", path, errno: EIO) }
        try real.fullSync(descriptor, path: path)
    }
    func close(_ descriptor: Int32) { real.close(descriptor) }
    func replaceItem(at url: URL, with staged: URL) throws {
        try real.replaceItem(at: url, with: staged)
    }
    func removeItem(at url: URL) { real.removeItem(at: url) }
}

struct SaverTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SaverTests-\(UUID().uuidString)")
    let url: URL
    let original = Data((0..<1_200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try original.write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// An edited version of the file: two bytes at 10 and a run across the 1 MiB-chunked
    /// copy's first boundary-free stretch near the end.
    func edited() throws -> (EditBuffer, PieceTree) {
        let buffer = try EditBuffer(
            original: ByteSource(url: url), addDirectory: folder.appendingPathComponent("add"))
        let opened = buffer.tree
        try buffer.overwrite(at: 10, with: Data([0xAA, 0xBB]))
        try buffer.overwrite(at: 1_199_990, with: Data(repeating: 0xCC, count: 10))
        return (buffer, opened)
    }

    @Test func patchesTheFileAndKeepsItsMetadata() throws {
        defer { cleanUp() }
        #expect(setxattr(url.path, "test.saver", "kept", 4, 0, 0) == 0)
        try (url as NSURL).setResourceValue(["Saver"], forKey: .tagNamesKey)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .creationDate: created], ofItemAtPath: url.path)
        let before = try FileIdentity(url: url)
        let (buffer, opened) = try edited()
        let plan = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: true)
        #expect(plan.ranges == [10..<12, 1_199_990..<1_200_000])

        let identity = try Saver().save(buffer.snapshot(), plan: plan, to: url)
        #expect(try Data(contentsOf: url) == buffer.snapshot().read(0..<1_200_000))
        #expect(identity == (try FileIdentity(url: url)) && identity.key != before.key)
        var value = [UInt8](repeating: 0, count: 8)
        let length = getxattr(url.path, "test.saver", &value, 8, 0, 0)
        #expect(length == 4 && Data(value.prefix(4)) == Data("kept".utf8))
        let resources = try url.resourceValues(forKeys: [.tagNamesKey, .creationDateKey])
        #expect(resources.tagNames == ["Saver"] && resources.creationDate == created)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect(mode as? Int == 0o640)
    }

    /// Someone else changed the file: the whole version is written, and the file is cut
    /// back to its length.
    @Test func aWholeFilePlanRewritesEverything() throws {
        defer { cleanUp() }
        let (buffer, opened) = try edited()
        try Data(repeating: 0x11, count: 1_300_000).write(to: url)
        let plan = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: false)
        _ = try Saver().save(buffer.snapshot(), plan: plan, to: url)
        #expect(try Data(contentsOf: url) == buffer.snapshot().read(0..<1_200_000))
    }

    @Test func refusesHardLinkedFiles() throws {
        defer { cleanUp() }
        try FileManager.default.linkItem(at: url, to: folder.appendingPathComponent("link"))
        let (buffer, opened) = try edited()
        let plan = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: true)
        #expect(throws: Saver.SaveError.hardLinked) {
            try Saver().save(buffer.snapshot(), plan: plan, to: url)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    /// A failure at any step before the swap leaves the file as it was and no staging
    /// file behind.
    @Test func failuresLeaveTheOriginal() throws {
        defer { cleanUp() }
        let before = try FileIdentity(url: url)
        let (buffer, opened) = try edited()
        let plan = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: true)
        let failing = FaultyFileSystem(failSyncAt: 1)
        #expect(throws: FileSystemError.self) {
            try Saver(fileSystem: failing).save(buffer.snapshot(), plan: plan, to: url)
        }
        let staged = try #require(failing.opened.withLock { $0.first })
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileIdentity(url: url) == before)

        let full = FaultyFileSystem(failClone: true, capacity: 1000)
        #expect(throws: Saver.SaveError.notEnoughSpace(needed: 1_200_000, available: 1000)) {
            try Saver(fileSystem: full).save(buffer.snapshot(), plan: plan, to: url)
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileIdentity(url: url) == before)
        // No room needed check passes when there is room: the copy path saves.
        let copying = FaultyFileSystem(failClone: true)
        _ = try Saver(fileSystem: copying).save(buffer.snapshot(), plan: plan, to: url)
        #expect(try Data(contentsOf: url) == buffer.snapshot().read(0..<1_200_000))
        #expect(try FileIdentity(url: url).key != before.key)
    }

    /// Save As: a new file, or over another file, with no staging file left behind.
    @Test func writesAWholeVersionToAnotherFile() throws {
        defer { cleanUp() }
        let (buffer, _) = try edited()
        let wanted = try buffer.snapshot().read(0..<1_200_000)
        let fresh = folder.appendingPathComponent("copy.bin")
        let identity = try Saver().write(buffer.snapshot(), to: fresh)
        #expect(try Data(contentsOf: fresh) == wanted && identity == FileIdentity(url: fresh))
        let other = folder.appendingPathComponent("other.bin")
        try Data(repeating: 7, count: 1_300_000).write(to: other)
        _ = try Saver().write(buffer.snapshot(), to: other)
        #expect(try Data(contentsOf: other) == wanted)
        #expect(try Data(contentsOf: url) == original)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(left) == ["file.bin", "copy.bin", "other.bin", "add"])
    }

    // MARK: Strategy B (M3c)

    @Test func savesAHardLinkedFileInPlace() throws {
        defer { cleanUp() }
        let link = folder.appendingPathComponent("link")
        try FileManager.default.linkItem(at: url, to: link)
        let before = try FileIdentity(url: url)
        let (buffer, opened) = try edited()
        let plan = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: true)
        let journal = folder.appendingPathComponent("save-journal.bin")
        let identity = try Saver().save(
            buffer.snapshot(), plan: plan, to: url, inPlaceJournal: journal)
        let wanted = try buffer.snapshot().read(0..<1_200_000)
        #expect(try Data(contentsOf: url) == wanted && Data(contentsOf: link) == wanted)
        #expect(identity.key == before.key && identity.linkCount == 2)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        // A whole-file plan would journal the whole file: refused, Save As instead.
        let whole = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: false)
        #expect(throws: Saver.SaveError.hardLinked) {
            try Saver().save(buffer.snapshot(), plan: whole, to: url, inPlaceJournal: journal)
        }
    }

    /// A save that stops after writing into the file: in the app it's rolled back at once
    /// (the flush failed), after a crash by recovery (the journal has no commit mark).
    @Test func anUncommittedInPlaceSaveRollsBack() throws {
        defer { cleanUp() }
        try FileManager.default.linkItem(at: url, to: folder.appendingPathComponent("link"))
        let (buffer, opened) = try edited()
        let plan = SavePlan(saved: opened, current: buffer.tree, diskMatchesSaved: true)
        let journal = folder.appendingPathComponent("save-journal.bin")
        // Flush 1 is the journal's, flush 2 the file's.
        #expect(throws: FileSystemError.self) {
            try Saver(fileSystem: FaultyFileSystem(failSyncAt: 2)).save(
                buffer.snapshot(), plan: plan, to: url, inPlaceJournal: journal)
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: journal.path))

        // A crash right after the writes: journal written, file changed, no mark.
        let fs = RealFileSystem()
        try SaveJournal.begin(
            journal, file: url, identity: try FileIdentity(url: url), ranges: plan.ranges,
            fileSystem: fs)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 1_200_000))
        try handle.close()
        #expect(try SaveJournal.rollBackIfNeeded(journal, fileSystem: fs))
        let back = try Data(contentsOf: url)
        #expect(back[10..<12] == original[10..<12] && back[1_199_990...] == original[1_199_990...])
        #expect(!FileManager.default.fileExists(atPath: journal.path))

        // A journal cut short never got to the writes: nothing to undo.
        try SaveJournal.begin(
            journal, file: url, identity: try FileIdentity(url: url), ranges: plan.ranges,
            fileSystem: fs)
        try FileHandle(forWritingTo: journal).truncate(atOffset: 20)
        let untouched = try Data(contentsOf: url)
        #expect(try !SaveJournal.rollBackIfNeeded(journal, fileSystem: fs))
        #expect(try Data(contentsOf: url) == untouched)
    }
}
