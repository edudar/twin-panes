import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct TrashFolderTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func isTheHomeFoldersDotTrash() {
        let trash = TrashFolder(home: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        #expect(trash.url.path == "/Users/someone/.Trash")
    }

    @Test func aReadableTrashIsListable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let trash = TrashFolder(home: home)
        try FileManager.default.createDirectory(at: trash.url, withIntermediateDirectories: true)
        #expect(trash.isListable())
    }

    @Test func aMissingTrashIsNotListable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!TrashFolder(home: home).isListable())
    }

    /// What a denied Full Disk Access looks like to `opendir`: no permission to read.
    @Test func anUnreadableTrashIsNotListable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let trash = TrashFolder(home: home)
        try FileManager.default.createDirectory(
            at: trash.url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0])
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: trash.url.path)
        }
        #expect(!trash.isListable())
    }
}
