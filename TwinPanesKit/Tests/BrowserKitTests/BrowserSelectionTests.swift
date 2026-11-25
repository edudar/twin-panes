import AppKit
import Testing
import TwinPanesCore
import WorkspaceKit

@testable import BrowserKit

/// Selecting several rows, what F5–F8 act on (docs/plans/M6.md, D-a, step 2).
@MainActor
@Suite struct BrowserSelectionTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserSelectionTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let folder: URL
    let grants: FolderGrants

    init() throws {
        let fm = FileManager.default
        folder = root.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(
            at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for (name, size) in [("a.txt", 10), ("b.bin", 300), ("c.png", 20), (".hidden", 5)] {
            try Data(count: size).write(to: folder.appendingPathComponent(name))
        }
        let prefs = root.appendingPathComponent("prefs")
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

    func select(_ names: [String], in item: BrowserItem) throws {
        let rows = try names.map { try #require(item.controller.row(named: $0)) }
        item.controller.tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    func selected(_ item: BrowserItem) -> [String] { item.selectedEntries.map(\.name) }

    @Test func severalRowsAreSelectedInRowOrder() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        try select(["c.png", "a.txt", "sub"], in: item)
        #expect(selected(item) == ["sub", "a.txt", "c.png"])
    }

    @Test func theParentRowNeverJoinsOtherRows() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        let table = item.controller.tableView
        // What a ⇧-click from ".." proposes; clicks and keys go through this.
        let proposed = item.controller.tableView(
            table, selectionIndexesForProposedSelection: [0, 1, 2])
        #expect(proposed == [1, 2])
        table.selectAll(nil)
        #expect(!table.selectedRowIndexes.contains(0))
        #expect(selected(item) == ["sub", "a.txt", "b.bin", "c.png"])
        table.selectRowIndexes([0], byExtendingSelection: false)
        #expect(table.selectedRowIndexes == [0] && selected(item).isEmpty)
    }

    @Test func aSortKeepsEverySelectedName() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        try select(["a.txt", "c.png"], in: item)
        item.sort(by: ListingOrder(column: .size, ascending: false))
        await item.listed()
        #expect(Set(selected(item)) == ["a.txt", "c.png"])
    }

    @Test func hidingFilesDropsOnlyTheHiddenOnes() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        item.showHidden(true)
        await item.listed()
        try select([".hidden", "b.bin"], in: item)
        item.showHidden(false)
        await item.listed()
        #expect(selected(item) == ["b.bin"])
    }

    @Test func aLiveUpdateKeepsTheSelection() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        try select(["b.bin", "c.png"], in: item)
        try Data([1]).write(to: folder.appendingPathComponent("0-new.txt"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.txt"))
        for _ in 0..<200 where item.entries.contains(where: { $0.name == "a.txt" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        await item.listed()
        #expect(selected(item) == ["b.bin", "c.png"])
    }

    @Test func theStatusLineCountsTheSelection() async throws {
        defer { cleanUp() }
        var status = ""
        let item = BrowserItem(folder: folder, grants: grants) { _, _ in }
        let host = RecordingHost { status = $0 }
        item.host = host
        _ = item.viewController.view
        await item.listed()
        defer { item.willClose() }
        try select(["a.txt", "b.bin", "sub"], in: item)
        #expect(status.contains("3 of 4 selected"))
        #expect(status.contains("310 bytes"))
    }

    /// ⌘A in a big folder, then a re-sort off the main actor, keeps every row selected.
    @Test func everythingStaysSelectedThroughABigSort() async throws {
        defer { cleanUp() }
        let big = root.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        let count = FolderListing.mainActorLimit + 500
        for index in 0..<count {
            FileManager.default.createFile(
                atPath: big.appendingPathComponent("f\(index)").path, contents: nil)
        }
        let item = await browser(at: big)
        defer { item.willClose() }
        item.controller.tableView.selectAll(nil)
        item.sort(by: ListingOrder(ascending: false))
        await item.listed()
        #expect(item.selectedEntries.count == count)
    }
}

@MainActor
private final class RecordingHost: WorkspaceHost {
    let record: (String) -> Void
    init(_ record: @escaping (String) -> Void) { self.record = record }
    func showStatus(_ message: String) { record(message) }
}
