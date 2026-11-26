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

    /// Waits until `check` holds after a live update, failing after 10 s.
    func until(
        in item: BrowserItem, _ check: @escaping () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        if check() { return }
        var deadlineTask: Task<Void, Never>?
        defer { deadlineTask?.cancel() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            item.didUpdate = {
                guard !finished, check() else { return }
                finished = true
                item.didUpdate = nil
                done.resume()
            }
            deadlineTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !finished else { return }
                finished = true
                item.didUpdate = nil
                Issue.record(
                    "no such update within 10 s: \(item.entries.map(\.name))",
                    sourceLocation: sourceLocation)
                done.resume()
            }
        }
    }

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
        await until(in: item) {
            item.entries.contains(where: { $0.name == "0-new.txt" })
                && !item.entries.contains(where: { $0.name == "a.txt" })
        }
        await item.listed()
        #expect(selected(item) == ["b.bin", "c.png"])
    }

    @Test func hidingTheSoleSelectedDotfileResyncsSelection() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        item.showHidden(true)
        await item.listed()
        try select([".hidden"], in: item)
        #expect(item.selectedName == ".hidden")
        item.showHidden(false)
        await item.listed()
        #expect(item.selectedName != ".hidden")
        #expect(selected(item) != [".hidden"])
        #expect(item.selectedName == item.controller.selectedEntry?.name)
        #expect(selected(item) == [item.selectedName].compactMap { $0 })
    }

    @Test func aRankMovingLiveUpdatePreservesMultiSelection() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        item.sort(by: ListingOrder(column: .size, ascending: true))
        await item.listed()
        try select(["a.txt", "b.bin"], in: item)
        try Data(count: 500).write(to: folder.appendingPathComponent("a.txt"))
        await until(in: item) {
            item.entries.first { $0.name == "a.txt" }?.size == 500
        }
        await item.listed()
        #expect(Set(selected(item)) == ["a.txt", "b.bin"])
        #expect(item.selectedName == "b.bin")
    }

    @Test func reloadWithUnchangedIndexesRefreshesSelectionListing() async throws {
        defer { cleanUp() }
        let item = await browser(at: folder)
        defer { item.willClose() }
        item.showHidden(true)
        await item.listed()
        // `.hidden` sorts last on `name`, so after hiding it `a.txt` keeps row index 2
        // and `selectRowIndexes([2])` is a no-op; `selection` must still drop `.hidden`.
        item.sort(by: ListingOrder(column: .name, ascending: false))
        await item.listed()
        try select(["a.txt", ".hidden"], in: item)
        #expect(item.selectedName == ".hidden")
        item.showHidden(false)
        await item.listed()
        #expect(item.selectedName == "a.txt")
        #expect(selected(item) == ["a.txt"])
    }

    @Test func staleSelectionSummaryDoesNotOverwriteAfterFolderChange() async throws {
        defer { cleanUp() }
        let big1 = root.appendingPathComponent("big1")
        let big2 = root.appendingPathComponent("big2")
        for dir in [big1, big2] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for index in 0..<(FolderListing.mainActorLimit + 10) {
                FileManager.default.createFile(
                    atPath: dir.appendingPathComponent("f\(index)").path, contents: nil)
            }
        }
        var status = ""
        let item = BrowserItem(folder: big1, grants: grants) { _, _ in }
        let host = RecordingHost { status = $0 }
        item.host = host
        _ = item.viewController.view
        await item.listed()
        defer { item.willClose() }

        item.controller.tableView.selectAll(nil)
        let staleTask = item.controller.selectionSummaryTask
        item.go(to: big2)
        await item.listed()
        item.controller.tableView.selectAll(nil)
        let currentTask = item.controller.selectionSummaryTask

        await staleTask?.value
        await currentTask?.value
        #expect(status.contains(big2.path))
        #expect(!status.contains(big1.path))
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
