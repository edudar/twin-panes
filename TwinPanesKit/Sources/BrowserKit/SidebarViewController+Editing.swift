import AppKit

/// Editing the favorites in the sidebar (docs/plans/M5.md, D-d, step 17): folders are
/// dropped in, favorites are dragged to reorder, and the context menu removes one.
extension SidebarViewController {
    /// Where a drop the outline view proposes lands among the favorites, or nil when it
    /// can't land there (on Locations or one of its volumes). A drop on a favorite goes
    /// before it.
    func dropIndex(proposedItem: Any?, childIndex: Int) -> Int? {
        guard let node = proposedItem as? SidebarNode else { return nil }
        if node === favoritesSection { return max(0, childIndex) }
        return favoritesSection.children.firstIndex { $0 === node }
    }

    /// Adds the folders among `urls` at `index`, an index into the favorites as shown
    /// during the drag. A folder that's already a favorite moves. Returns false when
    /// none of them is a folder.
    func acceptDrop(of urls: [URL], at index: Int) -> Bool {
        let folders = urls.filter(Self.isFolder)
        guard !folders.isEmpty else { return false }
        var insertion = index
        for folder in folders {
            let current = favorites.folders.firstIndex {
                $0.path == folder.standardizedFileURL.path
            }
            // Adding a favorite that's there takes it out first, so one moving down
            // lands a place earlier than the index the list showed.
            if let current, current < insertion { insertion -= 1 }
            favorites.add(folder, at: insertion)
            insertion += 1
        }
        reloadFavorites()
        return true
    }

    /// A folder the user can browse into: packages count as files, as in the browser.
    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// Removes the favorite on `row`; rows that aren't favorites are left alone.
    func removeFavorite(atRow row: Int) {
        guard let node = outlineView.item(atRow: row) as? SidebarNode,
            favoritesSection.children.contains(where: { $0 === node }), let folder = node.folder
        else { return }
        favorites.remove(folder)
        reloadFavorites()
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let remove = NSMenuItem(
            title: "Remove from Sidebar", action: #selector(removeClickedFavorite(_:)),
            keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc func removeClickedFavorite(_ sender: Any?) {
        removeFavorite(atRow: outlineView.clickedRow)
    }

    var isClickedRowAFavorite: Bool {
        let node = outlineView.item(atRow: outlineView.clickedRow) as? SidebarNode
        return favoritesSection.children.contains { $0 === node }
    }

    // MARK: Dragging

    public func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        guard let node = item as? SidebarNode,
            favoritesSection.children.contains(where: { $0 === node })
        else { return nil }
        return node.folder as NSURL?
    }

    public func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let target = dropIndex(proposedItem: item, childIndex: index) else { return [] }
        outlineView.setDropItem(favoritesSection, dropChildIndex: target)
        return info.draggingSource as? NSOutlineView === outlineView ? .move : .link
    }

    public func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?,
        childIndex index: Int
    ) -> Bool {
        let urls =
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            ?? []
        guard let target = dropIndex(proposedItem: item, childIndex: index) else { return false }
        return acceptDrop(of: urls, at: target)
    }
}
