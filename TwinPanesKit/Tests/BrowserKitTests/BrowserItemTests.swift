import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

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

    /// Moving around inside one grant keeps the tab's access token instead of starting
    /// access again on every navigation.
    @Test func navigatingUnderOneGrantKeepsItsToken() async throws {
        defer { cleanUp() }
        try grants.add(root)
        let item = browser(at: root)
        item.go()
        await item.listed()
        let first = try #require(item.scope)
        item.go(to: root.appendingPathComponent("sub"))
        await item.listed()
        #expect(item.scope === first)
        #expect(
            grants.grant(covering: root.appendingPathComponent("sub/inner"))?.path == first.url.path
        )
        item.go(to: URL(fileURLWithPath: "/"))
        await item.listed()
        #expect(item.scope == nil)
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
        var viewed: [QuickViewPlacement] = []
        item.viewFile = { _, placement in viewed.append(placement) }
        let controller = item.controller
        _ = controller.view
        await item.listed()
        #expect(controller.isParentRowSelected)
        func enabled(_ action: Selector) -> Bool {
            controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        #expect(enabled(#selector(BrowserViewController.browserOpen(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserView(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserViewInSamePanel(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserEdit(_:))))
        controller.browserView(nil)
        controller.browserViewInSamePanel(nil)
        controller.browserEdit(nil)
        #expect(item.folder.path == root.appendingPathComponent("sub").path)
        #expect(viewed.isEmpty)
        #expect(opened.files.isEmpty)
    }

    @Test func viewAndEditSplitByEntryKindAndViewFileFallback() async throws {
        defer { cleanUp() }
        let appPackage = root.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: appPackage, withIntermediateDirectories: true)
        let item = browser(at: root)
        var viewed: [(String?, QuickViewPlacement)] = []
        item.viewFile = { browser, placement in
            viewed.append((browser.selectedEntry?.name, placement))
        }
        let controller = item.controller
        _ = controller.view
        await item.listed()
        #expect(item.activeScope == nil)

        func select(_ name: String) throws {
            let row = try #require(controller.row(named: name))
            controller.tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        func enabled(_ action: Selector) -> Bool {
            controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }

        // Folder: View and View in Same Panel enabled; Edit disabled.
        try select("sub")
        #expect(enabled(#selector(BrowserViewController.browserView(_:))))
        #expect(enabled(#selector(BrowserViewController.browserViewInSamePanel(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserEdit(_:))))
        controller.browserView(nil)
        controller.browserViewInSamePanel(nil)
        controller.browserEdit(nil)
        #expect(viewed.count == 2)
        #expect(viewed[0].0 == "sub" && viewed[0].1 == .oppositePanel)
        #expect(viewed[1].0 == "sub" && viewed[1].1 == .samePanel)
        #expect(opened.files.isEmpty)

        // Package (.app): View enabled; Edit disabled.
        try select("Tool.app")
        #expect(try #require(item.selectedEntry).isPackage)
        #expect(enabled(#selector(BrowserViewController.browserView(_:))))
        #expect(enabled(#selector(BrowserViewController.browserViewInSamePanel(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserEdit(_:))))
        controller.browserEdit(nil)
        #expect(opened.files.isEmpty)

        // Regular file: all three enabled; Edit opens via `openFile`.
        try select("file.txt")
        #expect(enabled(#selector(BrowserViewController.browserView(_:))))
        #expect(enabled(#selector(BrowserViewController.browserViewInSamePanel(_:))))
        #expect(enabled(#selector(BrowserViewController.browserEdit(_:))))
        controller.browserView(nil)
        controller.browserViewInSamePanel(nil)
        controller.browserEdit(nil)
        #expect(viewed.count == 4)
        #expect(viewed[2].0 == "file.txt" && viewed[2].1 == .oppositePanel)
        #expect(viewed[3].0 == "file.txt" && viewed[3].1 == .samePanel)
        #expect(opened.files.count == 1)
        #expect(opened.files[0].0.lastPathComponent == "file.txt")

        // Fallback when `viewFile` is nil: `browserView` still opens the file via `browserOpen`.
        item.viewFile = nil
        controller.browserView(nil)
        #expect(opened.files.count == 2)
        #expect(opened.files[1].0.lastPathComponent == "file.txt")
    }

    @Test func selectionCallbackFiresOnCursorFolderAndAccessWithoutRebuildingTabs() async throws {
        defer { cleanUp() }
        let item = browser(at: root)
        var tabChanges = 0
        var selections: [(folder: URL, entry: String?, needsAccess: Bool)] = []
        item.onChange = { tabChanges += 1 }
        item.onSelectionChange = { changed in
            selections.append((changed.folder, changed.selectedEntry?.name, changed.needsAccess))
        }
        _ = item.viewController.view
        await item.listed()
        selections.removeAll()
        let baselineTabChanges = tabChanges

        // Cursor movement notifies `onSelectionChange` without triggering `onChange`.
        let fileRow = try #require(item.controller.row(named: "file.txt"))
        item.controller.tableView.selectRowIndexes([fileRow], byExtendingSelection: false)
        #expect(tabChanges == baselineTabChanges)
        #expect(selections.last?.entry == "file.txt")
        #expect(selections.last?.needsAccess == false)

        // Folder navigation fires `onSelectionChange` (and `onChange` once for the new tab title).
        let sub = root.appendingPathComponent("sub")
        item.go(to: sub)
        await item.listed()
        #expect(tabChanges == baselineTabChanges + 1)
        #expect(selections.contains { $0.folder.path == sub.path })

        // Access denial notifies `onSelectionChange` without rebuilding tabs.
        selections.removeAll()
        item.received(.failed(.needsAccess(sub)))
        #expect(tabChanges == baselineTabChanges + 1)
        #expect(selections.last?.needsAccess == true)
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

    func makeFiles(_ count: Int, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<count {
            FileManager.default.createFile(
                atPath: folder.appendingPathComponent("f\(i).bin").path, contents: nil)
        }
    }

    /// Past `FolderListing.mainActorLimit` batches merge off the main actor; the rows
    /// still end up complete and in order (M4 step 4).
    @Test func aBigFolderArrivesInBatchesAndInOrder() async throws {
        defer { cleanUp() }
        let big = root.appendingPathComponent("big")
        try makeFiles(FolderListing.mainActorLimit + 1_500, in: big)
        let item = browser(at: big)
        _ = item.viewController.view
        #expect(item.isListing)
        await item.listed()
        #expect(item.entries.count == FolderListing.mainActorLimit + 1_500)
        let names = item.entries.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(item.controller.numberOfRows(in: item.controller.tableView) == names.count + 1)
    }

    /// A listing that a navigation superseded never reaches the new folder's rows.
    @Test func lateBatchesFromTheOldFolderAreDropped() async throws {
        defer { cleanUp() }
        let big = root.appendingPathComponent("big")
        try makeFiles(3_000, in: big)
        let item = browser(at: root)
        _ = item.viewController.view
        await item.listed()
        item.go(to: big)
        let old = try #require(item.lister)
        item.go(to: root.appendingPathComponent("sub"))
        await item.listed()
        await withCheckedContinuation { done in old.whenFinished { done.resume() } }
        #expect(item.entries.map(\.name) == ["inner"])
        #expect(item.folder.lastPathComponent == "sub")
    }

    /// Going up selects the folder you came from once it's listed, unless the user has
    /// moved the selection meanwhile.
    @Test func theFolderYouCameFromIsSelectedWhenItArrives() async throws {
        defer { cleanUp() }
        let item = browser(at: root.appendingPathComponent("sub"))
        _ = item.viewController.view
        await item.listed()
        item.goToParent()
        #expect(item.controller.isParentRowSelected)  // nothing listed yet
        await item.listed()
        #expect(item.controller.selectedEntry?.name == "sub")
    }

    /// Rows arriving above the selected one leave the same entry selected, not whatever
    /// lands on its old row.
    @Test func aBatchAboveTheSelectionKeepsIt() async throws {
        defer { cleanUp() }
        let item = browser(at: root)
        _ = item.viewController.view
        await item.listed()
        let table = item.controller.tableView
        table.selectRowIndexes(
            [try #require(item.controller.row(named: "file.txt"))], byExtendingSelection: false)
        let early = DirectoryEntry(
            url: root.appendingPathComponent("a-early"), name: "a-early", isDirectory: true,
            isPackage: false, isSymbolicLink: false, isHidden: false, size: nil, modified: nil,
            type: .folder)
        item.received(.batch([early]))
        #expect(item.entries.map(\.name) == ["a-early", "sub", "file.txt"])
        #expect(item.controller.selectedEntry?.name == "file.txt")
    }

    @Test func needsAccessViaFailedListingPopulatesPromptAndOpenDoesNotGoToParent() async throws {
        defer { cleanUp() }
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        let item = browser(at: locked)
        let controller = item.controller
        _ = controller.view
        await item.listed()
        #expect(!item.needsAccess)

        item.received(.failed(.needsAccess(locked)))
        #expect(item.needsAccess)
        #expect(controller.grantButton.title.contains("Grant Access"))
        #expect(Self.labels(in: controller.view).contains { $0.contains("locked") })

        controller.browserOpen(nil)
        await item.listed()
        #expect(item.folder.path == locked.path)
    }

    @Test func volumeRootAccessRequestDoesNotRepeatVolumeName() {
        defer { cleanUp() }
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let volume = URL(fileURLWithPath: "/Volumes/MyDisk", isDirectory: true)
        let request = AccessRequest.for(folder: volume, lost: nil, home: home, volume: volume)
        #expect(request.directory == volume)
        #expect(request.button == "Grant Access to “MyDisk”…")
        #expect(!request.message.contains("is on “MyDisk”"))
        #expect(request.message == "Grant access to “MyDisk” once and it’s remembered.")
    }

    @Test func coveringGrantUnderHomeAsksForFolderDirectly() {
        defer { cleanUp() }
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let request = AccessRequest.for(
            folder: desktop, lost: nil, home: home, coveringGrant: home)
        #expect(request.directory == desktop)
        #expect(request.button == "Grant Access…")
    }

    @Test func nonExistentLostDirectoryFallsBackToNearestExistingAncestor() {
        defer { cleanUp() }
        let missing = root.appendingPathComponent("missing/deep", isDirectory: true)
        let resolved = BrowserViewController.nearestExistingAncestor(of: missing)
        #expect(resolved == root)
    }

    static func labels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }
}
