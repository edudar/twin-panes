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
        let urls = try (1...12).map { try file("f\($0)") }
        for url in urls { try store.add(url) }
        #expect(store.entries.count == 12)
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

    @Test func unresolvableEntriesAreDropped() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = BookmarkStore(defaults: defaults, key: key)
        let a = try file("a")
        try store.add(a)
        defaults.set(
            [Data("garbage".utf8)] + (defaults.array(forKey: key) as? [Data] ?? []), forKey: key)
        #expect(paths(store) == [a.path])
        #expect(BookmarkStore.resolve(Data("garbage".utf8)) == nil)
    }

    @Test func refreshKeepsPosition() throws {
        defer { cleanUp() }
        let store = BookmarkStore(defaults: try #require(UserDefaults(suiteName: suite)), key: key)
        let a = try file("a")
        let b = try file("b")
        try store.add(a)
        try store.add(b)
        try store.refresh(a)
        #expect(paths(store) == [b.path, a.path])
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
