import Foundation

/// Folders the user has granted the sandboxed app access to, kept as app-scoped
/// security-scoped bookmarks so access survives relaunch (PLAN.md §5). A grant covers
/// everything inside its folder.
public final class FolderGrants {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "FolderGrants.bookmarks") {
        self.defaults = defaults
        self.key = key
    }

    private var bookmarks: [Data] {
        get { defaults.array(forKey: key) as? [Data] ?? [] }
        set { defaults.set(newValue, forKey: key) }
    }

    /// Records a folder the user just picked in an open panel (access is active then).
    public func add(_ folder: URL) throws {
        let data = try folder.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let path = folder.standardizedFileURL.path
        bookmarks = [data] + bookmarks.filter { Self.resolve($0)?.url.path != path }
    }

    /// The granted folders that still resolve.
    public var folders: [URL] { bookmarks.compactMap { Self.resolve($0)?.url } }

    /// Starts access through the most specific grant that contains `url`, refreshing
    /// its bookmark if stale. Nil when no grant covers it.
    public func scope(covering url: URL) -> SecurityScope? {
        let target = url.standardizedFileURL.pathComponents
        var best: (url: URL, stale: Bool, depth: Int)?
        for data in bookmarks {
            guard let (folder, stale) = Self.resolve(data) else { continue }
            let parts = folder.standardizedFileURL.pathComponents
            if target.starts(with: parts), parts.count > (best?.depth ?? -1) {
                best = (folder, stale, parts.count)
            }
        }
        guard let best else { return nil }
        let scope = SecurityScope(url: best.url)
        if best.stale { try? add(best.url) }
        return scope
    }

    public func removeAll() { bookmarks = [] }

    private static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }
}
