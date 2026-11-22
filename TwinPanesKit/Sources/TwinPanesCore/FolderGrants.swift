import Foundation

/// Folders the user has granted the sandboxed app access to, kept as app-scoped
/// security-scoped bookmarks so access survives relaunch (PLAN.md §5). A grant covers
/// everything inside its folder.
public final class FolderGrants {
    private let store: BookmarkStore

    public init(defaults: UserDefaults = .standard, key: String = "FolderGrants.bookmarks") {
        store = BookmarkStore(defaults: defaults, key: key)
    }

    /// Records a folder the user just picked in an open panel (access is active then).
    public func add(_ folder: URL) throws { try store.add(folder) }

    /// The granted folders that still resolve.
    public var folders: [URL] { store.entries.map(\.url) }

    /// Starts access through the most specific grant that contains `url`, refreshing
    /// its bookmark if stale. Nil when no grant covers it.
    public func scope(covering url: URL) -> SecurityScope? {
        let target = url.standardizedFileURL.pathComponents
        var best: (url: URL, stale: Bool, depth: Int)?
        for entry in store.entries {
            let parts = entry.url.standardizedFileURL.pathComponents
            if target.starts(with: parts), parts.count > (best?.depth ?? -1) {
                best = (entry.url, entry.stale, parts.count)
            }
        }
        guard let best else { return nil }
        let scope = SecurityScope(url: best.url)
        if best.stale { try? store.refresh(best.url) }
        return scope
    }

    public func removeAll() { store.removeAll() }
}
