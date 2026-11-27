import Foundation

/// The app's open sessions, one per file (docs/plans/M3b.md, D-a), keyed by the file's
/// device and inode so a second path to the same file (a hard link, a different spelling)
/// finds the session already open. Sessions are held weakly: the tabs showing a session
/// keep it alive, and it leaves the registry with its last tab.
@MainActor
public final class SessionRegistry {
    private var entries: [FileIdentity.Key: Entry] = [:]
    private var observers: [Observer] = []

    private struct Entry {
        weak var session: EditorSession?
    }

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (EditorSession) -> Void
    }

    /// Where sessions keep their folders and clones; nil keeps none.
    public let sessionsRoot: URL?

    public init(sessionsRoot: URL? = nil) { self.sessionsRoot = sessionsRoot }

    /// The live session editing the file at `url`, if there is one.
    public func session(for url: URL) -> EditorSession? {
        guard let key = try? FileIdentity(url: url).key,
            let session = entries[key]?.session,
            !session.isClosed
        else { return nil }
        return session
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
        session.startWatching()
        register(session, key: session.identity.key)
        return (session, true)
    }

    /// Takes in a session made elsewhere (a recovered one), keyed by its file as it is
    /// now. A session whose file is gone, or whose file another live session already
    /// edits, isn't found by opening the file.
    public func adopt(_ session: EditorSession) {
        guard !session.isClosed, let key = try? FileIdentity(url: session.url).key else { return }
        if let existing = entries[key]?.session, !existing.isClosed { return }
        register(session, key: key)
    }

    private func register(_ session: EditorSession, key: FileIdentity.Key) {
        entries = entries.filter { $0.value.session.map { !$0.isClosed } ?? false }
        entries[key] = Entry(session: session)
        // A save replaces the file, giving it a new inode: follow the session there;
        // closing drops it from the registry immediately, before deallocation.
        session.observe(self) { [weak self, weak session] change in
            guard let self, let session else { return }
            switch change {
            case .saved:
                self.entries = self.entries.filter {
                    $0.value.session.map { $0 !== session } ?? false
                }
                if !session.isClosed {
                    self.entries[session.identity.key] = Entry(session: session)
                }
            case .closed:
                self.entries = self.entries.filter {
                    $0.value.session.map { $0 !== session } ?? false
                }
            case .edited, .saving, .fileChanged:
                break
            }
        }
        notifyObservers(session)
    }

    /// Calls `handler` whenever `open(_:scope:addDirectory:)` creates a new session or
    /// `adopt(_:)` registers one, for as long as `owner` lives.
    public func observe(_ owner: AnyObject, _ handler: @escaping @MainActor (EditorSession) -> Void)
    {
        observers.append(Observer(owner: owner, handler: handler))
    }

    private func notifyObservers(_ session: EditorSession) {
        observers.removeAll { $0.owner == nil }
        for observer in observers where observer.owner != nil { observer.handler(session) }
    }

    /// Live sessions, for tests and the quit workflow.
    public var sessions: [EditorSession] {
        entries.values.compactMap { entry in
            guard let session = entry.session, !session.isClosed else { return nil }
            return session
        }
    }
}
