import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct SaveJournalTests {
    let fm = FileManager.default, fs = RealFileSystem()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SJT-\(UUID())")
    func f(_ name: String) -> URL { folder.appendingPathComponent(name) }
    var url: URL { f("f") }
    var j: URL { f(SaveJournal.fileName) }
    var hasJ: Bool { fm.fileExists(atPath: j.path) }
    init() throws { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    func disk(_ u: URL? = nil) throws -> Data { try Data(contentsOf: u ?? url) }
    func w(_ b: UInt8, _ n: Int = 64) throws { try Data(repeating: b, count: n).write(to: url) }
    func seed(_ n: Int = 64, _ r: Range<UInt64> = 4..<12) throws -> Data {
        let d = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) }); try d.write(to: url)
        try SaveJournal.begin(
            j, file: url, identity: FileIdentity(url: url), ranges: [r], newLength: UInt64(n),
            fileSystem: fs)
        return d
    }
    func roll(_ c: (any FileSystem)? = nil, to: URL? = nil) throws -> Bool {
        try SaveJournal.rollBackIfNeeded(j, targetURL: to, fileSystem: c ?? fs)
    }

    @Test func rollbackSafetyCommittedMovedAndChunked() throws {
        defer { try? fm.removeItem(at: folder) }
        let orig = try seed(); try w(0xEE)
        #expect(chmod(url.path, 0o444) == 0); #expect(throws: FileSystemError.self) { try roll() }
        #expect(chmod(url.path, 0o644) == 0 && hasJ)
        #expect(throws: CrashingFileSystem.Crash.self) { try roll(CrashingFileSystem(crashAt: 2)) }
        #expect(throws: CrashingFileSystem.Crash.self) { try roll(CrashingFileSystem(crashAt: 3)) }
        #expect(try hasJ && roll() && disk()[4..<12] == orig[4..<12])
        _ = try seed(64, 0..<8); try fm.removeItem(at: url)
        #expect(throws: ByteSourceError.self) { try roll() }
        try w(0x55); #expect(try hasJ && !roll() && !hasJ)
        let upd = Data(repeating: 0x22, count: 64); _ = try seed(64, 8..<16); try upd.write(to: url)
        try (Data(contentsOf: j) + Data("DONE".utf8)).write(to: j)
        #expect(try !roll() && !hasJ && disk() == upd)
        let l = f("l"), m = f("m"), exp = try seed(64, 8..<16)[8..<16]
        try fm.linkItem(at: url, to: l); try w(0xCC); try fm.moveItem(at: url, to: m)
        #expect(try roll(to: m) && disk(m)[8..<16] == exp && disk(l)[8..<16] == exp)
        let n = Saver.chunkSize + 64 * 1024, big = try seed(n, 64..<UInt64(n - 64))
        try w(0xEE, n); let s = CrashingFileSystem(crashAt: nil)
        #expect(try roll(s) && s.operations >= 5 && disk()[64..<(n - 64)] == big[64..<(n - 64)])
    }
    @MainActor @Test func recoveredStrategyBSessionSavesInPlace() async throws {
        defer { try? fm.removeItem(at: folder) }; try w(0x11); let l = f("l")
        try fm.linkItem(at: url, to: l); let s = try EditorSession(url: url, sessionsRoot: folder)
        try s.overwrite(Data([0xAA]), at: 5, selectionBefore: 5..<6, selectionAfter: 5..<6)
        let made = try #require(s.folder)
        try SaveJournal.begin(
            made.file(SaveJournal.fileName), file: url, identity: FileIdentity(url: url),
            ranges: [5..<6], newLength: 64, fileSystem: fs)
        var p = try disk(); p[5] = 0xAA; try p.write(to: url)
        try fm.copyItem(at: made.url, to: f("c")); s.close()
        let r = try EditorSession(recovering: SessionFolder(url: f("c")))
        #expect(r.identity == (try FileIdentity(url: url)) && r.identity.linkCount == 2)
        try await r.save()
        #expect(try disk()[5..<6] == Data([0xAA]) && disk(l)[5..<6] == Data([0xAA]))
    }

    /// A crash after an in-place save grew the file: rollback cuts it back.
    @Test func rollbackUndoesAGrowth() throws {
        defer { try? fm.removeItem(at: folder) }
        let old = Data((0..<64).map { UInt8($0) })
        try old.write(to: url)
        try SaveJournal.begin(
            j, file: url, identity: FileIdentity(url: url), ranges: [10..<100], newLength: 100,
            fileSystem: fs)
        try (old.prefix(10) + Data(repeating: 0xEE, count: 90)).write(to: url)  // the writes
        #expect(try roll() && disk() == old && !hasJ)
    }

    /// A crash after an in-place save shrank the file: the bytes past the new end come back
    /// from the journal although the plan wrote none of them.
    @Test func rollbackUndoesAShrink() throws {
        defer { try? fm.removeItem(at: folder) }
        let old = Data((0..<64).map { UInt8($0) })
        try old.write(to: url)
        try SaveJournal.begin(
            j, file: url, identity: FileIdentity(url: url), ranges: [], newLength: 40,
            fileSystem: fs)
        try old.prefix(40).write(to: url)
        #expect(try roll() && disk() == old && !hasJ)
    }

    /// A journal an earlier build wrote (`TPSJ`, no length) still rolls back its bytes.
    @Test func anEarlierJournalStillRollsBack() throws {
        defer { try? fm.removeItem(at: folder) }
        let old = Data((0..<64).map { UInt8($0) })
        try old.write(to: url)
        let identity = try FileIdentity(url: url)
        var body = Array("TPSJ".utf8)
        let path = Array(url.path.utf8)
        JournalFormat.append(UInt32(path.count), to: &body)
        body += path
        JournalFormat.append(identity.key.device, to: &body)
        JournalFormat.append(identity.key.inode, to: &body)
        JournalFormat.append(UInt32(1), to: &body)
        JournalFormat.append(UInt64(8), to: &body)
        JournalFormat.append(UInt64(4), to: &body)
        body += old[8..<12]
        JournalFormat.append(JournalFormat.crc32c(body), to: &body)
        try Data(body).write(to: j)
        var changed = old
        changed.replaceSubrange(8..<12, with: [0xEE, 0xEE, 0xEE, 0xEE])
        try changed.write(to: url)
        #expect(try roll() && disk() == old && !hasJ)
    }
}
