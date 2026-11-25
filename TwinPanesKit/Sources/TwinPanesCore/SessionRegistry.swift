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

    /// Where sessions keep their folders and clones; nil keeps none.
    public let sessionsRoot: URL?

    public init(sessionsRoot: URL? = nil) { self.sessionsRoot = sessionsRoot }

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
        if let session = session(for: url) {
            if session.scope == nil, let scope { session.scope = scope }
            return (session, false)
        }
        let session = try EditorSession(
            url: url, scope: scope, addDirectory: addDirectory, sessionsRoot: sessionsRoot)
        register(session, key: session.identity.key)
        session.startWatching()
        return (session, true)
    }

    /// Takes in a session made elsewhere (a recovered one), keyed by its file as it is
    /// now. A session whose file is gone, or whose file another live session already
    /// edits, isn't found by opening the file.
    public func adopt(_ session: EditorSession) {
        guard let key = try? FileIdentity(url: session.url).key, entries[key]?.session == nil
        else { return }
        register(session, key: key)
    }

    private func register(_ session: EditorSession, key: FileIdentity.Key) {
        entries = entries.filter { $0.value.session != nil }
        entries[key] = Entry(session: session)
        // A save replaces the file, giving it a new inode: follow the session there.
        session.observe(self) { [weak self, weak session] change in
            guard change == .saved, let self, let session else { return }
            self.entries = self.entries.filter { $0.value.session.map { $0 !== session } ?? false }
            self.entries[session.identity.key] = Entry(session: session)
        }
    }

    /// Live sessions, for tests and the quit workflow.
    public var sessions: [EditorSession] { entries.values.compactMap(\.session) }
}
