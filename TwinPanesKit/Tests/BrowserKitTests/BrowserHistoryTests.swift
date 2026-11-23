import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// Back and forward per tab (docs/plans/M4.md, D-d, step 7).
@MainActor
@Suite struct BrowserHistoryTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserHistoryTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let item: BrowserItem

    init() async throws {
        let fm = FileManager.default
        for path in ["a/inner", "b", "c"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: root.appendingPathComponent("z.txt").path, contents: nil)
        let grants = FolderGrants(
            defaults: UserDefaults(suiteName: root.appendingPathComponent("c/defaults").path)!)
        item = BrowserItem(folder: root, grants: grants) { _, _ in }
        _ = item.viewController.view
        await item.listed()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func go(_ path: String) async {
        item.go(to: root.appendingPathComponent(path))
        await item.listed()
    }

    func back() async {
        item.goBack()
        await item.listed()
    }

    func forward() async {
        item.goForward()
        await item.listed()
    }

    var at: String { item.folder.path.replacingOccurrences(of: root.path, with: "") }

    @Test func backAndForwardRetraceTheFoldersWithTheirSelection() async throws {
        defer { cleanUp() }
        let table = item.controller.tableView
        table.selectRowIndexes(
            [try #require(item.controller.row(named: "z.txt"))], byExtendingSelection: false)
        await go("a")
        await go("a/inner")
        #expect(item.canGoBack && !item.canGoForward)
        await back()
        #expect(at == "/a" && item.controller.selectedEntry?.name == "inner")
        await back()
        #expect(at == "" && item.controller.selectedEntry?.name == "z.txt")
        #expect(!item.canGoBack)
        item.goBack()  // nothing further back: stays put
        #expect(at == "")
        await forward()
        await forward()
        #expect(at == "/a/inner" && !item.canGoForward)
    }

    @Test func aNewNavigationClearsForwardAndRefreshingRecordsNothing() async {
        defer { cleanUp() }
        await go("a")
        await back()
        #expect(item.canGoForward)
        await go("b")
        #expect(!item.canGoForward)
        item.go()  // the same folder again
        await item.listed()
        await back()
        #expect(at == "" && !item.canGoBack)
    }

    @Test func goingUpIsRecordedToo() async {
        defer { cleanUp() }
        await go("a/inner")
        item.goToParent()
        await item.listed()
        await back()
        #expect(at == "/a/inner")
    }

    @Test func aFolderThatWentAwayIsSkipped() async throws {
        defer { cleanUp() }
        await go("b")
        await go("a")
        try FileManager.default.removeItem(at: root.appendingPathComponent("b"))
        await back()
        #expect(at == "")
        #expect(item.canGoForward)
        await forward()
        #expect(at == "/a")
    }

    @Test func menuItemsFollowTheStacks() async {
        defer { cleanUp() }
        func enabled(_ action: Selector) -> Bool {
            item.controller.validateMenuItem(
                NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        #expect(!enabled(#selector(BrowserViewController.browserBack(_:))))
        await go("c")
        #expect(enabled(#selector(BrowserViewController.browserBack(_:))))
        #expect(!enabled(#selector(BrowserViewController.browserForward(_:))))
        item.controller.browserBack(nil)
        await item.listed()
        #expect(enabled(#selector(BrowserViewController.browserForward(_:))))
    }
}

/// The access prompt asks for as much as the user means (docs/plans/M4.md, D-g).
@Suite struct AccessRequestTests {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func anExternalVolumeAsksForTheWholeVolume() {
        let request = AccessRequest.for(
            folder: URL(fileURLWithPath: "/Volumes/Backup Disk/Photos/2026"), lost: nil, home: home)
        #expect(request.directory.path == "/Volumes/Backup Disk")
        #expect(request.button == "Grant Access to “Backup Disk”…")
        #expect(request.message.contains("“2026” is on “Backup Disk”"))
    }

    @Test func insideHomeAsksForHome() {
        let request = AccessRequest.for(
            folder: home.appendingPathComponent("Code/project"), lost: nil, home: home)
        #expect(request.directory == home && request.message.contains("Desktop, Documents"))
    }

    @Test func aLostGrantIsAskedForAgainWhereItWas() {
        let lost = URL(fileURLWithPath: "/Volumes/Old Name", isDirectory: true)
        let request = AccessRequest.for(
            folder: lost.appendingPathComponent("inner"), lost: lost, home: home)
        #expect(request.directory == lost && request.button == "Grant Access Again…")
        #expect(request.message.contains("lost it"))
    }

    @Test func elsewhereAsksForTheFolder() {
        let folder = URL(fileURLWithPath: "/opt/data")
        let request = AccessRequest.for(folder: folder, lost: nil, home: home)
        #expect(request.directory == folder && request.button == "Grant Access…")
    }
}
