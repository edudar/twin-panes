import Darwin
import Foundation
import Testing

@testable import TwinPanesCore

/// The real seam's writes (docs/plans/M6.md, D-c, step 6).
@Suite struct FileOperationSystemTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileOperationSystemTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let system = RealFileOperationSystem()
    let old = Date(timeIntervalSince1970: 1_000_000_000)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func xattr(_ name: String, of url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        getxattr(url.path, name, &bytes, size, 0, XATTR_NOFOLLOW)
        return String(decoding: bytes, as: UTF8.self)
    }

    func setXattr(_ name: String, _ value: String, on url: URL) {
        let bytes = Array(value.utf8)
        setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW)
    }

    @Test func aFileCopiesWithItsBytesDatesAndAttributes() throws {
        defer { cleanUp() }
        let source = url("a.bin")
        try Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) }).write(to: source)
        setXattr("com.example.tag", "red", on: source)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        try system.copyFile(source, to: url("b.bin")) { _ in true }
        #expect(try Data(contentsOf: url("b.bin")) == Data(contentsOf: source))
        #expect(xattr("com.example.tag", of: url("b.bin")) == "red")
        let copied = try FileManager.default.attributesOfItem(atPath: url("b.bin").path)
        #expect(copied[.modificationDate] as? Date == old)
    }

    @Test func aSymlinkCopiesAsALink() throws {
        defer { cleanUp() }
        try FileManager.default.createSymbolicLink(
            atPath: url("link").path, withDestinationPath: "nowhere")
        try system.copyFile(url("link"), to: url("link2")) { _ in true }
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: url("link2").path)
                == "nowhere")
    }

    @Test func aCopyNeverReplaces() throws {
        defer { cleanUp() }
        try Data("new".utf8).write(to: url("a"))
        try Data("old".utf8).write(to: url("b"))
        #expect(throws: FileSystemError.self) {
            try system.copyFile(url("a"), to: url("b")) { _ in true }
        }
        #expect(try Data(contentsOf: url("b")) == Data("old".utf8))
    }

    @Test func aFolderTakesItsSourcesMetadataLast() throws {
        defer { cleanUp() }
        let source = url("src")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        setXattr("com.example.tag", "blue", on: source)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        try system.makeFolder(at: url("dst"))
        #expect(throws: FileSystemError.self) { try system.makeFolder(at: url("dst")) }
        try Data().write(to: url("dst/inside"))
        try system.copyMetadata(from: source, to: url("dst"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url("dst").path)
        #expect(attributes[.modificationDate] as? Date == old)
        #expect(xattr("com.example.tag", of: url("dst")) == "blue")
    }

    @Test func removeTakesOneItem() throws {
        defer { cleanUp() }
        try Data().write(to: url("f"))
        try FileManager.default.createDirectory(at: url("d"), withIntermediateDirectories: true)
        try system.remove(url("f"))
        try system.remove(url("d"))
        #expect(!FileManager.default.fileExists(atPath: url("f").path))
        #expect(!FileManager.default.fileExists(atPath: url("d").path))
        #expect(throws: FileSystemError.self) { try system.remove(url("f")) }
    }

    /// A clone copies no data and reports no progress, so this copies without cloning, as
    /// across volumes, to check that the real callback stops the copy.
    @Test func stoppingADataCopyThrowsCancelled() throws {
        defer { cleanUp() }
        let source = url("big.bin")
        try Data(count: 8 << 20).write(to: source)
        var calls = 0
        let error = #expect(throws: FileSystemError.self) {
            try system.copyFileWithoutCloning(source, to: url("copy.bin")) { _ in
                calls += 1
                return false
            }
        }
        #expect(error?.errno == ECANCELED && calls == 1)
    }
}
