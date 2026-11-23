import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// Rows refreshed in the views already on screen (docs/plans/M4.md, performance pass,
/// step 5): a listing batch of thousands of rows rebuilt every visible row view.
@MainActor
@Suite struct BrowserRefreshTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserRefreshTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let item: BrowserItem
    let window: NSWindow

    init() async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for (i, size) in [5, 50, 500, 5_000].enumerated() {
            fm.createFile(
                atPath: root.appendingPathComponent("f\(i).txt").path, contents: Data(count: size))
        }
        let grants = FolderGrants(
            defaults: UserDefaults(suiteName: root.appendingPathComponent("sub/defaults").path)!)
        item = BrowserItem(folder: root, grants: grants) { _, _ in }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = item.controller.view
        item.go()
        await item.listed()
        layOut()
    }

    func cleanUp() {
        window.close()
        item.willClose()
        try? FileManager.default.removeItem(at: root)
    }

    var table: NSTableView { item.controller.tableView }
    func layOut() { window.contentView?.layoutSubtreeIfNeeded() }

    /// The name cells on screen, by row, with the name each shows.
    func shownNames() -> [Int: (cell: FileCell, text: String)] {
        var shown: [Int: (FileCell, String)] = [:]
        table.enumerateAvailableRowViews { rowView, row in
            if let cell = rowView.view(atColumn: 0) as? FileCell { shown[row] = (cell, cell.text) }
        }
        return shown
    }

    func expectCellsMatchTheRows(sourceLocation: SourceLocation = #_sourceLocation) {
        for (row, shown) in shownNames() {
            #expect(
                shown.text == item.controller.entry(atRow: row)?.name,
                sourceLocation: sourceLocation)
        }
    }

    func entries(_ count: Int, prefix: String) -> [DirectoryEntry] {
        (0..<count).map {
            DirectoryEntry(
                url: root.appendingPathComponent("\(prefix)\($0)"), name: "\(prefix)\($0)",
                isDirectory: false, isPackage: false, isSymbolicLink: false, isHidden: false,
                size: 1, modified: nil, type: .data)
        }
    }

    @Test func thousandsMoreRowsKeepTheRowViews() async throws {
        defer { cleanUp() }
        let rowView = try #require(table.rowView(atRow: 1, makeIfNecessary: false))
        item.pendingBatch += entries(3_000, prefix: "a")  // sorts before the files on screen
        item.applyPending()
        await item.listed()
        layOut()
        #expect(table.numberOfRows == item.entries.count + 1)
        #expect(table.rowView(atRow: 1, makeIfNecessary: false) === rowView)
        expectCellsMatchTheRows()
    }

    @Test func aSortShowsTheNewRowsInTheSameCells() async throws {
        defer { cleanUp() }
        let before = shownNames()
        item.sort(by: ListingOrder(column: .size, ascending: false))
        await item.listed()
        layOut()
        #expect(item.entries.dropFirst().first?.name == "f3.txt")
        let after = shownNames()
        #expect(Set(after.keys) == Set(before.keys))
        for (row, shown) in after { #expect(shown.cell === before[row]?.cell) }
        expectCellsMatchTheRows()
    }

    @Test func thousandsFewerRowsStillShowTheRightOnes() async throws {
        defer { cleanUp() }
        item.pendingBatch += entries(3_000, prefix: "a")
        item.applyPending()
        await item.listed()
        item.pendingRemovals = Set(entries(3_000, prefix: "a").map(\.name))
        item.applyPending()
        await item.listed()
        layOut()
        #expect(table.numberOfRows == item.entries.count + 1)
        expectCellsMatchTheRows()
    }

    /// A file renamed and another resized from outside show their new name and size.
    @Test func outsideChangesShowInTheirCells() async throws {
        defer { cleanUp() }
        let fm = FileManager.default
        try fm.moveItem(
            at: root.appendingPathComponent("f0.txt"), to: root.appendingPathComponent("g0.txt"))
        try Data(count: 2_000_000).write(to: root.appendingPathComponent("f1.txt"))
        // As FSEvents would report them; the watcher has tests of its own.
        item.folderChanged(.names(["f0.txt", "g0.txt", "f1.txt"]))
        await item.listed()
        #expect(item.entries.contains { $0.name == "g0.txt" })
        #expect(item.entries.first { $0.name == "f1.txt" }?.size == 2_000_000)
        layOut()
        expectCellsMatchTheRows()
        let row = try #require(item.controller.row(named: "f1.txt"))
        let size = table.view(atColumn: 1, row: row, makeIfNecessary: false) as? FileCell
        #expect(
            size?.text == ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file))
    }
}

extension BrowserRefreshTests {
    /// Each row draws its cells into its own layer: four layers a row cost more to
    /// commit (docs/plans/M4.md, performance pass, step 7).
    @Test func cellsDrawIntoTheirRowsLayer() async throws {
        defer { cleanUp() }
        window.contentView?.wantsLayer = true
        layOut()
        var cells = 0
        table.enumerateAvailableRowViews { rowView, _ in
            for column in 0..<table.numberOfColumns {
                guard let cell = rowView.view(atColumn: column) as? FileCell else { continue }
                cells += 1
                #expect(cell.layer == nil)
            }
        }
        #expect(cells > 0)
    }
}
