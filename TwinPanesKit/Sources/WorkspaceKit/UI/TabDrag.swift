import AppKit

extension NSPasteboard.PasteboardType {
    /// A tab being dragged within the app: its item's ID (docs/plans/M5.md, D-b).
    static let workspaceTab = NSPasteboard.PasteboardType("io.github.edudar.twinpanes.tab")
}

extension ItemID {
    /// Reads the ID a dragged tab wrote; nil for anything else.
    init?(draggedTab item: NSPasteboardItem) {
        guard let text = item.string(forType: .workspaceTab), let uuid = UUID(uuidString: text)
        else { return nil }
        self.init(rawValue: uuid)
    }

    /// What a dragged tab puts on the pasteboard.
    var draggedTab: NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(rawValue.uuidString, forType: .workspaceTab)
        return item
    }
}

/// Where a tab dropped at `x` goes among tabs whose centres are `tabCentres`, left to
/// right: after every tab whose centre is left of `x`.
func tabInsertionIndex(at x: CGFloat, tabCentres: [CGFloat]) -> Int {
    tabCentres.filter { $0 < x }.count
}
