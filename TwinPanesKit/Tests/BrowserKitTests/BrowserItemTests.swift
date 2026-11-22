import AppKit
import Testing
import TwinPanesCore

@testable import BrowserKit

/// BrowserItem navigation on a temp folder tree (from the review's missing tests).
@MainActor
@Suite struct BrowserItemTests {
    let root: URL
    /// Preferences live in their own temp folder: an absolute-path suite keeps the plist
    /// there, while removing a named suite's domain still leaves a file in
    /// ~/Library/Preferences.
    let prefs = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserItemTests-prefs-\(UUID().uuidString)", isDirectory: true)
    var suite: String { prefs.appendingPathComponent("defaults").path }
    let defaults: UserDefaults
    let grants: FolderGrants
    final class Opened { var files: [(URL, SecurityScope?)] = [] }
    let opened = Opened()

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserItemTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("sub/inner"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: root.appendingPathComponent("file.txt"))
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: prefs.appendingPathComponent("defaults").path)!
        grants = FolderGrants(defaults: defaults)
    }

    func cleanUp() {
        let locked = root.appendingPathComponent("locked")
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: prefs)
    }

    func browser(at folder: URL) -> BrowserItem {
        BrowserItem(folder: folder, grants: grants) { [opened] url, scope in
            opened.files.append((url, scope))
        }
    }

    @Test func listsFoldersFirst() {
        defer { cleanUp() }
        let item = browser(at: root)
        #expect(item.go())
        #expect(item.hasListed)
        #expect(!item.needsAccess)
        #expect(item.entries.map(\.name) == ["sub", "file.txt"])
    }

    @Test func staysPutOnAMissingPathOrAFile() {
        defer { cleanUp() }
        let item = browser(at: root)
        item.go()
        #expect(!item.go(to: root.appendingPathComponent("missing")))
        #expect(!item.go(to: root.appendingPathComponent("file.txt")))
        #expect(item.folder.path == root.path)
        #expect(item.entries.count == 2)
    }

    @Test func anUnreadableFolderAsksForAccess() throws {
        defer { cleanUp() }
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let item = browser(at: root)
        #expect(item.go(to: locked))
        #expect(item.needsAccess)
        #expect(item.entries.isEmpty)
        #expect(item.folder.path == locked.path)
    }

    @Test func goingUpSelectsTheFolderYouCameFrom() {
        defer { cleanUp() }
        let item = browser(at: root.appendingPathComponent("sub"))
        _ = item.viewController.view
        item.goToParent()
        #expect(item.folder.path == root.path)
        #expect(item.controller.selectedEntry?.name == "sub")
    }

    @Test func theTopFolderHasNoParent() {
        defer { cleanUp() }
        let item = browser(at: URL(fileURLWithPath: "/"))
        item.goToParent()
        #expect(item.folder.path == "/")
    }

    @Test func openingAFilePassesTheCoveringGrant() throws {
        defer { cleanUp() }
        let item = browser(at: root)
        item.go()
        let file = try #require(item.entries.first { $0.name == "file.txt" })
        item.open(file)
        #expect(opened.files.count == 1)
        #expect(opened.files.first?.1 == nil)
        try grants.add(root)
        item.open(file)
        #expect(opened.files.last?.0.lastPathComponent == "file.txt")
        #expect(opened.files.last?.1?.url.standardizedFileURL.path == root.path)
    }

    @Test func openingAFolderGoesIntoIt() throws {
        defer { cleanUp() }
        let item = browser(at: root)
        item.go()
        item.open(try #require(item.entries.first { $0.name == "sub" }))
        #expect(item.folder.path == root.appendingPathComponent("sub").path)
        #expect(opened.files.isEmpty)
    }
}
