import Foundation

/// Folders the user has granted the sandboxed app access to, kept as app-scoped
/// security-scoped bookmarks so access survives relaunch (PLAN.md §5). A grant covers
/// everything inside its folder.
public final class FolderGrants {
    private let store: BookmarkStore
    private var cachedEntries: [BookmarkStore.Entry]?

    public init(defaults: UserDefaults = .standard, key: String = "FolderGrants.bookmarks") {
        store = BookmarkStore(defaults: defaults, key: key)
    }

    /// Records a folder the user just picked in an open panel (access is active then).
    public func add(_ folder: URL) throws {
        try store.add(folder)
        cachedEntries = nil
    }

    /// The granted folders that still resolve.
    public var folders: [URL] { resolvedEntries().map(\.url) }

    /// Starts access through the most specific grant that contains `url`, refreshing
    /// its bookmark if stale. Nil when no grant covers it.
    public func scope(covering url: URL) -> SecurityScope? {
        guard let best = best(covering: url) else { return nil }
        let scope = SecurityScope(url: best.url)
        if best.stale {
            try? store.refresh(best.url)
            cachedEntries = nil
        }
        return scope
    }

    /// The granted folder whose access `scope(covering:)` would start for `url`, without
    /// starting it: starting access is a call into the sandbox, slow on a busy system,
    /// so a tab keeps its token while it stays under the same grant.
    public func grant(covering url: URL) -> URL? { best(covering: url)?.url }

    private func best(covering url: URL) -> (url: URL, stale: Bool)? {
        let target = url.standardizedFileURL.pathComponents
        var best: (url: URL, stale: Bool, depth: Int)?
        for entry in resolvedEntries() {
            let parts = entry.url.standardizedFileURL.pathComponents
            if target.starts(with: parts), parts.count > (best?.depth ?? -1) {
                best = (entry.url, entry.stale, parts.count)
            }
        }
        return best.map { ($0.url, $0.stale) }
    }

    /// The most specific granted folder containing `url` whose bookmark no longer
    /// resolves (renamed, moved or unmounted), as it last was: the place to ask for
    /// access again (D-g).
    public func lostGrant(covering url: URL) -> URL? {
        let target = url.standardizedFileURL.pathComponents
        return store.lost
            .filter { target.starts(with: $0.standardizedFileURL.pathComponents) }
            .max { $0.pathComponents.count < $1.pathComponents.count }
    }

    public func removeAll() {
        store.removeAll()
        cachedEntries = nil
    }

    private func resolvedEntries() -> [BookmarkStore.Entry] {
        if let cachedEntries { return cachedEntries }
        let entries = store.entries
        cachedEntries = entries
        return entries
    }
}
