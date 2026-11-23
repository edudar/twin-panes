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
}
