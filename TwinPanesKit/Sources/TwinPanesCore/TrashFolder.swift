import Foundation

/// The user's Trash, `~/.Trash`. macOS guards it beyond the sandbox: only an app with Full
/// Disk Access may list it, and the user can grant or revoke that while the app runs.
public struct TrashFolder: Sendable {
    public let url: URL

    /// `home` is the real home folder, not the sandbox container's.
    public init(home: URL) {
        url = home.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Whether this process may list the Trash now. Blocking I/O: call it off the main
    /// actor.
    public func isListable() -> Bool {
        guard let directory = opendir(url.path) else { return false }
        closedir(directory)
        return true
    }
}
