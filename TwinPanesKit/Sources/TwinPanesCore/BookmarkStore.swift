import Foundation

/// A newest-first list of app-scoped security-scoped bookmarks kept in `UserDefaults`
/// under one key (PLAN.md §5). Shared by the folder grants and the Open Recent list.
/// One entry per standardized path; an optional `limit` caps the list. A bookmark that
/// stops resolving (moved, renamed, unmounted) is kept and reported in `lost` with the
/// path it last had, so the user can be asked to grant it again (docs/plans/M4.md,
/// D-g); only data that isn't a bookmark at all is pruned.
public final class BookmarkStore {
    public typealias Entry = (url: URL, data: Data, stale: Bool)

    private let defaults: UserDefaults
    private let key: String
    public let limit: Int?

    public init(defaults: UserDefaults = .standard, key: String, limit: Int? = nil) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
    }

    /// Records `url` at the top, replacing any entry for the same path (a lost one too),
    /// pruning data that isn't a bookmark, and trimming to `limit`. Call while access to it is active.
    public func add(_ url: URL) throws {
        let data = try Self.bookmark(url)
        let path = url.standardizedFileURL.path
        stored = [data] + stored.filter { Self.path(of: $0).map { $0 != path } ?? false }
    }

    /// Where the entries that no longer resolve last were, newest first.
    public var lost: [URL] {
        stored.compactMap { data in
            Self.resolve(data) == nil
                ? Self.recordedPath(of: data).map(URL.init(fileURLWithPath:)) : nil
        }
    }

    /// Drops the entries for `url`'s path, lost or not.
    public func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        stored = stored.filter { Self.path(of: $0).map { $0 != path } ?? false }
    }

    /// The entries that still resolve, newest first.
    public var entries: [Entry] {
        stored.compactMap { data in Self.resolve(data).map { ($0.url, data, $0.stale) } }
    }

    /// Recreates the bookmark for `url` in place, keeping its position and pruning dead
    /// entries. Use when an entry resolved as stale; adds it at the top if not present.
    public func refresh(_ url: URL) throws {
        let data = try Self.bookmark(url)
        let path = url.standardizedFileURL.path
        var list = stored.filter { Self.path(of: $0) != nil }
        if let index = list.firstIndex(where: { Self.path(of: $0) == path }) {
            list[index] = data
            stored = list
        } else {
            stored = [data] + list
        }
    }

    public func removeAll() { defaults.removeObject(forKey: key) }

    /// Resolves a bookmark made by this store; nil if it no longer resolves.
    public static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }

    private var stored: [Data] {
        get { defaults.array(forKey: key) as? [Data] ?? [] }
        set { defaults.set(limit.map { Array(newValue.prefix($0)) } ?? newValue, forKey: key) }
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The path an entry resolves to, or else the one recorded in it.
    private static func path(of data: Data) -> String? {
        resolve(data)?.url.standardizedFileURL.path ?? recordedPath(of: data)
    }

    /// The path recorded in bookmark data, without resolving it; nil for non-bookmarks.
    static func recordedPath(of data: Data) -> String? {
        (URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}
