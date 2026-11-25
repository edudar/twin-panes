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

    @Test func backgroundTabRestorableStatePreservesRestoredSelection() async throws {
        defer { cleanUp() }
        let table = item.controller.tableView
        table.selectRowIndexes(
            [try #require(item.controller.row(named: "z.txt"))], byExtendingSelection: false)
        let saved = try #require(item.restorableState)
        let background = try #require(BrowserItem.restored(from: saved, grants: grants) { _, _ in })
        #expect(!background.hasListed)
        #expect(background.restoredSelection == "z.txt")
        let reencoded = try #require(background.restorableState)
        #expect(!background.hasListed)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: reencoded.payload)
        #expect(decoded.selected == "z.txt")
    }

    @Test func invalidKindVersionOrRelativePathIsRefused() throws {
        defer { cleanUp() }
        let validPayload = try #require(item.restorableState).payload
        let wrongKind = ItemState(kind: ItemKind("other"), version: 1, payload: validPayload)
        #expect(BrowserItem.restored(from: wrongKind, grants: grants) { _, _ in } == nil)
        for badVersion in [0, -1, BrowserItem.stateVersion + 1] {
            let state = ItemState(kind: .browser, version: badVersion, payload: validPayload)
            #expect(BrowserItem.restored(from: state, grants: grants) { _, _ in } == nil)
        }
        let relative = BrowserState(
            folder: "relative/path", selected: nil, back: [], forward: [],
            sortColumn: ListingOrder.Column.name.rawValue, ascending: true,
            foldersFirst: true, showsHidden: false)
        let relState = ItemState(
            kind: .browser, version: 1, payload: try JSONEncoder().encode(relative))
        #expect(BrowserItem.restored(from: relState, grants: grants) { _, _ in } == nil)
    }

    @Test func historyIsCappedAndRelativePlacesAreFiltered() throws {
        defer { cleanUp() }
        let places = (0..<120).map { BrowserState.Place(path: "/dir/\($0)", selected: nil) }
        let state = BrowserState(
            folder: root.path, selected: nil,
            back: [BrowserState.Place(path: "rel/a", selected: nil)] + places,
            forward: places + [BrowserState.Place(path: "rel/b", selected: nil)],
            sortColumn: "unknownColumn", ascending: true,
            foldersFirst: true, showsHidden: false)
        let itemState = ItemState(
            kind: .browser, version: 1, payload: try JSONEncoder().encode(state))
        let tab = try #require(BrowserItem.restored(from: itemState, grants: grants) { _, _ in })
        #expect(tab.order.column == .name)
        #expect(tab.backStack.count == BrowserItem.maxHistory)
        #expect(tab.backStack.first?.folder.path == "/dir/20")
        #expect(tab.backStack.last?.folder.path == "/dir/119")
        #expect(tab.forwardStack.count == BrowserItem.maxHistory)
        #expect(tab.forwardStack.first?.folder.path == "/dir/20")
        #expect(tab.forwardStack.last?.folder.path == "/dir/119")
    }

    @Test func historyPushCapsAtMaxHistory() async throws {
        defer { cleanUp() }
        let fm = FileManager.default
        for i in 0..<(BrowserItem.maxHistory + 5) {
            try fm.createDirectory(at: url("h\(i)"), withIntermediateDirectories: true)
            item.go(to: url("h\(i)"))
        }
        await item.listed()
        #expect(item.backStack.count == BrowserItem.maxHistory)
        #expect(item.backStack.last?.folder == url("h\(BrowserItem.maxHistory + 3)"))
    }

    @Test func historyEntrySelectedRoundTrips() async throws {
        defer { cleanUp() }
        let table = item.controller.tableView
        table.selectRowIndexes(
            [try #require(item.controller.row(named: "z.txt"))], byExtendingSelection: false)
        await go("a")
        let tab = try await restored()
        #expect(tab.backStack.last?.selected == "z.txt")
        tab.goBack()
        await tab.listed()
        #expect(tab.controller.selectedEntry?.name == "z.txt")
    }
}
