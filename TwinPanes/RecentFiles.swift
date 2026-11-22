import AppKit
import TwinPanesCore

/// File › Open Recent, backed by app-scoped security-scoped bookmarks so files stay
/// reachable from the sandbox after relaunch (PLAN.md §5). A bookmark that resolves
/// but reports itself stale is recreated on the spot.
@MainActor
final class RecentFiles: NSObject, NSMenuDelegate {
    static let limit = 10
    private let store: BookmarkStore

    init(defaults: UserDefaults = .standard) {
        store = BookmarkStore(defaults: defaults, key: "RecentFiles.bookmarks", limit: Self.limit)
    }

    /// Records `url` at the top of the list. Call while access to it is active.
    func note(_ url: URL) {
        guard (try? store.add(url)) != nil else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func clear() { store.removeAll() }

    /// The entries that still resolve, newest first.
    var entries: [(url: URL, data: Data)] { store.entries.map { ($0.url, $0.data) } }

    /// Resolves a bookmark from the menu, starts access, refreshes it if stale, and
    /// returns the URL with its scope token; nil if the file can't be reached any more.
    func open(_ data: Data) -> (URL, SecurityScope)? {
        guard let (url, stale) = BookmarkStore.resolve(data) else { return nil }
        let scope = SecurityScope(url: url)
        if stale { try? store.refresh(url) }
        return (url, scope)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in entries {
            let item = NSMenuItem(
                title: entry.url.lastPathComponent,
                action: #selector(AppActions.openRecentFile(_:)), keyEquivalent: "")
            item.representedObject = entry.data
            item.toolTip = entry.url.path
            item.image = NSWorkspace.shared.icon(forFile: entry.url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Clear Menu", action: #selector(AppActions.clearRecentFiles(_:)),
                keyEquivalent: ""))
    }
}
