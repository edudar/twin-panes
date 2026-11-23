import Darwin
import Foundation
import Testing

@testable import TwinPanesCore

struct FileSystemTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileSystemTests-\(UUID().uuidString)")
    let fs = RealFileSystem()

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func writesResizesAndFlushes() throws {
        defer { cleanUp() }
        let url = folder.appendingPathComponent("a.bin")
        try Data([1, 2, 3, 4, 5]).write(to: url)
        let descriptor = try fs.openForWriting(url)
        try fs.write(Data([0xAA, 0xBB]), to: descriptor, at: 1, path: url.path)
        try fs.truncate(descriptor, to: 4, path: url.path)
        try fs.fullSync(descriptor, path: url.path)
        fs.close(descriptor)
        #expect(try Data(contentsOf: url) == Data([1, 0xAA, 0xBB, 4]))
        // Not the closed descriptor: a parallel test may have been given its number.
        #expect(throws: FileSystemError("flush", url.path, errno: EBADF)) {
            try fs.fullSync(-1, path: url.path)
        }
    }

    /// Clone into the staging folder, then swap it in: the file gets the clone's inode.
    @Test func clonesStagesAndReplaces() throws {
        defer { cleanUp() }
        let url = folder.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: url)
        let before = try FileIdentity(url: url)
        let staging = try fs.replacementDirectory(for: url)
        defer { fs.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("a.bin")
        try fs.clone(url, to: staged)
        #expect(try FileIdentity(url: staged).key.device == before.key.device)
        let copied = staging.appendingPathComponent("copy.bin")
        try fs.copy(url, to: copied)
        #expect(try Data(contentsOf: copied) == Data([1, 2, 3]))
        #expect(throws: FileSystemError("clone", url.path, errno: EEXIST)) {
            try fs.clone(url, to: staged)
        }
        try Data([9]).write(to: staged)
        try fs.replaceItem(at: url, with: staged)
        #expect(try Data(contentsOf: url) == Data([9]))
        #expect(try FileIdentity(url: url).key != before.key)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect((fs.availableCapacity(for: url) ?? 0) > 0)
    }

    @Test func reportsWhatFailed() {
        defer { cleanUp() }
        let missing = folder.appendingPathComponent("missing.bin")
        #expect(throws: FileSystemError("open", missing.path, errno: ENOENT)) {
            try fs.openForWriting(missing)
        }
        #expect(
            FileSystemError("open", "/x", errno: ENOENT).description
                == "Can't open /x: No such file or directory")
    }
}
