import AppKit
import BrowserKit
import TwinPanesCore
import WorkspaceKit

extension SmokeTest {
    /// The sidebar in the real window (docs/plans/M5.md, D-d, steps 16 and 19): shown,
    /// toggled with ⌃⌘S; a chosen favorite or volume opens in the active panel, whose
    /// folder it highlights; and a favorite added or removed shows in every window.
    func sidebar(
        _ check: (Bool, String) -> Void, in controller: MainWindowController,
        alongside other: MainWindowController
    ) async {
        let frame = controller.frameController
        guard let window = controller.window, let content = window.contentView,
            let outline = Self.view(in: content, id: "sidebar") as? NSOutlineView,
            let browser = controller.layout.focusedPanelItem as? BrowserItem
        else { return check(false, "the window shows the sidebar beside a browser") }
        let width = outline.enclosingScrollView?.superview?.frame.width ?? 0
        check(
            frame.isSidebarShown && abs(width - 180) < 2,
            "the sidebar is shown, \(Int(width)) pt wide")
        // The one column fills the sidebar, less the outline's indent; at its default
        // 100 pt every name was cut off.
        let column = outline.tableColumns.first?.width ?? 0
        check(
            column >= outline.frame.width - 40,
            "the sidebar's names have its full width: column \(Int(column)) of \(Int(outline.frame.width)) pt"
        )
        let toggle = KeyChord("s", [.control, .command])
        check(dispatch(toggle, in: window) && !frame.isSidebarShown, "⌃⌘S hides the sidebar")
        check(dispatch(toggle, in: window) && frame.isSidebarShown, "and shows it again")

        let title = { (row: Int) in
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue
        }
        guard let row = (0..<outline.numberOfRows).first(where: { title($0) == "Applications" })
        else {
            return check(false, "the sidebar lists Applications")
        }
        // Finder's glyph comes as bitmaps from the system; a symbol has none.
        let appsIcon =
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
            .imageView?.image
        check(
            appsIcon?.isTemplate == true
                && appsIcon?.representations.contains { $0 is NSBitmapImageRep } == true,
            "Applications shows Finder's glyph")
        await trashRow(check, in: outline)

        outline.selectRowIndexes([row], byExtendingSelection: false)
        await browser.listed()
        check(
            browser.folder.path == "/Applications",
            "choosing a favorite opens it in the active panel")
        check(outline.selectedRow == row, "and the sidebar highlights it")
        browser.go(to: FileManager.default.temporaryDirectory)
        await browser.listed()
        check(outline.selectedRow == -1, "a folder the sidebar doesn't list clears the highlight")

        // The volumes arrive off the main actor; the boot volume comes first.
        let bootName = await Task.detached { MountedVolumes.current().first?.name }.value
        var bootRow: Int?
        for _ in 0..<100 where bootRow == nil {
            bootRow = (0..<outline.numberOfRows).first { title($0) == bootName }
            if bootRow == nil { await settle(milliseconds: 20) }
        }
        if let bootRow { outline.selectRowIndexes([bootRow], byExtendingSelection: false) }
        await browser.listed()
        check(browser.folder.path == "/", "choosing the boot volume opens it in the active panel")

        await editFavorites(check, in: outline, alongside: other)
    }

    /// Locations lists Home and the Trash. In the sandboxed app the Trash row can be chosen
    /// exactly when the app may list `~/.Trash`, which takes Full Disk Access.
    private func trashRow(_ check: (Bool, String) -> Void, in outline: NSOutlineView) async {
        let titles = (0..<outline.numberOfRows).map { row in
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue
        }
        guard let locations = titles.firstIndex(of: "Locations"),
            let trash = titles.lastIndex(of: "Trash")
        else { return check(false, "Locations lists the Trash") }
        let home = DirectoryReader.realHomeDirectory
        check(
            titles[locations + 1] == FileManager.default.displayName(atPath: home.path),
            "Locations starts with Home")
        let isListable = await Task.detached { TrashFolder(home: home).isListable() }.value
        let canChoose =
            outline.delegate?.outlineView?(
                outline, shouldSelectItem: outline.item(atRow: trash) as Any) ?? false
        check(
            canChoose == isListable,
            "the Trash row can be chosen only with Full Disk Access (listable: \(isListable))")
    }

    /// A folder dropped on Favorites through the outline view's real drop methods shows in
    /// both windows; Remove from Sidebar takes it out of both. A real drag session can't
    /// be synthesized, so the drop comes with a stand-in for its dragging info.
    private func editFavorites(
        _ check: (Bool, String) -> Void, in outline: NSOutlineView,
        alongside other: MainWindowController
    ) async {
        let otherOutline =
            other.window?.contentView.flatMap { Self.view(in: $0, id: "sidebar") }
            as? NSOutlineView
        func lists(_ name: String, in outline: NSOutlineView?) -> Bool {
            guard let outline else { return false }
            return (0..<outline.numberOfRows).contains { row in
                (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                    .textField?.stringValue == name
            }
        }
        let name = "smoke-favorite-\(UUID().uuidString.prefix(8))"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard
            (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true))
                != nil,
            let source = outline.dataSource, let heading = outline.item(atRow: 0)
        else { return check(false, "a folder and the sidebar to drop it on") }
        let pasteboard = NSPasteboard(name: .init("smoke-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([folder as NSURL])
        let drop = StandInDraggingInfo(pasteboard: pasteboard)
        let operation =
            source.outlineView?(
                outline, validateDrop: drop, proposedItem: heading, proposedChildIndex: 0) ?? []
        let accepted =
            source.outlineView?(outline, acceptDrop: drop, item: heading, childIndex: 0) ?? false
        check(
            !operation.isEmpty && accepted && lists(name, in: outline)
                && lists(name, in: otherOutline),
            "a folder dropped on Favorites shows in every window's sidebar")

        guard
            let row = (0..<outline.numberOfRows).first(where: { row in
                (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                    .textField?.stringValue == name
            }),
            let remove = outline.menu?.items.first(where: { $0.title == "Remove from Sidebar" }),
            let action = remove.action
        else { return check(false, "the new favorite and Remove from Sidebar") }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        check(NSApp.sendAction(action, to: remove.target, from: remove), "Remove from Sidebar runs")
        check(
            !lists(name, in: outline) && !lists(name, in: otherOutline),
            "and the favorite leaves every window's sidebar")
    }
}

/// What AppKit hands a drop destination, for a drop the smoke test makes itself.
@MainActor
// AppKit's protocol isn't isolated, but AppKit only uses it on the main actor.
private final class StandInDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.link, .copy, .move] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
