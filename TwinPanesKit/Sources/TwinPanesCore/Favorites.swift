import Foundation

/// The sidebar's favorite folders, in order (docs/plans/M5.md, D-d). Kept as paths in
/// user defaults, not bookmarks: access comes from the saved folder grants (D42).
/// Until someone edits it, the list is the defaults; after that it's what they left,
/// even empty.
public final class Favorites {
    static let key = "Sidebar.favorites"

    private let defaults: UserDefaults
    private let home: URL

    /// `home` is the real home folder, not the sandbox container's.
    public init(defaults: UserDefaults, home: URL) {
        self.defaults = defaults
        self.home = home.standardizedFileURL
    }

    public var standard: [URL] {
        [home]
            + ["Desktop", "Documents", "Downloads"].map {
                home.appendingPathComponent($0, isDirectory: true)
            } + [URL(fileURLWithPath: "/Applications", isDirectory: true)]
    }

    public var folders: [URL] {
        guard let paths = defaults.stringArray(forKey: Self.key) else { return standard }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private func save(_ folders: [URL]) {
        defaults.set(folders.map(\.path), forKey: Self.key)
    }

    /// Adds `folder` at `index` (default: the end). A folder already there moves instead,
    /// so the list never holds one twice.
    public func add(_ folder: URL, at index: Int? = nil) {
        let folder = folder.standardizedFileURL
        var list = folders.filter { !BookmarkStore.pathsEqual($0, folder) }
        list.insert(folder, at: min(max(index ?? list.count, 0), list.count))
        save(list)
    }

    public func remove(_ folder: URL) {
        let list = folders
        let remaining = list.filter { !BookmarkStore.pathsEqual($0, folder) }
        guard remaining.count != list.count else { return }
        save(remaining)
    }
}
