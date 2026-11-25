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

    @Test func editsAreReportedSoOtherSidebarsCanShowThem() throws {
        defer { cleanUp() }
        var edits = 0
        sidebar.onFavoritesEdited = {
            edits += 1
            sidebar.reloadFavorites()
        }
        _ = sidebar.acceptDrop(of: [try makeFolder("Projects")], at: 0)
        sidebar.removeFavorite(atRow: try row("Projects"))
        #expect(edits == 2)
    }

    @Test func theMenusRemoveActsOnTheSelectedFavoriteWithoutARightClick() throws {
        defer { cleanUp() }
        outline.selectRowIndexes([try row("Downloads")], byExtendingSelection: false)
        sidebar.removeClickedFavorite(nil)
        #expect(!favoriteNames.contains("Downloads"))
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

    @Test func ejectButtonKeepsRequiredHorizontalCompressionAndHugging() throws {
        defer { cleanUp() }
        let eject = try #require(try ejectButton(onRow: "USB"))
        #expect(eject.contentCompressionResistancePriority(for: .horizontal) == .required)
        #expect(eject.contentHuggingPriority(for: .horizontal) == .required)
    }

    @Test func layoutSizesColumnToSidebarWidthAndStylesHeadingsDifferently() throws {
        defer { cleanUp() }
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
        sidebar.view.layoutSubtreeIfNeeded()
        #expect((outline.outlineTableColumn?.width ?? 0) > 150)

        let heading =
            outline.view(atColumn: 0, row: try row("Favorites"), makeIfNecessary: true)
            as? NSTableCellView
        let item =
            outline.view(atColumn: 0, row: try row("Desktop"), makeIfNecessary: true)
            as? NSTableCellView
        #expect(heading?.textField?.font?.pointSize == NSFont.smallSystemFontSize)
        #expect(heading?.textField?.textColor == .secondaryLabelColor)
        #expect(item?.textField?.font?.pointSize == NSFont.systemFontSize)
        #expect(heading?.textField?.font != item?.textField?.font)
    }

    @Test func highlightingMatchesSymlinkPathsAndNilClearsSelection() throws {
        defer { cleanUp() }
        let desktop = favorites.standard[1]
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let alias = folder.appendingPathComponent("DesktopAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: desktop)

        sidebar.highlight(alias)
        #expect(outline.selectedRow == (try row("Desktop")))

        sidebar.highlight(nil)
        #expect(outline.selectedRow == -1)
    }

    func draggingInfo(urls: [URL], sequence: Int) -> any NSDraggingInfo {
        let pb = NSPasteboard.withUniqueName()
        pb.writeObjects(urls as [NSURL])
        return StubDraggingInfo(pasteboard: pb, sequence: sequence)
    }

    @Test func appPackagesAndRegularFilesAreRefusedInValidateDropAndAcceptDrop() throws {
        defer { cleanUp() }
        let app = folder.appendingPathComponent("Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try Data([1]).write(to: file)

        #expect(!sidebar.acceptDrop(of: [app], at: 0))
        #expect(
            sidebar.outlineView(
                outline, validateDrop: draggingInfo(urls: [app], sequence: 1),
                proposedItem: sidebar.favoritesSection, proposedChildIndex: 0) == [])
        #expect(
            sidebar.outlineView(
                outline, validateDrop: draggingInfo(urls: [file], sequence: 2),
                proposedItem: sidebar.favoritesSection, proposedChildIndex: 0) == [])
    }

    @Test func symlinkToFolderIsAcceptedInValidateDropAndAcceptDrop() throws {
        defer { cleanUp() }
        let target = try makeFolder("Real")
        let link = folder.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let operation = sidebar.outlineView(
            outline, validateDrop: draggingInfo(urls: [link], sequence: 3),
            proposedItem: sidebar.favoritesSection, proposedChildIndex: 0)
        #expect(operation == .link)
        #expect(sidebar.acceptDrop(of: [link], at: 0))
        #expect(favoriteNames.first == "Link")
    }

    @Test func emptySpaceRightClickDisablesRemoveFromSidebarEvenWithSelection() throws {
        defer { cleanUp() }
        _ = NSApplication.shared
        outline.selectRowIndexes([try row("Downloads")], byExtendingSelection: false)
        let rightClick = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        NSApp.postEvent(rightClick, atStart: true)
        _ = NSApp.nextEvent(
            matching: .rightMouseDown, until: .distantPast, inMode: .default, dequeue: true)
        defer {
            if let reset = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
            {
                NSApp.postEvent(reset, atStart: true)
                _ = NSApp.nextEvent(
                    matching: .applicationDefined, until: .distantPast, inMode: .default,
                    dequeue: true)
            }
        }
        let removeItem = try #require(
            outline.menu?.items.first {
                $0.action == #selector(SidebarViewController.removeClickedFavorite(_:))
            })
        #expect(!sidebar.validateMenuItem(removeItem))
    }
}

@MainActor
private final class StubDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int

    init(pasteboard: NSPasteboard, sequence: Int) {
        self.draggingPasteboard = pasteboard
        self.draggingSequenceNumber = sequence
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
