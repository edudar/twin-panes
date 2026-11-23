import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct BookmarkStoreTests {
    let dir: URL
    /// An absolute-path suite keeps the plist inside `dir`: removing the domain alone
    /// still leaves an empty file in ~/Library/Preferences.
    var suite: String { dir.appendingPathComponent("defaults").path }
    let key = "Test.bookmarks"

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkStoreTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([1]).write(to: url)
        return url
    }

    func cleanUp() {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    func paths(_ store: BookmarkStore) -> [String] {
        store.entries.map { $0.url.standardizedFileURL.path }
    }

    @Test func newestFirstAndTrimmedToLimit() throws {
        defer { cleanUp() }
        let store = BookmarkStore(
            defaults: try #require(UserDefaults(suiteName: suite)), key: key, limit: 3)
        let urls = try (1...5).map { try file("f\($0)") }
        for url in urls { try store.add(url) }
        #expect(paths(store) == urls.reversed().prefix(3).map(\.path))
    }

    @Test func noLimitKeepsEverything() throws {
        defer { cleanUp() }
        let store = BookmarkStore(defaults: try #require(UserDefaults(suiteName: suite)), key: key)
        let urls = try (1...4).map { try file("f\($0)") }
        for url in urls { try store.add(url) }
        #expect(store.entries.count == 4)
    }

    @Test func addingTheSamePathAgainMovesItToTheTop() throws {
        defer { cleanUp() }
        let store = BookmarkStore(defaults: try #require(UserDefaults(suiteName: suite)), key: key)
        let a = try file("a")
        let b = try file("b")
        try store.add(a)
        try store.add(b)
        try store.add(dir.appendingPathComponent("./a"))  // same path, different spelling
        #expect(paths(store) == [a.path, b.path])
    }

    @Test func unresolvableEntriesAreDroppedAndPrunedOnWrite() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = BookmarkStore(defaults: defaults, key: key)
        let a = try file("a")
        let b = try file("b")
        try store.add(a)
        defaults.set(
            [Data("garbage".utf8)] + (defaults.array(forKey: key) as? [Data] ?? []), forKey: key)
        #expect(paths(store) == [a.path])
        #expect(BookmarkStore.resolve(Data("garbage".utf8)) == nil)
        try store.add(b)
        #expect((defaults.array(forKey: key) as? [Data])?.count == 2)
    }

    /// A bookmark whose item went away is kept as lost, with its path, until it's
    /// granted again; adding the same path replaces it (M4, D-g).
    @Test func aMovedItemIsReportedLostNotDropped() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = BookmarkStore(defaults: defaults, key: key)
        let folder = dir.appendingPathComponent("granted", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.add(folder)
        try store.add(try file("other"))
        try FileManager.default.removeItem(at: folder)
        #expect(paths(store) == [dir.appendingPathComponent("other").path])
        // The recorded path is the real one (/private/var for the temp folder).
        let lost = try #require(store.lost.first)
        #expect(store.lost.count == 1 && lost.lastPathComponent == "granted")
        try store.add(try file("third"))  // writing doesn't prune it
        #expect(store.lost == [lost])
        let grants = FolderGrants(defaults: defaults, key: key)
        #expect(grants.lostGrant(covering: lost.appendingPathComponent("inner/x")) == lost)
        #expect(grants.lostGrant(covering: lost.deletingLastPathComponent()) == nil)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try store.add(folder)
        #expect(store.lost.isEmpty && paths(store).first == folder.path)
        store.forget(folder)
        #expect(!paths(store).contains(folder.path))
    }

    @Test func refreshKeepsPositionAndAddsIfMissing() throws {
        defer { cleanUp() }
        let store = BookmarkStore(defaults: try #require(UserDefaults(suiteName: suite)), key: key)
        let a = try file("a")
        let b = try file("b")
        let c = try file("c")
        try store.add(a)
        try store.add(b)
        try store.refresh(a)
        #expect(paths(store) == [b.path, a.path])
        try store.refresh(c)
        #expect(paths(store) == [c.path, b.path, a.path])
    }

    @Test func folderGrantsRespectPathComponentBoundaries() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let grants = FolderGrants(defaults: defaults)
        let foo = dir.appendingPathComponent("foo", isDirectory: true)
        let foobar = dir.appendingPathComponent("foobar", isDirectory: true)
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foobar, withIntermediateDirectories: true)
        try grants.add(foo)
        #expect(grants.scope(covering: foo.appendingPathComponent("inside")) != nil)
        #expect(grants.scope(covering: foobar) == nil)
        #expect(grants.scope(covering: foobar.appendingPathComponent("inside")) == nil)
        grants.removeAll()
        #expect(grants.folders.isEmpty)
        #expect(grants.scope(covering: foo) == nil)
    }

    @Test func persistsAcrossInstancesAndRemoveAllEmpties() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let a = try file("a")
        try BookmarkStore(defaults: defaults, key: key).add(a)
        let store = BookmarkStore(defaults: defaults, key: key)
        #expect(paths(store) == [a.path])
        store.removeAll()
        #expect(store.entries.isEmpty)
        #expect(BookmarkStore(defaults: defaults, key: key).entries.isEmpty)
    }
}
