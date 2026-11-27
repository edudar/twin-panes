import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TwinPanesCore

@Suite struct FileMetadataTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FileMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func regularFileMetadataAndPermissions() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("notes.txt")
            let payload = Data("hello world!".utf8)
            try payload.write(to: file)
            #expect(chmod(file.path, 0o640) == 0)
            let meta = try FileMetadata.read(url: file)
            #expect(meta.url == file && meta.name == "notes.txt")
            #expect(
                meta.typeIdentifier == UTType.plainText.identifier
                    && meta.kind == TypeNames.description(of: .plainText))
            #expect(
                !meta.isDirectory && !meta.isPackage && !meta.isSymbolicLink && !meta.isDataless)
            #expect(meta.size == UInt64(payload.count) && meta.allocatedSize != nil)
            #expect(meta.created != nil && meta.modified != nil && meta.accessed != nil)
            #expect(meta.posixMode == 0o640 && meta.formattedPermissions == "rw-r----- (0640)")
            #expect(!meta.owner.isEmpty && !meta.group.isEmpty && meta.hardLinkCount == 1)
            #expect(meta.symlinkTarget == nil && !meta.hasMoreExtendedAttributes)
        }
    }

    @Test func folderAndPackageHaveNilSizes() throws {
        try withTempDir { dir in
            let folder = dir.appendingPathComponent("Folder", isDirectory: true)
            let app = dir.appendingPathComponent("Tool.app", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data(count: 128).write(to: folder.appendingPathComponent("inside.bin"))

            let folderMeta = try FileMetadata.read(url: folder)
            #expect(folderMeta.isDirectory && !folderMeta.isPackage)
            #expect(folderMeta.size == nil && folderMeta.allocatedSize == nil)
            #expect(folderMeta.typeIdentifier == UTType.folder.identifier)
            #expect(folderMeta.kind == "Folder")

            let appMeta = try FileMetadata.read(url: app)
            #expect(!appMeta.isDirectory && appMeta.isPackage)
            #expect(appMeta.size == nil && appMeta.allocatedSize == nil)
            #expect(UTType(appMeta.typeIdentifier)?.conforms(to: .application) == true)
        }
    }

    @Test func symlinksClassifyTargetOrFallbackToSymbolicLink() throws {
        try withTempDir { dir in
            let fm = FileManager.default
            let file = dir.appendingPathComponent("target.txt")
            let folder = dir.appendingPathComponent("TargetDir", isDirectory: true)
            try Data("abcdef".utf8).write(to: file)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            let fileLink = dir.appendingPathComponent("link-file")
            try fm.createSymbolicLink(at: fileLink, withDestinationURL: file)
            let fileMeta = try FileMetadata.read(url: fileLink)
            #expect(fileMeta.isSymbolicLink && fileMeta.symlinkTarget == file.path)
            #expect(fileMeta.size == 6 && !fileMeta.isDirectory)
            #expect(fileMeta.typeIdentifier == UTType.plainText.identifier)

            let folderLink = dir.appendingPathComponent("link-folder")
            try fm.createSymbolicLink(at: folderLink, withDestinationURL: folder)
            let folderMeta = try FileMetadata.read(url: folderLink)
            #expect(folderMeta.isSymbolicLink && folderMeta.symlinkTarget == folder.path)
            #expect(folderMeta.isDirectory && folderMeta.size == nil)
            #expect(folderMeta.typeIdentifier == UTType.folder.identifier)

            let brokenLink = dir.appendingPathComponent("broken")
            try fm.createSymbolicLink(
                at: brokenLink, withDestinationURL: dir.appendingPathComponent("missing"))
            let brokenMeta = try FileMetadata.read(url: brokenLink)
            #expect(brokenMeta.isSymbolicLink && brokenMeta.symlinkTarget != nil)
            #expect(!brokenMeta.isDirectory && brokenMeta.size == nil)
            #expect(brokenMeta.typeIdentifier == UTType.symbolicLink.identifier)
        }
    }

    @Test func extendedAttributesSortedAndCappedAt64() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent("xattr.bin")
            try Data("data".utf8).write(to: file)
            for (name, count) in [("com.tp.zeta", 3), ("com.tp.alpha", 5)] {
                let bytes = [UInt8](repeating: 1, count: count)
                #expect(setxattr(file.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0)
            }
            let initial = try FileMetadata.read(url: file)
            let custom = initial.extendedAttributes.filter { $0.name.hasPrefix("com.tp.") }
            #expect(
                custom == [
                    .init(name: "com.tp.alpha", size: 5), .init(name: "com.tp.zeta", size: 3),
                ]
                    && !initial.hasMoreExtendedAttributes)

            let cappedFile = dir.appendingPathComponent("many-xattr.bin")
            try Data("x".utf8).write(to: cappedFile)
            for index in 0..<(FileMetadata.maxExtendedAttributes + 2) {
                var byte = UInt8(index)
                let name = String(format: "com.tp.attr.%02d", index)
                #expect(setxattr(cappedFile.path, name, &byte, 1, 0, XATTR_NOFOLLOW) == 0)
            }
            let capped = try FileMetadata.read(url: cappedFile)
            #expect(capped.extendedAttributes.count == FileMetadata.maxExtendedAttributes)
            #expect(capped.hasMoreExtendedAttributes)
            let cappedNames = capped.extendedAttributes.map(\.name)
            #expect(cappedNames == cappedNames.sorted())
        }
    }

    @Test func hardLinksFlagsPermissionsAndErrors() throws {
        try withTempDir { dir in
            let first = dir.appendingPathComponent("first.bin")
            defer { chflags(first.path, 0) }
            try Data("abc".utf8).write(to: first)
            #expect(link(first.path, dir.appendingPathComponent("second.bin").path) == 0)
            #expect(chflags(first.path, UInt32(UF_HIDDEN | UF_IMMUTABLE)) == 0)
            let meta = try FileMetadata.read(url: first)
            #expect(meta.hardLinkCount == 2)
            #expect(meta.flags.contains("Locked") && meta.flags.contains("Hidden"))
            #expect(chflags(first.path, 0) == 0)

            for (mode, expected) in [
                (0o644 as UInt16, "rw-r--r-- (0644)"), (0o755, "rwxr-xr-x (0755)"),
                (0o000, "--------- (0000)"),
            ] {
                #expect(chmod(first.path, mode) == 0)
                #expect(try FileMetadata.read(url: first).formattedPermissions == expected)
            }
            #expect(throws: POSIXError(.ENOENT)) {
                _ = try FileMetadata.read(url: dir.appendingPathComponent("missing"))
            }
            #expect(throws: POSIXError(.ENOTDIR)) {
                _ = try FileMetadata.read(url: first.appendingPathComponent("child"))
            }
        }
    }
}
