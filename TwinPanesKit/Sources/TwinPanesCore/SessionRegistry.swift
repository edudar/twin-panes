import Foundation

/// The app's open sessions, one per file (docs/plans/M3b.md, D-a), keyed by the file's
/// device and inode so a second path to the same file (a hard link, a different spelling)
/// finds the session already open. Sessions are held weakly: the tabs showing a session
/// keep it alive, and it leaves the registry with its last tab.
@MainActor
public final class SessionRegistry {
    private var entries: [FileIdentity.Key: Entry] = [:]

    private struct Entry {
        weak var session: EditorSession?
    }

    public init() {}

    /// The live session editing the file at `url`, if there is one.
    public func session(for url: URL) -> EditorSession? {
        guard let key = try? FileIdentity(url: url).key else { return nil }
        return entries[key]?.session
    }

    /// The live session for `url`, or a new one, registered. `isNew` tells which.
    /// Throws `ByteSourceError` when the file can't be opened.
    public func open(
        _ url: URL, scope: SecurityScope? = nil, addDirectory: URL? = nil
    ) throws -> (session: EditorSession, isNew: Bool) {
        if let session = session(for: url) { return (session, false) }
        let session = try EditorSession(url: url, scope: scope, addDirectory: addDirectory)
        entries = entries.filter { $0.value.session != nil }
        entries[session.identity.key] = Entry(session: session)
        // A save replaces the file, giving it a new inode: follow the session there.
        session.observe(self) { [weak self, weak session] change in
            guard change == .saved, let self, let session else { return }
            self.entries = self.entries.filter { $0.value.session.map { $0 !== session } ?? false }
            self.entries[session.identity.key] = Entry(session: session)
        }
        return (session, true)
    }

    /// Live sessions, for tests and the quit workflow.
    public var sessions: [EditorSession] { entries.values.compactMap(\.session) }
}
