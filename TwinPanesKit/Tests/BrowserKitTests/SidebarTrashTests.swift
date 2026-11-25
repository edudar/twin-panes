import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// The Trash row in Locations, which only Full Disk Access lets the app list.
@MainActor
@Suite struct SidebarTrashTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidebarTrashTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    var home: URL { folder.appendingPathComponent("home", isDirectory: true) }
    let sidebar: SidebarViewController

    init() throws {
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("prefs"), withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("prefs/defaults").path
        let favorites = Favorites(
            defaults: try #require(UserDefaults(suiteName: suite)),
            home: folder.appendingPathComponent("home", isDirectory: true))
        sidebar = SidebarViewController(favorites: favorites)
        _ = sidebar.view
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    var trashRow: Int? {
        let outline = sidebar.outlineView
        return (0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarNode)?.title == "Trash"
        }
    }

    func canChoose(_ row: Int) -> Bool {
        let outline = sidebar.outlineView
        return sidebar.outlineView(outline, shouldSelectItem: outline.item(atRow: row) as Any)
    }

    @Test func anUnlistableTrashIsGreyedOutAndCantBeChosen() async throws {
        defer { cleanUp() }
        await sidebar.refreshTrashAccess()
        let row = try #require(trashRow)
        #expect(!canChoose(row))
        let cell = sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
        #expect(cell?.toolTip?.contains("Full Disk Access") == true)
    }

    @Test func aListableTrashOpensLikeAnyLocation() async throws {
        defer { cleanUp() }
        let trash = TrashFolder(home: home)
        try FileManager.default.createDirectory(at: trash.url, withIntermediateDirectories: true)
        await sidebar.refreshTrashAccess()
        let row = try #require(trashRow)
        #expect(canChoose(row))
        var opened: [URL] = []
        sidebar.onOpen = { opened.append($0) }
        sidebar.outlineView.selectRowIndexes([row], byExtendingSelection: false)
        #expect(opened == [trash.url])
    }

    @Test func losingAccessGreysTheTrashOutAgain() async throws {
        defer { cleanUp() }
        let trash = TrashFolder(home: home)
        try FileManager.default.createDirectory(at: trash.url, withIntermediateDirectories: true)
        await sidebar.refreshTrashAccess()
        try FileManager.default.removeItem(at: trash.url)
        await sidebar.refreshTrashAccess()
        #expect(!canChoose(try #require(trashRow)))
    }
}
