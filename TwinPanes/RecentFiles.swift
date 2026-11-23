import AppKit
import TwinPanesCore

/// File › Open Recent, backed by app-scoped security-scoped bookmarks so files stay
/// reachable from the sandbox after relaunch (PLAN.md §5). A bookmark that resolves
/// but reports itself stale is recreated on the spot; one that no longer resolves stays
/// in the menu as moved or renamed, and choosing it asks the user to find the file
/// (docs/plans/M4.md, D-g).
@MainActor
final class RecentFiles: NSObject, NSMenuDelegate {
    static let limit = 10
    private let store: BookmarkStore
    private let recordSystemRecents: Bool
    private let isolatedFolder: URL?
    private let isolatedSuite: String?

    init(
        defaults: UserDefaults = .standard,
        recordSystemRecents: Bool = true,
        isolatedFolder: URL? = nil,
        isolatedSuite: String? = nil
    ) {
        self.recordSystemRecents = recordSystemRecents
        self.isolatedFolder = isolatedFolder
        self.isolatedSuite = isolatedSuite
        store = BookmarkStore(defaults: defaults, key: "RecentFiles.bookmarks", limit: Self.limit)
    }

    /// Ephemeral store in a temporary folder that does not touch user preferences or
    /// system recents (for `--smoke-test` / `--bench`).
    static func isolated() -> RecentFiles {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-recents-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = dir.appendingPathComponent("defaults").path
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Unable to create isolated UserDefaults suite at \(suite)")
        }
        return RecentFiles(
            defaults: defaults,
            recordSystemRecents: false,
            isolatedFolder: dir,
            isolatedSuite: suite)
    }

    /// Removes the temporary preferences domain and folder created by `isolated()`.
    func cleanUp() {
        if let isolatedSuite { UserDefaults().removePersistentDomain(forName: isolatedSuite) }
        if let isolatedFolder { try? FileManager.default.removeItem(at: isolatedFolder) }
    }

    /// Records `url` at the top of the list. Call while access to it is active.
    func note(_ url: URL) {
        guard (try? store.add(url)) != nil else { return }
        if recordSystemRecents { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    func clear() { store.removeAll() }

    /// The entries that still resolve, newest first.
    var entries: [(url: URL, data: Data)] { store.entries.map { ($0.url, $0.data) } }

    /// Where files that no longer resolve last were, newest first.
    var lost: [URL] { store.lost }

    func forget(_ url: URL) { store.forget(url) }

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
        for url in lost {
            let item = NSMenuItem(
                title: "\(url.lastPathComponent) (moved or renamed)",
                action: #selector(AppActions.locateRecentFile(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
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
