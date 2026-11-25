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

    // MARK: Editing the favorites (step 17)

    func makeFolder(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var favoriteNames: [String] { favorites.folders.map(\.lastPathComponent) }

    @Test func aFolderDroppedOnFavoritesIsAddedWhereItLands() throws {
        defer { cleanUp() }
        let projects = try makeFolder("Projects")
        #expect(sidebar.acceptDrop(of: [projects], at: 1))
        #expect(favoriteNames[1] == "Projects")
        #expect(titles[2] == "Projects")
    }

    @Test func aDroppedFileIsRefused() throws {
        defer { cleanUp() }
        let file = folder.appendingPathComponent("notes.txt")
        try Data([1]).write(to: file)
        #expect(!sidebar.acceptDrop(of: [file], at: 0))
        #expect(favorites.folders.count == 5)
    }

    @Test func aFavoriteDraggedFurtherDownLandsWhereItWasDropped() {
        defer { cleanUp() }
        let home = favorites.folders[0]
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Dropped between Documents (2) and Downloads (3), as the list shows it.
        #expect(sidebar.acceptDrop(of: [home], at: 3))
        #expect(favoriteNames == ["Desktop", "Documents", "home", "Downloads", "Applications"])
    }

    @Test func dropsLandBetweenFavoritesOrBeforeOneButNotOnLocations() throws {
        defer { cleanUp() }
        let section = sidebar.favoritesSection, locations = sidebar.locationsSection
        #expect(sidebar.dropIndex(proposedItem: section, childIndex: 2) == 2)
        #expect(sidebar.dropIndex(proposedItem: section.children[3], childIndex: -1) == 3)
        #expect(sidebar.dropIndex(proposedItem: locations, childIndex: 0) == nil)
        #expect(sidebar.dropIndex(proposedItem: locations.children[0], childIndex: -1) == nil)
    }

    /// A real drag is checked by hand; this checks AppKit finds the drag methods.
    @Test func theOutlineViewTakesDropsAndDragsFavorites() throws {
        defer { cleanUp() }
        let source = try #require(outline.dataSource)
        #expect(outline.registeredDraggedTypes.contains(.fileURL))
        for selector in [
            #selector(NSOutlineViewDataSource.outlineView(_:pasteboardWriterForItem:)),
            #selector(
                NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:)
            ),
            #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:)),
        ] {
            #expect(source.responds(to: selector))
        }
    }

    @Test func removingAFavoriteTakesItOutOfTheList() throws {
        defer { cleanUp() }
        sidebar.removeFavorite(atRow: try row("Documents"))
        #expect(!favoriteNames.contains("Documents") && !titles.contains("Documents"))
    }

    @Test func removingLeavesVolumesAndHeadingsAlone() throws {
        defer { cleanUp() }
        sidebar.removeFavorite(atRow: try row("USB"))
        sidebar.removeFavorite(atRow: try row("Favorites"))
        #expect(titles.contains("USB") && favorites.folders.count == 5)
    }

    // MARK: Ejecting (step 18)

    func ejectButton(onRow title: String) throws -> EjectButton? {
        let cell = outline.view(atColumn: 0, row: try row(title), makeIfNecessary: true)
        return cell?.subviews.lazy.compactMap { $0 as? EjectButton }.first
    }

    @Test func anEjectableVolumesButtonReportsTheVolume() throws {
        defer { cleanUp() }
        var ejected: [String] = []
        sidebar.onEject = { ejected.append($0.name) }
        try #require(try ejectButton(onRow: "USB")).performClick(nil)
        #expect(ejected == ["USB"])
    }

    @Test func aVolumeThatCantBeEjectedHasNoButton() throws {
        defer { cleanUp() }
        #expect(try ejectButton(onRow: "Macintosh HD") == nil)
    }
}
