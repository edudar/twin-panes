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
        let unviewed = BrowserItem(folder: folder, grants: grants) { _, _ in }
        #expect(unviewed.currentSelection.isEmpty)
        let item = await browser(at: folder)
        defer { item.willClose() }
        try select(["c.png", "a.txt", "sub"], in: item)
        #expect(selected(item) == ["sub", "a.txt", "c.png"])
        #expect(item.currentSelection.entries.map(\.name) == ["sub", "a.txt", "c.png"])
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

    @Test func applyRowChangesPreservesWantedSelectionWhenSelectedRowIsRemoved() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("merge"), withIntermediateDirectories: true)
        let item = await browser(at: folder)
        defer { item.willClose() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = item.viewController.view
        window.layoutIfNeeded()
        window.makeFirstResponder(item.controller.tableView)
        try select(["docs"], in: item)
        item.selectWhenListed("renamed")
        let renamed = DirectoryEntry(
            url: folder.appendingPathComponent("renamed"), name: "renamed", isDirectory: true,
            isPackage: false, isSymbolicLink: false, isHidden: false, size: nil, modified: nil,
            type: .folder)
        let previous = item.listing
        let withoutDocs = previous.removing(names: ["docs"])
        item.replaceListing(with: withoutDocs)
        let removeChanges = try #require(
            withoutDocs.rowChanges(from: previous, touching: ["docs"], limit: 100))
        #expect(item.controller.applyRowChanges(removeChanges))
        #expect(item.controller.wantedSelection == "renamed")

        let withRenamed = withoutDocs.merging([renamed])
        item.replaceListing(with: withRenamed)
        let insertChanges = try #require(
            withRenamed.rowChanges(from: withoutDocs, touching: ["renamed"], limit: 100))
        #expect(item.controller.applyRowChanges(insertChanges))
        #expect(item.selectedName == "renamed")
        #expect(selected(item) == ["renamed"])
        #expect(item.controller.wantedSelection == nil)
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

    @Test func liveUpdatePreservesAndUpdatesMultiRowSelectionStatus() async throws {
        defer { cleanUp() }
        var status = ""
        let item = BrowserItem(folder: folder, grants: grants) { _, _ in }
        let host = RecordingHost { status = $0 }
        item.host = host
        _ = item.viewController.view
        await item.listed()
        defer { item.willClose() }
        #expect(status.contains("4 items"))

        try select(["a.txt", "b.bin"], in: item)
        #expect(status.contains("2 of 4 selected"))
        #expect(status.contains("310 bytes"))

        try Data(count: 50).write(to: folder.appendingPathComponent("d.txt"))
        await until(in: item) { item.entries.contains { $0.name == "d.txt" } }
        await item.listed()
        #expect(status.contains("2 of 5 selected"))
        #expect(status.contains("310 bytes"))

        try FileManager.default.removeItem(at: folder.appendingPathComponent("c.png"))
        await until(in: item) { !item.entries.contains { $0.name == "c.png" } }
        await item.listed()
        #expect(status.contains("2 of 4 selected"))
        #expect(status.contains("310 bytes"))

        try Data(count: 40).write(to: folder.appendingPathComponent("a.txt"))
        await until(in: item) { item.entries.first { $0.name == "a.txt" }?.size == 40 }
        await item.listed()
        #expect(status.contains("2 of 4 selected"))
        #expect(status.contains("340 bytes"))
    }

    @Test func liveUpdatePreservesSingleRowSelectionStatusAndUpdatesSize() async throws {
        defer { cleanUp() }
        var status = ""
        let item = BrowserItem(folder: folder, grants: grants) { _, _ in }
        let host = RecordingHost { status = $0 }
        item.host = host
        _ = item.viewController.view
        await item.listed()
        defer { item.willClose() }

        try select(["a.txt"], in: item)
        #expect(status.contains(folder.appendingPathComponent("a.txt").path))
        #expect(status.contains("10 bytes"))

        try Data(count: 50).write(to: folder.appendingPathComponent("d.txt"))
        await until(in: item) { item.entries.contains { $0.name == "d.txt" } }
        await item.listed()
        #expect(status.contains(folder.appendingPathComponent("a.txt").path))
        #expect(status.contains("10 bytes"))

        try Data(count: 42).write(to: folder.appendingPathComponent("a.txt"))
        await until(in: item) { item.entries.first { $0.name == "a.txt" }?.size == 42 }
        await item.listed()
        #expect(status.contains(folder.appendingPathComponent("a.txt").path))
        #expect(status.contains("42 bytes"))
    }

    @Test func liveUpdatePreservesParentRowSelectionStatus() async throws {
        defer { cleanUp() }
        var status = ""
        let item = BrowserItem(folder: folder, grants: grants) { _, _ in }
        let host = RecordingHost { status = $0 }
        item.host = host
        _ = item.viewController.view
        await item.listed()
        defer { item.willClose() }

        try select(["a.txt"], in: item)
        item.controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
        #expect(status.hasPrefix("Parent folder:"))

        try Data(count: 50).write(to: folder.appendingPathComponent("d.txt"))
        await until(in: item) { item.entries.contains { $0.name == "d.txt" } }
        await item.listed()
        #expect(status.hasPrefix("Parent folder:"))
    }

    @Test func emptyingFolderAfterSingleSelectionFallsBackToFolderSummary() async throws {
        defer { cleanUp() }
        let single = root.appendingPathComponent("single", isDirectory: true)
        try FileManager.default.createDirectory(at: single, withIntermediateDirectories: true)
        try Data(count: 7).write(to: single.appendingPathComponent("only.txt"))

        var status = ""
        let item = BrowserItem(folder: single, grants: grants) { _, _ in }
        let host = RecordingHost { status = $0 }
        item.host = host
        _ = item.viewController.view
        await item.listed()
        defer { item.willClose() }

        try select(["only.txt"], in: item)
        #expect(status.contains("only.txt"))
        #expect(status.contains("7 bytes"))

        try FileManager.default.removeItem(at: single.appendingPathComponent("only.txt"))
        await until(in: item) { item.entries.isEmpty }
        await item.listed()
        #expect(status.contains("0 items (0 folders)"))
    }

    @Test func noticeNeedsAccessAndListingTakePriorityOverSelectionStatus() async throws {
        defer { cleanUp() }
        var status = ""
        let item = BrowserItem(folder: folder, grants: grants) { _, _ in }
        let host = RecordingHost { status = $0 }
        item.host = host
        _ = item.viewController.view
        await item.listed()
        defer { item.willClose() }

        try select(["a.txt", "b.bin"], in: item)
        #expect(status.contains("2 of 4 selected"))

        item.notice = "Important notice"
        item.updateStatus()
        #expect(status == "Important notice")

        item.notice = nil
        item.needsAccess = true
        item.updateStatus()
        #expect(status.contains("no access yet"))

        item.needsAccess = false
        item.go(to: folder)
        #expect(item.isListing)
        let synthetic = ["x.txt", "y.txt"].map { name in
            DirectoryEntry(
                url: folder.appendingPathComponent(name), name: name, isDirectory: false,
                isPackage: false, isSymbolicLink: false, isHidden: false, size: 1,
                modified: nil, type: .data)
        }
        item.received(.batch(synthetic))
        try select(["x.txt", "y.txt"], in: item)
        #expect(status.contains("2 of 2 selected"))
        item.updateStatus()
        #expect(status.contains("Listing…"))
        await item.listed()
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

    @Test func garbageReleasesItsValueOffTheMainThreadWhileBoxIsHeld() async {
        var box: Garbage<DeinitProbe>?
        let freedOffMain = await withCheckedContinuation { continuation in
            let garbage = Garbage(DeinitProbe { continuation.resume(returning: $0) })
            box = garbage
            DispatchQueue.global(qos: .utility).async { garbage.empty() }
        }
        #expect(freedOffMain)
        _ = box
    }
}

private final class DeinitProbe: @unchecked Sendable {
    private let onDeinit: @Sendable (Bool) -> Void
    init(_ onDeinit: @escaping @Sendable (Bool) -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit(!Thread.isMainThread) }
}

@MainActor
private final class RecordingHost: WorkspaceHost {
    let record: (String) -> Void
    init(_ record: @escaping (String) -> Void) { self.record = record }
    func showStatus(_ message: String) { record(message) }
}
