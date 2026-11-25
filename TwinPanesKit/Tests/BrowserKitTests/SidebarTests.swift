import AppKit
import Testing

@testable import BrowserKit
@testable import TwinPanesCore

/// The sidebar's sections, clicks and highlight (docs/plans/M5.md, D-d, step 16).
@MainActor
@Suite struct SidebarTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidebarTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    let favorites: Favorites
    let sidebar: SidebarViewController
    let volumes = [
        Volume(
            url: URL(fileURLWithPath: "/", isDirectory: true), name: "Macintosh HD",
            isEjectable: false),
        Volume(
            url: URL(fileURLWithPath: "/Volumes/USB", isDirectory: true), name: "USB",
            isEjectable: true),
    ]

    init() throws {
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("prefs"), withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("prefs/defaults").path
        favorites = Favorites(
            defaults: try #require(UserDefaults(suiteName: suite)),
            home: folder.appendingPathComponent("home", isDirectory: true))
        sidebar = SidebarViewController(favorites: favorites)
        _ = sidebar.view
        sidebar.show(volumes: volumes)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    var outline: NSOutlineView { sidebar.outlineView }

    var titles: [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNode)?.title }
    }

    func row(_ title: String) throws -> Int {
        try #require(titles.firstIndex(of: title))
    }

    @Test func favoritesAndVolumesShowUnderTheirSections() {
        defer { cleanUp() }
        #expect(
            titles == [
                "Favorites", "home", "Desktop", "Documents", "Downloads", "Applications",
                "Locations", "Macintosh HD", "USB",
            ])
    }

    @Test func choosingARowOpensItsFolder() throws {
        defer { cleanUp() }
        var opened: [URL] = []
        sidebar.onOpen = { opened.append($0) }
        outline.selectRowIndexes([try row("USB")], byExtendingSelection: false)
        #expect(opened.map(\.path) == ["/Volumes/USB"])
    }

    @Test func aSectionHeadingCantBeChosen() throws {
        defer { cleanUp() }
        let heading = outline.item(atRow: try row("Locations"))
        #expect(sidebar.outlineView(outline, shouldSelectItem: heading as Any) == false)
    }

    @Test func highlightingSelectsTheFoldersRowWithoutOpeningIt() throws {
        defer { cleanUp() }
        var opened: [URL] = []
        sidebar.onOpen = { opened.append($0) }
        sidebar.highlight(URL(fileURLWithPath: "/Applications/", isDirectory: true))
        #expect(outline.selectedRow == (try row("Applications")))
        #expect(opened.isEmpty)
    }

    @Test func highlightingAFolderThatIsntListedClearsTheHighlight() throws {
        defer { cleanUp() }
        sidebar.highlight(URL(fileURLWithPath: "/Applications", isDirectory: true))
        sidebar.highlight(folder.appendingPathComponent("elsewhere"))
        #expect(outline.selectedRow == -1)
    }

    @Test func reloadingPicksUpChangedFavoritesAndKeepsTheHighlight() throws {
        defer { cleanUp() }
        sidebar.highlight(URL(fileURLWithPath: "/Applications", isDirectory: true))
        favorites.add(folder.appendingPathComponent("Projects"), at: 0)
        sidebar.reloadFavorites()
        #expect(titles[1] == "Projects")
        #expect(outline.selectedRow == (try row("Applications")))
    }
}
