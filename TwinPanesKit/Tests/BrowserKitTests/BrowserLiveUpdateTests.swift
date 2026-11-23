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
}
