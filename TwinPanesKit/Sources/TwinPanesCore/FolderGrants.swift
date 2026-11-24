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
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        for candidate in coveringEntries(for: url) {
            let scope = SecurityScope(url: candidate.url)
            if scope.isActive || !isSandboxed {
                if scope.isActive, candidate.stale {
                    try? store.refresh(candidate.url)
                    cachedEntries = nil
                }
                return scope
            }
            cachedEntries = nil
        }
        return nil
    }

    /// The granted folder whose access `scope(covering:)` would start for `url`, without
    /// starting it: starting access is a call into the sandbox, slow on a busy system,
    /// so a tab keeps its token while it stays under the same grant.
    public func grant(covering url: URL) -> URL? { best(covering: url)?.url }

    private func best(covering url: URL) -> (url: URL, stale: Bool)? {
        coveringEntries(for: url).first.map { ($0.url, $0.stale) }
    }

    private func coveringEntries(for url: URL) -> [(url: URL, stale: Bool, depth: Int)] {
        let target = URL(fileURLWithPath: BookmarkStore.canonicalPath(url)).pathComponents
        let caseSensitive = BookmarkStore.isCaseSensitive(url)
        let targetVolume = BookmarkStore.volumeURL(of: url)
        return resolvedEntries().compactMap { entry in
            if let targetVolume,
                let entryVolume = BookmarkStore.volumeURL(of: entry.url),
                targetVolume != entryVolume
            {
                return nil
            }
            let parts = URL(fileURLWithPath: BookmarkStore.canonicalPath(entry.url)).pathComponents
            guard
                Self.startsWith(
                    target, prefix: parts,
                    caseSensitive: caseSensitive && BookmarkStore.isCaseSensitive(entry.url))
            else { return nil }
            return (entry.url, entry.stale, parts.count)
        }
        .sorted { $0.depth > $1.depth }
    }

    /// The most specific granted folder containing `url` whose bookmark no longer
    /// resolves (renamed, moved or unmounted), as it last was: the place to ask for
    /// access again (D-g).
    public func lostGrant(covering url: URL) -> URL? {
        let target = URL(fileURLWithPath: BookmarkStore.canonicalPath(url)).pathComponents
        let caseSensitive = BookmarkStore.isCaseSensitive(url)
        return store.lost
            .compactMap { lost -> (url: URL, depth: Int)? in
                let parts = URL(fileURLWithPath: BookmarkStore.canonicalPath(lost)).pathComponents
                guard
                    Self.startsWith(
                        target, prefix: parts,
                        caseSensitive: caseSensitive && BookmarkStore.isCaseSensitive(lost))
                else { return nil }
                return (lost, parts.count)
            }
            .max { $0.depth < $1.depth }?
            .url
    }

    public func removeAll() {
        store.removeAll()
        cachedEntries = nil
    }

    /// Drops the grant for `folder` and clears cached entries.
    public func forget(_ folder: URL) {
        store.forget(folder)
        cachedEntries = nil
    }

    /// Clears cached entries so the next lookup re-resolves from the store.
    public func invalidate() {
        cachedEntries = nil
    }

    private static func startsWith(
        _ target: [String], prefix: [String], caseSensitive: Bool
    ) -> Bool {
        guard target.count >= prefix.count else { return false }
        for (lhs, rhs) in zip(target, prefix) {
            if caseSensitive {
                if lhs != rhs { return false }
            } else {
                if lhs.caseInsensitiveCompare(rhs) != .orderedSame { return false }
            }
        }
        return true
    }

    private func resolvedEntries() -> [BookmarkStore.Entry] {
        if let cachedEntries { return cachedEntries }
        let entries = store.entries
        cachedEntries = entries
        return entries
    }
}
