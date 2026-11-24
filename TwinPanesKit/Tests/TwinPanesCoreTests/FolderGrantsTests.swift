import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct FolderGrantsTests {
    let dir: URL
    var suite: String { dir.appendingPathComponent("defaults").path }
    let key = "Test.folderGrants"

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderGrantsTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cleanUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func grantScopeAndLostGrantMatchSymlinkAndCaseVariants() throws {
        defer { cleanUp() }
        let grants = FolderGrants(defaults: try #require(UserDefaults(suiteName: suite)), key: key)
        let folder = dir.appendingPathComponent("Projects", isDirectory: true)
        let child = folder.appendingPathComponent("Sub/file.txt")
        try FileManager.default.createDirectory(
            at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: child)
        try grants.add(folder)

        let symlink = dir.appendingPathComponent("ProjectsLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: folder)
        let symlinkedChild = symlink.appendingPathComponent("Sub/file.txt")
        let canonicalFolder = BookmarkStore.canonicalPath(folder)
        #expect(
            grants.grant(covering: symlinkedChild).map(BookmarkStore.canonicalPath)
                == canonicalFolder)
        #expect(grants.scope(covering: symlinkedChild) != nil)

        let caseSensitive = BookmarkStore.isCaseSensitive(folder)
        if !caseSensitive {
            let cased = dir.appendingPathComponent("PROJECTS/sub/FILE.TXT")
            #expect(
                grants.grant(covering: cased).map(BookmarkStore.canonicalPath) == canonicalFolder)
        }

        try FileManager.default.removeItem(at: folder)
        grants.invalidate()
        #expect(grants.grant(covering: child) == nil)
        #expect(
            grants.lostGrant(covering: child).map(BookmarkStore.canonicalPath) == canonicalFolder)
        if !caseSensitive {
            let cased = dir.appendingPathComponent("projects/sub/file.txt")
            #expect(
                grants.lostGrant(covering: cased).map(BookmarkStore.canonicalPath)
                    == canonicalFolder)
        }
    }

    @Test func forgetAndInvalidateDropStaleCachedEntries() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let grants = FolderGrants(defaults: defaults, key: key)
        let folder = dir.appendingPathComponent("Cached", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try grants.add(folder)

        #expect(grants.folders.count == 1)
        grants.forget(folder)
        #expect(grants.folders.isEmpty)
        #expect(grants.grant(covering: folder) == nil)

        try grants.add(folder)
        #expect(grants.folders.count == 1)
        BookmarkStore(defaults: defaults, key: key).forget(folder)
        // Still cached until invalidate() is called.
        #expect(grants.folders.count == 1)
        grants.invalidate()
        #expect(grants.folders.isEmpty)
    }

    @Test func crossVolumePrefixDoesNotFalselyMatch() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let grants = FolderGrants(defaults: defaults, key: key)
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let devNull = URL(fileURLWithPath: "/dev/null")

        let rootVol = try? root.resourceValues(forKeys: [.volumeURLKey]).volume
        let devVol = try? devNull.resourceValues(forKeys: [.volumeURLKey]).volume
        try #require(rootVol != nil && devVol != nil && rootVol != devVol)

        try grants.add(root)
        #expect(grants.grant(covering: devNull) == nil)
    }
}
