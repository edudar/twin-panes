import Darwin
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
        stored = [data] + without(url)
    }

    /// Where the entries that no longer resolve last were, newest first.
    public var lost: [URL] {
        stored.compactMap { data in
            Self.resolve(data) == nil
                ? Self.recordedPath(of: data).map(URL.init(fileURLWithPath:)) : nil
        }
    }

    /// Drops the entries for `url`'s path, lost or not.
    public func forget(_ url: URL) { stored = without(url) }

    private func without(_ url: URL) -> [Data] {
        stored.filter { Self.url(of: $0).map { !Self.pathsEqual($0, url) } ?? false }
    }

    /// The entries that still resolve, newest first.
    public var entries: [Entry] {
        stored.compactMap { data in Self.resolve(data).map { ($0.url, data, $0.stale) } }
    }

    /// Resolves each stored bookmark once and returns both live entries and lost URLs, newest first.
    public func snapshot() -> (entries: [Entry], lost: [URL]) {
        var entries: [Entry] = []
        var lost: [URL] = []
        for data in stored {
            if let resolved = Self.resolve(data) {
                entries.append((resolved.url, data, resolved.stale))
            } else if let path = Self.recordedPath(of: data) {
                lost.append(URL(fileURLWithPath: path))
            }
        }
        return (entries, lost)
    }

    /// Recreates the bookmark for `url` in place, keeping its position and pruning dead
    /// entries. Use when an entry resolved as stale; adds it at the top if not present.
    public func refresh(_ url: URL) throws {
        let data = try Self.bookmark(url)
        var list: [Data] = []
        var matchIndex: Int?
        for entryData in stored {
            guard let entryURL = Self.url(of: entryData) else { continue }
            if matchIndex == nil, Self.pathsEqual(entryURL, url) {
                matchIndex = list.count
            }
            list.append(entryData)
        }
        if let matchIndex {
            list[matchIndex] = data
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
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        return (url, stale)
    }

    private var stored: [Data] {
        get { defaults.array(forKey: key) as? [Data] ?? [] }
        set {
            defaults.set(
                limit.map { Array(newValue.prefix(max(0, $0))) } ?? newValue, forKey: key)
        }
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The URL an entry resolves to, or else the path recorded in it.
    private static func url(of data: Data) -> URL? {
        resolve(data)?.url ?? recordedPath(of: data).map { URL(fileURLWithPath: $0) }
    }

    /// The path recorded in bookmark data, without resolving it; nil for non-bookmarks.
    static func recordedPath(of data: Data) -> String? {
        (URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data)?.path)
            .map { canonicalPath(URL(fileURLWithPath: $0)) }
    }

    /// Resolves symlinks and on-disk casing via `realpath` on `url` or its deepest
    /// existing ancestor, falling back to `standardizedFileURL.path`.
    static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        var probe = standardized
        var trailing: [String] = []
        while true {
            if let resolvedPtr = realpath(probe.path, nil) {
                defer { free(resolvedPtr) }
                let resolved = String(
                    decoding: UnsafeBufferPointer(
                        start: UnsafeRawPointer(resolvedPtr).assumingMemoryBound(to: UInt8.self),
                        count: strlen(resolvedPtr)),
                    as: UTF8.self)
                if trailing.isEmpty { return resolved }
                let suffix = trailing.reversed().joined(separator: "/")
                return resolved == "/" ? "/\(suffix)" : "\(resolved)/\(suffix)"
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            trailing.append(probe.lastPathComponent)
            probe = parent
        }
        return standardized.path
    }

    static func isCaseSensitive(_ url: URL) -> Bool {
        resourceValue(url, key: .volumeSupportsCaseSensitiveNamesKey) {
            $0.volumeSupportsCaseSensitiveNames
        } ?? true
    }

    static func volumeURL(of url: URL) -> URL? {
        resourceValue(url, key: .volumeURLKey) { $0.volume }
    }

    private static func resourceValue<T>(
        _ url: URL, key: URLResourceKey, read: (URLResourceValues) -> T?
    ) -> T? {
        var probe = url.standardizedFileURL
        while true {
            if let values = try? probe.resourceValues(forKeys: [key]), let value = read(values) {
                return value
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
    }

    static func pathsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = canonicalPath(lhs)
        let b = canonicalPath(rhs)
        if !isCaseSensitive(lhs) || !isCaseSensitive(rhs) {
            return a.caseInsensitiveCompare(b) == .orderedSame
        }
        return a == b
    }
}
