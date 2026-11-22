import Foundation
import Testing

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
    }

    @Test func grantsPickTheMostSpecificFolder() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try #require(UserDefaults(suiteName: "FolderGrantsTests-\(UUID())"))
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

    @Test func realHomeIsNotTheContainer() {
        #expect(!DirectoryReader.realHomeDirectory.path.contains("/Library/Containers/"))
    }
}
