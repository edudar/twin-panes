import AppKit
import Testing
import TwinPanesCore

@testable import BrowserKit

/// Sorting by column in the tab (docs/plans/M4.md, D-c, step 5).
@MainActor
@Suite struct BrowserSortingTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserSortingTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let prefs: URL
    let grants: FolderGrants

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        for (name, size) in [("small.txt", 1), ("big.bin", 300), ("medium.png", 20)] {
            try Data(count: size).write(to: root.appendingPathComponent(name))
        }
        prefs = root.appendingPathComponent("prefs")
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        grants = FolderGrants(
            defaults: UserDefaults(suiteName: prefs.appendingPathComponent("d").path)!)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func browser(at folder: URL) async -> BrowserItem {
        let item = BrowserItem(folder: folder, grants: grants) { _, _ in }
        _ = item.viewController.view
        await item.listed()
        return item
    }

    func names(_ item: BrowserItem) -> [String] {
        item.entries.map(\.name).filter { $0 != "prefs" }
    }

    @Test func sortingKeepsFoldersOnTopAndTheSelection() async throws {
        defer { cleanUp() }
        let item = await browser(at: root)
        #expect(names(item) == ["folder", "big.bin", "medium.png", "small.txt"])
        let table = item.controller.tableView
        table.selectRowIndexes(
            [try #require(item.controller.row(named: "small.txt"))], byExtendingSelection: false)
        item.sort(by: ListingOrder(column: .size, ascending: false))
        await item.listed()
        #expect(names(item) == ["folder", "big.bin", "medium.png", "small.txt"])
        item.sort(by: ListingOrder(column: .size))
        #expect(names(item) == ["folder", "small.txt", "medium.png", "big.bin"])
        #expect(item.controller.selectedEntry?.name == "small.txt")
        item.sort(by: ListingOrder(column: .kind))
        #expect(item.entries.first?.name == "folder")
    }

    @Test func aHeaderClickSortsByItsColumn() async throws {
        defer { cleanUp() }
        let item = await browser(at: root)
        let table = item.controller.tableView
        #expect(table.sortDescriptors.first?.key == "name")
        let size = try #require(table.tableColumns.first { $0.title == "Size" })
        table.sortDescriptors = [try #require(size.sortDescriptorPrototype)]
        #expect(item.order.column == .size && item.order.ascending)
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        #expect(item.order == ListingOrder(column: .size, ascending: false))
        #expect(names(item).dropFirst().first == "big.bin")
    }

    /// A big folder sorts off the main actor; the order outlives a navigation, and a
    /// re-sort a navigation overtook never lands in the new folder.
    @Test func aBigFolderSortsOffTheMainActor() async throws {
        defer { cleanUp() }
        let big = root.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<(FolderListing.mainActorLimit + 500) {
            FileManager.default.createFile(
                atPath: big.appendingPathComponent("f\(i)").path, contents: nil)
        }
        let item = await browser(at: big)
        item.sort(by: ListingOrder(ascending: false))
        await item.listed()
        let names = item.entries.map(\.name)
        #expect(names.first == "f\(FolderListing.mainActorLimit + 499)" && names.last == "f0")
        item.sort(by: ListingOrder())
        item.go(to: root)
        await item.listed()
        #expect(item.entries.map(\.name).contains("folder") && item.entries.count == 6)
        #expect(item.order == ListingOrder())
    }
}

/// The hidden-files toggle (docs/plans/M4.md, D-e, step 6).
@MainActor
@Suite struct BrowserHiddenFilesTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserHiddenFilesTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL

    @Test func hiddenFilesShowWithoutListingAgain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["visible.txt", ".dot", "sub/.inner"] {
            fm.createFile(atPath: root.appendingPathComponent(name).path, contents: nil)
        }
        let prefs = root.appendingPathComponent("sub")
        let grants = FolderGrants(
            defaults: UserDefaults(suiteName: prefs.appendingPathComponent("d").path)!)
        let item = BrowserItem(folder: root, grants: grants) { _, _ in }
        _ = item.viewController.view
        await item.listed()
        #expect(
            item.entries.map(\.name) == ["sub", "visible.txt"] && item.listing.hiddenCount == 1)

        let menuItem = NSMenuItem(
            title: "", action: #selector(BrowserViewController.browserToggleHidden(_:)),
            keyEquivalent: "")
        #expect(item.controller.validateMenuItem(menuItem) && menuItem.state == .off)
        item.controller.browserToggleHidden(nil)
        #expect(!item.isListing)  // filtered, not listed again
        #expect(item.entries.map(\.name) == ["sub", ".dot", "visible.txt"])
        #expect(item.controller.validateMenuItem(menuItem) && menuItem.state == .on)

        item.go(to: root.appendingPathComponent("sub"))  // the toggle belongs to the tab
        await item.listed()
        #expect(item.entries.map(\.name).contains(".inner"))
        item.showHidden(false)
        #expect(!item.entries.map(\.name).contains(".inner"))
    }
}
