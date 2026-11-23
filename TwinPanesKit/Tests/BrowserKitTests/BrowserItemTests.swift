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

    @Test func listsFoldersFirst() async {
        defer { cleanUp() }
        let item = browser(at: root)
        #expect(item.go())
        #expect(item.isListing)
        await item.listed()
        #expect(item.hasListed && !item.isListing)
        #expect(!item.needsAccess)
        #expect(item.entries.map(\.name) == ["sub", "file.txt"])
    }

    @Test func staysPutOnAMissingPathOrAFile() async {
        defer { cleanUp() }
        let item = browser(at: root)
        item.go()
        await item.listed()
        #expect(!item.go(to: root.appendingPathComponent("missing")))
        #expect(!item.go(to: root.appendingPathComponent("file.txt")))
        #expect(item.folder.path == root.path)
        #expect(item.entries.count == 2)
    }

    @Test func anUnreadableFolderAsksForAccess() async throws {
        defer { cleanUp() }
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let item = browser(at: root)
        #expect(item.go(to: locked))
        await item.listed()
        #expect(item.needsAccess)
        #expect(item.entries.isEmpty)
        #expect(item.folder.path == locked.path)
    }

    @Test func goingUpSelectsTheFolderYouCameFrom() async {
        defer { cleanUp() }
        let item = browser(at: root.appendingPathComponent("sub"))
        _ = item.viewController.view
        await item.listed()
        item.goToParent()
        await item.listed()
        #expect(item.folder.path == root.path)
        #expect(item.controller.selectedEntry?.name == "sub")
    }

    @Test func theTopFolderHasNoParent() async {
        defer { cleanUp() }
        let item = browser(at: URL(fileURLWithPath: "/"))
        item.goToParent()
        await item.listed()
        #expect(item.folder.path == "/")
    }

    @Test func openingAFilePassesTheCoveringGrant() async throws {
        defer { cleanUp() }
        let item = browser(at: root)
        item.go()
        await item.listed()
        let file = try #require(item.entries.first { $0.name == "file.txt" })
        item.open(file)
        await item.listed()
        #expect(opened.files.count == 1)
        #expect(opened.files.first?.1 == nil)
        try grants.add(root)
        item.open(file)
        await item.listed()
        #expect(opened.files.last?.0.lastPathComponent == "file.txt")
        #expect(opened.files.last?.1?.url.standardizedFileURL.path == root.path)
    }

    @Test func openingAFolderGoesIntoIt() async throws {
        defer { cleanUp() }
        let item = browser(at: root)
        item.go()
        await item.listed()
        item.open(try #require(item.entries.first { $0.name == "sub" }))
        await item.listed()
        #expect(item.folder.path == root.appendingPathComponent("sub").path)
        #expect(opened.files.isEmpty)
    }

    @Test func pathFieldRevertsEmptyAndBadTildeAndNavigatesValidPath() async {
        defer { cleanUp() }
        let item = browser(at: root)
        _ = item.viewController.view
        await item.listed()
        let field = item.controller.pathField

        // Empty/whitespace input stays put and restores the current path.
        field.stringValue = "   "
        item.controller.pathEntered(field)
        await item.listed()
        #expect(item.folder.path == root.path)
        #expect(field.stringValue == root.path)

        // `~other` must not be expanded as `<home>other`.
        field.stringValue = "~definitely-not-a-user-\(UUID().uuidString)"
        item.controller.pathEntered(field)
        await item.listed()
        #expect(item.folder.path == root.path)
        #expect(field.stringValue == root.path)

        // Valid subfolder path navigates there.
        let sub = root.appendingPathComponent("sub").path
        field.stringValue = sub
        item.controller.pathEntered(field)
        await item.listed()
        #expect(item.folder.path == sub)
    }

    @Test func menuValidationAndGrantedFolder() async throws {
        defer { cleanUp() }
        let item = browser(at: URL(fileURLWithPath: "/"))
        _ = item.viewController.view
        await item.listed()
        let parentItem = NSMenuItem(
            title: "Parent", action: #selector(BrowserViewController.browserParent(_:)),
            keyEquivalent: "")
        #expect(!item.controller.validateMenuItem(parentItem))

        // Granting `root` saves it in FolderGrants and lists it.
        item.granted(root)
        await item.listed()
        #expect(item.folder.path == root.path)
        #expect(grants.scope(covering: root.appendingPathComponent("sub")) != nil)
        #expect(item.controller.validateMenuItem(parentItem))

        // An empty folder has only "..": View is disabled, Open goes up.
        let empty = root.appendingPathComponent("sub/inner")
        item.go(to: empty)
        await item.listed()
        let viewItem = NSMenuItem(
            title: "View", action: #selector(BrowserViewController.browserView(_:)),
            keyEquivalent: "")
        #expect(!item.controller.validateMenuItem(viewItem))
        #expect(item.controller.isParentRowSelected)
    }

    @Test func viewControllerSurvivesAfterItemDeallocates() async {
        defer { cleanUp() }
        var item: BrowserItem? = browser(at: root)
        let controller = item!.controller
        _ = controller.view
        await item?.listed()
        #expect(controller.numberOfRows(in: controller.tableView) == 3)

        // Closing a tab releases BrowserItem while AppKit may still invoke callbacks
        // on the view controller during the current run-loop turn.
        item = nil
        controller.viewDidAppear()
        #expect(controller.numberOfRows(in: controller.tableView) == 0)
        #expect(controller.selectedEntry == nil)
        let openItem = NSMenuItem(
            title: "Open", action: #selector(BrowserViewController.browserOpen(_:)),
            keyEquivalent: "")
        #expect(!controller.validateMenuItem(openItem))
    }

    // MARK: The ".." row

    @Test func theParentRowComesFirstAndIsSelectedOnArrival() async {
        defer { cleanUp() }
        let item = browser(at: root)
        let controller = item.controller
        _ = controller.view
        await item.listed()
        #expect(controller.showsParentRow)
        #expect(controller.numberOfRows(in: controller.tableView) == item.entries.count + 1)
        #expect(controller.entry(atRow: 0) == nil)
        #expect(controller.entry(atRow: 1)?.name == "sub")
        #expect(controller.entry(atRow: 2)?.name == "file.txt")
        #expect(controller.entry(atRow: 3) == nil)
        #expect(controller.isParentRowSelected)
        #expect(controller.selectedEntry == nil)
        let cell = controller.tableView(
            controller.tableView, viewFor: controller.tableView.tableColumns[0], row: 0)
        #expect(Self.labels(in: cell) == [".."])
    }

    @Test func theTopFolderHasNoParentRow() async {
        defer { cleanUp() }
        let item = browser(at: URL(fileURLWithPath: "/"))
        let controller = item.controller
        _ = controller.view
        await item.listed()
        #expect(!controller.showsParentRow)
        #expect(controller.numberOfRows(in: controller.tableView) == item.entries.count)
        #expect(controller.entry(atRow: 0)?.name == item.entries.first?.name)
        #expect(!controller.isParentRowSelected)
    }

    @Test func openingTheParentRowGoesUp() async {
        defer { cleanUp() }
        let item = browser(at: root.appendingPathComponent("sub"))
        let controller = item.controller
        _ = controller.view
        await item.listed()
        controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
        controller.browserOpen(nil)
        await item.listed()
        #expect(item.folder.path == root.path)
        #expect(controller.selectedEntry?.name == "sub")
        #expect(controller.tableView.selectedRow == 1)
    }

    @Test func viewAndEditOnTheParentRowDoNothing() async {
        defer { cleanUp() }
        let item = browser(at: root.appendingPathComponent("sub"))
        let controller = item.controller
        _ = controller.view
        await item.listed()
        #expect(controller.isParentRowSelected)
        func enabled(_ action: Selector) -> Bool {
            controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        #expect(enabled(#selector(BrowserViewController.browserOpen(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserView(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserEdit(_:))))
        controller.browserView(nil)
        controller.browserEdit(nil)
        #expect(item.folder.path == root.appendingPathComponent("sub").path)
        #expect(opened.files.isEmpty)
    }

    @Test func typeToSelectSkipsTheParentRow() async {
        defer { cleanUp() }
        let item = browser(at: root)
        let controller = item.controller
        _ = controller.view
        await item.listed()
        let table = controller.tableView
        let column = table.tableColumns[0]
        #expect(controller.tableView(table, typeSelectStringFor: column, row: 0) == nil)
        #expect(controller.tableView(table, typeSelectStringFor: column, row: 1) == "sub")
    }

    static func labels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }
}
