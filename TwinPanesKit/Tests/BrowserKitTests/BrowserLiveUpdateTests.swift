import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// Live updates in the tab (docs/plans/M4.md, D-f, step 9).
@MainActor
@Suite struct BrowserLiveUpdateTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserLiveUpdateTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let item: BrowserItem

    init() async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        for name in ["b.txt", "d.txt"] {
            fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(count: 3))
        }
        let grants = FolderGrants(
            defaults: UserDefaults(suiteName: root.appendingPathComponent("sub/defaults").path)!)
        item = BrowserItem(folder: root, grants: grants) { _, _ in }
        _ = item.viewController.view
        await item.listed()
    }

    func cleanUp() {
        item.willClose()
        try? FileManager.default.removeItem(at: root)
    }

    var names: [String] { item.entries.map(\.name) }

    /// Waits until `check` holds after a live update, failing after 10 s.
    func until(
        _ check: @escaping () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        if check() { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            item.didUpdate = { [item] in
                guard !finished, check() else { return }
                finished = true
                item.didUpdate = nil
                done.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !finished else { return }
                finished = true
                Issue.record("no such update within 10 s: \(names)", sourceLocation: sourceLocation)
                done.resume()
            }
        }
    }

    @Test func outsideChangesShowUpInOrderAndKeepTheSelection() async throws {
        defer { cleanUp() }
        let table = item.controller.tableView
        table.selectRowIndexes(
            [try #require(item.controller.row(named: "d.txt"))], byExtendingSelection: false)
        let fm = FileManager.default
        fm.createFile(atPath: root.appendingPathComponent("a.txt").path, contents: nil)
        await until { names == ["sub", "a.txt", "b.txt", "d.txt"] }
        #expect(item.controller.selectedEntry?.name == "d.txt")
        try fm.moveItem(
            at: root.appendingPathComponent("b.txt"), to: root.appendingPathComponent("c.txt"))
        await until { names == ["sub", "a.txt", "c.txt", "d.txt"] }
        try Data(count: 99).write(to: root.appendingPathComponent("a.txt"))
        await until { item.entries.first { $0.name == "a.txt" }?.size == 99 }
        try fm.removeItem(at: root.appendingPathComponent("a.txt"))
        await until { names == ["sub", "c.txt", "d.txt"] }
        #expect(item.controller.selectedEntry?.name == "d.txt" && !item.isListing)
    }

    @Test func aVanishedFolderSendsTheTabUp() async throws {
        defer { cleanUp() }
        item.go(to: root.appendingPathComponent("sub/deeper"))
        await item.listed()
        try FileManager.default.removeItem(at: root.appendingPathComponent("sub"))
        await until { item.folder.path == root.path }
        await item.listed()
        #expect(item.notice?.contains("“deeper” is no longer there") == true)
        #expect(names == ["b.txt", "d.txt"])
        item.go(to: root)
        #expect(item.notice == nil)
    }

    @Test func aFullRelistSwapsTheRowsInPlace() async throws {
        defer { cleanUp() }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("e.txt").path, contents: nil)
        item.folderChanged(.relist)
        await item.listed()
        #expect(names == ["sub", "b.txt", "d.txt", "e.txt"])
    }

    /// FSEvents tells every stream it dropped events when anything overflows it: a burst
    /// of re-list requests runs one re-list and, after a pause, one more.
    @Test func aBurstOfRelistsRunsTwice() async throws {
        defer { cleanUp() }
        for _ in 0..<20 { item.folderChanged(.relist) }
        #expect(item.relistsStarted == 1)
        await until { item.relistsStarted == 2 }
        await item.listed()
        #expect(
            item.relistsStarted == 2 && !item.isRelisting && names == ["sub", "b.txt", "d.txt"])
    }

    /// A re-list asked for while the folder is still listing waits for the listing, so
    /// the two never pile the same entries into the rows.
    @Test func aRelistDuringTheListingWaitsForIt() async throws {
        defer { cleanUp() }
        let big = root.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<3_000 {
            FileManager.default.createFile(
                atPath: big.appendingPathComponent("f\(i)").path, contents: nil)
        }
        item.go(to: big)
        #expect(item.isListing)
        item.folderChanged(.relist)
        #expect(item.relistsStarted == 0)
        await item.listed()
        await until { item.relistsStarted == 1 }
        await item.listed()
        #expect(item.entries.count == 3_000 && Set(item.entries.map(\.name)).count == 3_000)
    }

    /// A live update that lands in the same run as the lister's last batches (FSEvents
    /// reported names while the final merge ran) isn't applied row by row: its changes
    /// would leave out the batch's rows, and NSTableView threw on the next insert.
    @Test func aLiveUpdateMixedWithListedRowsReloads() async throws {
        defer { cleanUp() }
        func entry(_ name: String) -> DirectoryEntry {
            DirectoryEntry(
                url: root.appendingPathComponent(name), name: name, isDirectory: false,
                isPackage: false, isSymbolicLink: false, isHidden: false, size: 1, modified: nil,
                type: .data)
        }
        item.pendingRemovals = ["b.txt"]
        item.pendingBatch = [entry("b.txt")]  // read again
        item.received(.batch([entry("a1"), entry("a2"), entry("zz")]))  // listed
        let table = item.controller.tableView
        #expect(table.numberOfRows == item.controller.numberOfRows(in: table))
        #expect(names == ["sub", "a1", "a2", "b.txt", "d.txt", "zz"])
        // The lister's copy and the one read again share a run: only the latter stays.
        var newer = entry("d.txt")
        newer = DirectoryEntry(
            url: newer.url, name: newer.name, isDirectory: false, isPackage: false,
            isSymbolicLink: false, isHidden: false, size: 77, modified: nil, type: .data)
        item.pendingRemovals = ["d.txt"]
        item.pendingBatch = [entry("d.txt"), newer]
        item.pendingHasListed = true
        item.applyPending()
        #expect(names.filter { $0 == "d.txt" }.count == 1)
        #expect(item.entries.first { $0.name == "d.txt" }?.size == 77)
        // And changes that aren't the table's are refused rather than thrown on.
        let wrong = RowChanges(removed: [], inserted: [50], changed: [], oldCount: 40, newCount: 41)
        #expect(!item.controller.applyRowChanges(wrong))
    }

    @Test func closingTheTabStopsWatching() async throws {
        defer { cleanUp() }
        #expect(item.watcher != nil)
        item.willClose()
        #expect(item.watcher == nil)
    }

    /// A small change updates rows in place: the other rows keep their views.
    @Test func aSmallChangeLeavesTheOtherRowsAlone() async throws {
        defer { cleanUp() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = item.controller.view
        defer { window.close() }
        // FSEvents delivers in order: once this shows, events from setting the folder up
        // (which would reload those rows, rightly) are behind us.
        FileManager.default.createFile(atPath: root.appendingPathComponent("z").path, contents: nil)
        await until { names.last == "z" }
        let table = item.controller.tableView
        window.contentView?.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        let dRow = try #require(item.controller.row(named: "d.txt"))
        let dView = try #require(table.view(atColumn: 0, row: dRow, makeIfNecessary: false))
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("c.txt").path, contents: nil)
        await until { names == ["sub", "b.txt", "c.txt", "d.txt", "z"] }
        let moved = try #require(item.controller.row(named: "d.txt"))
        #expect(moved == dRow + 1)
        // Its row moved under its row view, and the stripes followed.
        let rowView = try #require(table.rowView(atRow: moved, makeIfNecessary: false))
        #expect(rowView.backgroundColor == item.controller.stripe(moved))
        #expect(table.view(atColumn: 0, row: moved, makeIfNecessary: false) === dView)
    }

    /// When the selected entry goes, the row that took its place is selected.
    @Test func removingTheSelectedEntrySelectsItsNeighbour() async throws {
        defer { cleanUp() }
        let table = item.controller.tableView
        let row = try #require(item.controller.row(named: "b.txt"))
        table.selectRowIndexes([row], byExtendingSelection: false)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        await until { names == ["sub", "d.txt"] }
        #expect(item.controller.selectedEntry?.name == "d.txt")
    }

    /// Resizing a file when sorted by size moves its row and keeps both visible rows and selection
    /// in sync with the listing.
    @Test func resizingAFileWhenSortedBySizeMovesItsRowAndKeepsSelection() async throws {
        defer { cleanUp() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = item.controller.view
        defer { window.close() }
        try Data(count: 1).write(to: root.appendingPathComponent("b.txt"))
        try Data(count: 50).write(to: root.appendingPathComponent("d.txt"))
        item.sort(by: ListingOrder(column: .size, ascending: true))
        await until {
            names == ["sub", "b.txt", "d.txt"]
                && item.entries.first { $0.name == "b.txt" }?.size == 1
                && item.entries.first { $0.name == "d.txt" }?.size == 50
        }
        let table = item.controller.tableView
        window.contentView?.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        let bRow = try #require(item.controller.row(named: "b.txt"))
        table.selectRowIndexes([bRow], byExtendingSelection: false)
        #expect(item.controller.selectedEntry?.name == "b.txt")
        try Data(count: 200).write(to: root.appendingPathComponent("b.txt"))
        await until {
            names == ["sub", "d.txt", "b.txt"]
                && item.entries.first { $0.name == "b.txt" }?.size == 200
        }
        #expect(item.controller.selectedEntry?.name == "b.txt")
        #expect(table.numberOfRows == 4)
        #expect(table.selectedRow == item.controller.row(named: "b.txt"))
        window.contentView?.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        let shownNames = (1..<4).compactMap {
            (table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? FileCell)?.text
        }
        #expect(shownNames == ["sub", "d.txt", "b.txt"])
    }

    private func makeEntry(_ name: String, size: UInt64 = 1) -> DirectoryEntry {
        DirectoryEntry(
            url: root.appendingPathComponent(name), name: name, isDirectory: false,
            isPackage: false, isSymbolicLink: false, isHidden: false, size: size, modified: nil,
            type: .data)
    }

    @Test func deleteWhileMergingPurgesBufferedEntry() async throws {
        defer { cleanUp() }
        item.isMerging = true
        item.readsInFlight = 2
        item.apply(removing: ["b.txt"], adding: [makeEntry("b.txt", size: 10)])
        item.apply(removing: ["b.txt"], adding: [])
        item.isMerging = false
        item.applyPending()
        #expect(!names.contains("b.txt"))
    }

    @Test func relistPendingReplacementDropsStalePendingEdits() async throws {
        defer { cleanUp() }
        item.isMerging = true
        item.pendingBatch = [makeEntry("stale.txt")]
        item.pendingRemovals = ["b.txt"]
        item.pendingHasListed = true
        item.relist()
        for _ in 0..<100 where item.pendingReplacement == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(item.pendingReplacement != nil)
        #expect(item.pendingBatch.isEmpty)
        #expect(item.pendingRemovals.isEmpty)
        #expect(!item.pendingHasListed)
        item.isMerging = false
        item.applyPending()
        #expect(names == ["sub", "b.txt", "d.txt"])
    }

    @Test func outOfOrderReadFinishedDoesNotOverwriteNewerRead() async throws {
        defer { cleanUp() }
        item.latestReadSequence["b.txt"] = 2
        item.readsInFlight = 2
        item.readFinished(["b.txt"], [], generation: item.generation, sequence: 2)
        item.readFinished(
            ["b.txt"], [makeEntry("b.txt", size: 999)], generation: item.generation, sequence: 1)
        #expect(!names.contains("b.txt"))
    }

    @Test func stopListingCancelsInFlightRelistLister() async throws {
        defer { cleanUp() }
        item.relist()
        let lister = try #require(item.relistLister)
        item.willClose()
        #expect(lister.isCancelled)
        #expect(item.relistLister == nil)
    }

    @Test func readChangedWhileListingWithRelistRequestedSkipsRedundantRead() async throws {
        defer { cleanUp() }
        let beforeReads = item.readsInFlight
        item.relistRequested = true
        item.changedWhileListing = ["b.txt", "d.txt"]
        item.readChangedWhileListing()
        #expect(item.changedWhileListing.isEmpty)
        #expect(item.relistsStarted == 1)
        #expect(item.readsInFlight == beforeReads + 1)
        await item.listed()
    }
}
