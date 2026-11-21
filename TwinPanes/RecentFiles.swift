import AppKit
import TwinPanesCore

/// File › Open Recent, backed by app-scoped security-scoped bookmarks so files stay
/// reachable from the sandbox after relaunch (PLAN.md §5). A bookmark that resolves
/// but reports itself stale is recreated on the spot.
@MainActor
final class RecentFiles: NSObject, NSMenuDelegate {
    static let limit = 10
    private static let defaultsKey = "RecentFiles.bookmarks"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var bookmarks: [Data] {
        get { defaults.array(forKey: Self.defaultsKey) as? [Data] ?? [] }
        set { defaults.set(Array(newValue.prefix(Self.limit)), forKey: Self.defaultsKey) }
    }

    /// Records `url` at the top of the list. Call while access to it is active.
    func note(_ url: URL) {
        guard
            let data = try? url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                relativeTo: nil)
        else { return }
        let path = url.standardizedFileURL.path
        bookmarks = [data] + bookmarks.filter { Self.resolve($0)?.url.path != path }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func clear() { bookmarks = [] }

    /// The entries that still resolve, newest first.
    var entries: [(url: URL, data: Data)] {
        bookmarks.compactMap { data in Self.resolve(data).map { ($0.url, data) } }
    }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }

    /// Resolves a bookmark from the menu, starts access, refreshes it if stale, and
    /// returns the URL with its scope token; nil if the file can't be reached any more.
    func open(_ data: Data) -> (URL, SecurityScope)? {
        guard let (url, stale) = Self.resolve(data) else { return nil }
        let scope = SecurityScope(url: url)
        if stale { note(url) }
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
