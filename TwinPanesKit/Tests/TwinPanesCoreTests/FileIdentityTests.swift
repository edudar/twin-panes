import Darwin
import Foundation
import Testing

@testable import TwinPanesCore

struct FileIdentityTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileIdentityTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func file(_ name: String, _ bytes: [UInt8] = [1, 2, 3, 4]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func describesAFileAndMatchesTheOpenSource() throws {
        defer { cleanUp() }
        let url = try file("a.bin")
        let identity = try FileIdentity(url: url)
        #expect(identity.size == 4)
        #expect(identity.linkCount == 1)
        #expect(identity.isUnchanged(from: identity))
        // The source takes its identity from the open descriptor: the same file.
        #expect(try ByteSource(url: url).identity == identity)
        let handle = try FileHandle(forReadingFrom: url)
        let descriptor = handle.fileDescriptor
        #expect(try FileIdentity(descriptor: descriptor, path: url.path) == identity)
        try handle.close()
        // Not the closed descriptor: a parallel test may have been given its number.
        #expect(throws: ByteSourceError.openFailed(path: url.path, errno: EBADF)) {
            try FileIdentity(descriptor: -1, path: url.path)
        }
        let other = try FileIdentity(url: try file("b.bin"))
        #expect(other.key != identity.key)
    }

    /// Writing keeps the file (key) but changes size or time; either one counts.
    @Test func writesAreChangesOfTheSameFile() throws {
        defer { cleanUp() }
        let url = try file("a.bin")
        let before = try FileIdentity(url: url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data([9, 9, 9, 9]))  // same size, in place
        try handle.close()
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        let sameSize = try FileIdentity(url: url)
        #expect(sameSize.key == before.key && sameSize.size == before.size)
        #expect(!sameSize.isUnchanged(from: before))

        try Data([1]).write(to: url, options: [])  // truncates in place
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        let shorter = try FileIdentity(url: url)
        #expect(shorter.key == before.key)
        #expect(!shorter.isUnchanged(from: sameSize))  // size alone differs
    }

    @Test func replacingAndLinkingAreSeen() throws {
        defer { cleanUp() }
        let url = try file("a.bin")
        let before = try FileIdentity(url: url)
        let staged = try file("staged.bin", [7])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        let replaced = try FileIdentity(url: url)
        #expect(replaced.key != before.key)
        #expect(!replaced.isUnchanged(from: before))

        try FileManager.default.linkItem(at: url, to: folder.appendingPathComponent("link.bin"))
        #expect(try FileIdentity(url: url).linkCount == 2)
    }

    @Test func aMissingFileThrows() throws {
        defer { cleanUp() }
        let url = folder.appendingPathComponent("missing.bin")
        #expect(throws: ByteSourceError.openFailed(path: url.path, errno: ENOENT)) {
            try FileIdentity(url: url)
        }
    }

    @Test func accessModeFollowsPermissionAndLock() throws {
        defer { cleanUp() }
        let url = try file("a.bin")
        #expect(AccessMode.of(url) == .writable)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        #expect(AccessMode.of(url) == .readOnly(.noWritePermission))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(url.path, 0) }  // or the folder can't be removed
        #expect(AccessMode.of(url) == .readOnly(.locked))
        #expect(chflags(url.path, 0) == 0)
        #expect(AccessMode.of(url) == .writable)
    }

    /// A read-only volume can't be mounted in a test, so the order of the reasons is
    /// checked on the decision itself.
    @Test func reasonsAreReportedVolumeFirst() {
        defer { cleanUp() }
        let locked = UInt32(UF_IMMUTABLE), systemLocked = UInt32(SF_IMMUTABLE)
        #expect(
            AccessMode.classify(volumeReadOnly: true, fileFlags: locked, canWrite: false)
                == .readOnly(.readOnlyVolume))
        #expect(
            AccessMode.classify(volumeReadOnly: false, fileFlags: locked, canWrite: false)
                == .readOnly(.locked))
        #expect(
            AccessMode.classify(volumeReadOnly: false, fileFlags: systemLocked, canWrite: true)
                == .readOnly(.locked))
        #expect(
            AccessMode.classify(volumeReadOnly: false, fileFlags: 0, canWrite: false)
                == .readOnly(.noWritePermission))
        #expect(
            AccessMode.classify(volumeReadOnly: false, fileFlags: UInt32(UF_HIDDEN), canWrite: true)
                == .writable)
    }
}
