import Foundation

/// The names path completion offers, one folder's at a time (docs/plans/M5.md, D-e).
/// Each folder is read once, off the main actor, and kept while the path field is open,
/// so a 100k-entry folder never stalls typing. A folder that can't be read (no sandbox
/// grant, gone, not a folder) has no names, and nothing prompts for access.
@MainActor
public final class CompletionNames {
    public typealias Read = @Sendable (URL) -> [PathCompletion.Candidate]

    private let read: Read
    private let access: (URL) -> SecurityScope?
    private var cache: [String: [PathCompletion.Candidate]] = [:]
    private var latestRequest = 0

    /// `read` lists one folder off the main actor, while the scope `access` gives for it
    /// (on the main actor) is held.
    public init(read: @escaping Read, access: @escaping (URL) -> SecurityScope? = { _ in nil }) {
        self.read = read
        self.access = access
    }

    /// Reads folders the way the browser lists them, with access from `grants`.
    public convenience init(grants: FolderGrants) {
        self.init(read: Self.readFolder, access: { grants.scope(covering: $0) })
    }

    /// The names in `folder`, hidden ones included; packages count as files, as in the
    /// browser. Empty when the folder can't be read.
    nonisolated static func readFolder(_ folder: URL) -> [PathCompletion.Candidate] {
        // Completion offers nothing for a folder it can't read and never prompts
        // (PLAN.md §4.7); going to the folder reports why.
        guard let entries = try? DirectoryReader.entries(of: folder, includeHidden: true) else {
            return []
        }
        return entries.map { .init(name: $0.name, isFolder: $0.isDirectory && !$0.isPackage) }
    }

    /// The names already read for `folder`, or nil when they aren't yet.
    public func cached(in folder: URL) -> [PathCompletion.Candidate]? {
        cache[folder.standardizedFileURL.path]
    }

    /// The names in `folder`, read once. Returns nil when a request for another folder
    /// came while this one was being read: the caller's text has moved on.
    public func names(in folder: URL) async -> [PathCompletion.Candidate]? {
        latestRequest += 1
        let request = latestRequest
        if let names = cached(in: folder) { return names }
        let (read, scope) = (read, access(folder))
        let names = await Task.detached { withExtendedLifetime(scope) { read(folder) } }.value
        // Kept even when overtaken: the names are right, and typing may come back here.
        cache[folder.standardizedFileURL.path] = names
        return request == latestRequest ? names : nil
    }
}
