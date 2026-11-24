import AppKit
import Testing
import WorkspaceKit

@testable import BrowserKit
@testable import TwinPanesCore

@MainActor
private final class StatusHost: WorkspaceHost {
    var statuses: [String] = []
    func showStatus(_ message: String) { statuses.append(message) }
}

/// A browser tab's state comes back after a relaunch (docs/plans/M5.md, D-c, step 8).
@MainActor
@Suite struct BrowserStateTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowserStateTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let grants: FolderGrants
    let item: BrowserItem

    init() async throws {
        let fm = FileManager.default
        for path in ["a/inner", "b", "prefs"] {
            try fm.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for name in ["z.txt", ".hidden"] {
            fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data([1]))
        }
        grants = FolderGrants(
            defaults: UserDefaults(suiteName: root.appendingPathComponent("prefs/defaults").path)!)
        item = BrowserItem(folder: root, grants: grants) { _, _ in }
        _ = item.viewController.view
        await item.listed()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }

    func go(_ path: String) async {
        item.go(to: url(path))
        await item.listed()
    }

    /// A tab rebuilt from `item`'s state, listed as it would be once shown.
    func restored(host: WorkspaceHost? = nil) async throws -> BrowserItem {
        let state = try #require(item.restorableState)
        let tab = try #require(BrowserItem.restored(from: state, grants: grants) { _, _ in })
        tab.host = host
        _ = tab.viewController.view
        await tab.listed()
        return tab
    }

    @Test func theStateIsABrowsersCurrentVersion() throws {
        defer { cleanUp() }
        let state = try #require(item.restorableState)
        #expect(state.kind == .browser && state.version == BrowserItem.stateVersion)
    }

    @Test func folderSortHiddenFilesAndSelectionComeBack() async throws {
        defer { cleanUp() }
        let order = ListingOrder(column: .size, ascending: false, foldersFirst: false)
        item.sort(by: order)
        item.showHidden(true)
        await item.listed()
        let table = item.controller.tableView
        table.selectRowIndexes(
            [try #require(item.controller.row(named: "z.txt"))], byExtendingSelection: false)
        let tab = try await restored()
        #expect(tab.folder == root)
        #expect(tab.order == order && tab.showsHidden)
        #expect(tab.entries.contains { $0.name == ".hidden" })
        #expect(tab.controller.selectedEntry?.name == "z.txt")
    }

    @Test func backAndForwardComeBack() async throws {
        defer { cleanUp() }
        await go("a")
        await go("b")
        item.goBack()
        await item.listed()
        let tab = try await restored()
        #expect(tab.folder == url("a") && tab.canGoBack && tab.canGoForward)
        tab.goForward()
        await tab.listed()
        #expect(tab.folder == url("b"))
        tab.goBack()
        await tab.listed()
        tab.goBack()
        await tab.listed()
        #expect(tab.folder == root && !tab.canGoBack)
    }

    @Test func aFolderThatsGoneOpensItsNearestAncestorAndSaysSo() async throws {
        defer { cleanUp() }
        await go("a/inner")
        let state = try #require(item.restorableState)
        try FileManager.default.removeItem(at: url("a"))
        let host = StatusHost()
        let tab = try #require(BrowserItem.restored(from: state, grants: grants) { _, _ in })
        tab.host = host
        _ = tab.viewController.view
        await tab.listed()
        #expect(tab.folder == root)
        #expect(host.statuses.last?.contains("no longer there") == true)
    }

    @Test func aPayloadThatIsntABrowsersIsRefused() {
        defer { cleanUp() }
        let state = ItemState(kind: .browser, version: 1, payload: Data("not json".utf8))
        #expect(BrowserItem.restored(from: state, grants: grants) { _, _ in } == nil)
    }
}
