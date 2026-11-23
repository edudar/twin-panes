import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TwinPanesCore

@Suite struct DirectoryReaderTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryReaderTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: dir.appendingPathComponent("b-folder"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("A-folder"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("Tool.app"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: dir.appendingPathComponent("file10.bin"))
        try Data(count: 2).write(to: dir.appendingPathComponent("file2.bin"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        try fm.createSymbolicLink(
            at: dir.appendingPathComponent("link-to-folder"),
            withDestinationURL: dir.appendingPathComponent("A-folder"))
    }

    @Test func foldersFirstThenNaturalOrder() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try DirectoryReader.entries(of: dir).map(\.url.lastPathComponent)
        #expect(
            names == [
                "A-folder", "b-folder", "link-to-folder", "file2.bin", "file10.bin", "Tool.app",
            ])
    }

    @Test func entryDetails() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try DirectoryReader.entries(of: dir)
        let file = try #require(entries.first { $0.url.lastPathComponent == "file10.bin" })
        #expect(file.size == 10 && !file.isDirectory && file.modified != nil)
        let link = try #require(entries.first { $0.url.lastPathComponent == "link-to-folder" })
        #expect(link.isDirectory && link.isSymbolicLink)
        let app = try #require(entries.first { $0.url.lastPathComponent == "Tool.app" })
        #expect(app.isPackage && !app.isDirectory)
    }

    /// Kind comes from the name's type, cached, capitalised as in Finder (M4, D-b).
    @Test func kindsFromTypes() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent("README"))
        try Data().write(to: dir.appendingPathComponent("odd.zzqqxx"))
        let entries = try DirectoryReader.entries(of: dir)
        func entry(_ name: String) throws -> DirectoryEntry {
            try #require(entries.first { $0.name == name })
        }
        #expect(try entry("A-folder").type == .folder && entry("A-folder").kind == "Folder")
        #expect(try entry("Tool.app").type.conforms(to: .application))
        #expect(try entry("notes.txt").type.conforms(to: .plainText))
        #expect(try entry("README").type == .data)
        #expect(try entry("odd.zzqqxx").kind == "Document")
        #expect(try entry("link-to-folder").type == .folder)
        #expect(entries.allSatisfy { $0.kind.first?.isUppercase == true })
    }

    @Test func hiddenFilesOnRequest() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let all = try DirectoryReader.entries(of: dir, includeHidden: true)
        #expect(all.contains { $0.url.lastPathComponent == ".hidden" })
    }

    @Test func errors() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing")
        #expect(throws: DirectoryReaderError.notFound(missing)) {
            _ = try DirectoryReader.entries(of: missing)
        }
        let file = dir.appendingPathComponent("file2.bin")
        #expect(throws: DirectoryReaderError.notAFolder(file)) {
            _ = try DirectoryReader.entries(of: file)
        }
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
        #expect(throws: DirectoryReaderError.needsAccess(locked)) {
            _ = try DirectoryReader.entries(of: locked)
        }
    }

    @Test func symlinksAndEmptyFolder() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let empty = dir.appendingPathComponent("empty", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: false)
        #expect(try DirectoryReader.entries(of: empty).isEmpty)

        try fm.createSymbolicLink(
            at: dir.appendingPathComponent("link-to-app"),
            withDestinationURL: dir.appendingPathComponent("Tool.app"))
        try fm.createSymbolicLink(
            at: dir.appendingPathComponent("link-to-file"),
            withDestinationURL: dir.appendingPathComponent("file10.bin"))
        try fm.createSymbolicLink(
            at: dir.appendingPathComponent("broken-link"),
            withDestinationURL: dir.appendingPathComponent("does-not-exist"))

        let entries = try DirectoryReader.entries(of: dir)
        let appLink = try #require(entries.first { $0.url.lastPathComponent == "link-to-app" })
        #expect(appLink.isSymbolicLink && appLink.isPackage && !appLink.isDirectory)
        let fileLink = try #require(entries.first { $0.url.lastPathComponent == "link-to-file" })
        #expect(fileLink.isSymbolicLink && !fileLink.isDirectory && fileLink.size == 10)
        let broken = try #require(entries.first { $0.url.lastPathComponent == "broken-link" })
        #expect(broken.isSymbolicLink && !broken.isDirectory)
    }

    @Test func grantsPickTheMostSpecificFolder() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        // An absolute-path suite keeps the plist in `dir`, which the test removes; a named
        // suite would leave a file in ~/Library/Preferences on every run.
        let defaults = try #require(
            UserDefaults(suiteName: dir.appendingPathComponent("defaults").path))
        let grants = FolderGrants(defaults: defaults)
        #expect(grants.scope(covering: dir) == nil)
        try grants.add(dir)
        try grants.add(dir.appendingPathComponent("A-folder"))
        let deep = dir.appendingPathComponent("A-folder/inner/file")
        let scope = try #require(grants.scope(covering: deep))
        #expect(scope.url.lastPathComponent == "A-folder")
        #expect(
            grants.scope(covering: dir.appendingPathComponent("b-folder"))?.url.path
                == grants.folders.first { $0.lastPathComponent == dir.lastPathComponent }?.path)
        #expect(grants.scope(covering: URL(fileURLWithPath: "/usr")) == nil)
    }
}
