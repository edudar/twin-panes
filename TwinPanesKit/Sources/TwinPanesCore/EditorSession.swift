import Foundation

public enum EditorSessionError: Error, Equatable, CustomStringConvertible {
    /// The session can't change its file (docs/plans/M3b.md, D-b).
    case readOnly(AccessMode.ReadOnlyReason)

    public var description: String {
        switch self {
        case .readOnly(let reason): return "The file is read-only: \(reason)"
        }
    }
}

/// One open file and its edit history (docs/plans/M3b.md, D-a): the `EditBuffer`, the
/// undo stack, the version on disk, and the file's identity and access. Tabs that show
/// it keep only presentation (selection, find, view options) and follow it through
/// `observe(_:_:)`.
///
/// Main-actor only, like its `EditBuffer`; other threads read `snapshot`s.
@MainActor
public final class EditorSession {
    /// What changed, for observers.
    public enum Change: Equatable, Sendable {
        /// The bytes changed: an edit, undo, redo or revert.
        case edited
        /// A save finished: the saved version, and maybe the file's identity, changed.
        case saved
        /// `isSaving` changed.
        case saving
    }

    public let id = UUID()
    /// The file; Save As moves the session to another one.
    public internal(set) var url: URL
    /// Keeps sandbox access to `url` for as long as the session lives (PLAN.md §5).
    public internal(set) var scope: SecurityScope?
    /// Scopes of files the session edited before a Save As; kept, since the original
    /// pieces still read the file it opened.
    var earlierScopes: [SecurityScope] = []
    public internal(set) var buffer: EditBuffer
    /// Where session folders go (`SessionFolder.defaultRoot` in the app); nil keeps no
    /// folder and no clone.
    public let sessionsRoot: URL?
    /// Made on the first edit: the clone the original pieces read, the add buffer, and
    /// the manifest (docs/plans/M3c.md, D-a).
    public internal(set) var folder: SessionFolder?
    /// The clone failed (another volume): the original pieces read the live file.
    public internal(set) var isNarrowed = false
    /// Came back from a crash (its tab says so while the edits are unsaved).
    public private(set) var wasRecovered = false
    /// The operation journal in `folder`; nil before the first edit, or after it failed
    /// to write (edits go on, unprotected).
    var journal: SessionJournal?
    /// The file as last opened or saved.
    public internal(set) var identity: FileIdentity
    public internal(set) var access: AccessMode
    /// The version that is on disk.
    public internal(set) var savedTree: PieceTree
    public internal(set) var undoStack = UndoStack()
    /// Writes the file (see `save()`); a test can give it another `FileSystem`.
    public let saver: Saver
    /// The last save started or queued, and how many are running or queued (at most 2).
    var saveTail: Task<Void, Error>?
    var savesPending = 0
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (Change) -> Void
    }

    /// Opens `url`. Throws `ByteSourceError` for anything but a readable regular file.
    public init(
        url: URL, scope: SecurityScope? = nil, addDirectory: URL? = nil, saver: Saver = Saver(),
        sessionsRoot: URL? = nil
    ) throws {
        self.url = url
        self.scope = scope
        self.saver = saver
        self.sessionsRoot = sessionsRoot
        let source = try ByteSource(url: url)
        buffer =
            try addDirectory.map { try EditBuffer(original: source, addDirectory: $0) }
            ?? EditBuffer(original: source)
        identity = source.identity
        access = AccessMode.of(url)
        savedTree = buffer.tree
    }

    /// Reopens a session that crashed, from its folder (docs/plans/M3c.md, D-f). Its file
    /// is the manifest's (by bookmark, else by path, even if it's gone); the clone, the
    /// add buffer and the journal give back its current and saved versions. It comes
    /// back dirty, with no undo history, and goes on journaling into the same folder.
    public init(recovering folder: SessionFolder, saver: Saver = Saver()) throws {
        // A save in place that didn't commit is undone first (strategy B).
        _ = try? SaveJournal.rollBackIfNeeded(
            folder.file(SaveJournal.fileName), fileSystem: saver.fileSystem)
        let manifest = try folder.manifest()
        var stale = false
        let resolved = manifest.bookmark.flatMap {
            try? URL(
                resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil,
                bookmarkDataIsStale: &stale)
        }
        url = resolved ?? URL(fileURLWithPath: manifest.path)
        scope = resolved.map(SecurityScope.init)
        self.saver = saver
        sessionsRoot = folder.url.deletingLastPathComponent()
        let clone = try ByteSource(url: folder.file(Self.cloneName))
        guard let addFile = Self.addBufferFile(in: folder) else {
            throw ByteSourceError.openFailed(path: folder.url.path, errno: ENOENT)
        }
        let add = try AddBuffer(reopening: addFile)
        let data = (try? Data(contentsOf: folder.file(SessionJournal.fileName))) ?? Data()
        let decoded = JournalFormat.decode(data)
        let (tree, saved) = JournalFormat.replay(decoded.records, originalLength: clone.length)
        buffer = EditBuffer(original: clone, add: add, tree: tree)
        identity = manifest.identity
        access = AccessMode.of(url)
        savedTree = saved
        self.folder = folder
        wasRecovered = true
        journal = try SessionJournal(
            reopening: folder, records: decoded.records, validLength: decoded.validLength,
            add: add, fileSystem: saver.fileSystem)
    }

    /// The add buffer's file in a session folder (in the subfolder `AddBuffer` makes).
    static func addBufferFile(in folder: SessionFolder) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []
        return entries.lazy.map {
            folder.url.appendingPathComponent($0).appendingPathComponent("add-buffer")
        }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    deinit {
        if let folder {
            try? folder.markClosed()
            folder.delete()
        }
    }

    public var length: UInt64 { buffer.length }
    /// The current version, for reading on any thread.
    public var snapshot: EditSnapshot { buffer.snapshot() }
    /// The current version differs from the one on disk.
    public var isDirty: Bool { !buffer.tree.isSameVersion(as: savedTree) }
    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    /// Overwrites `bytes` at `offset` and records an undo step from `selectionBefore` to
    /// `selectionAfter`; with `coalescing`, it extends the last step instead (a typing
    /// burst). Throws `EditorSessionError.readOnly` or `ByteSourceError.truncated`
    /// without changing anything.
    public func overwrite(
        _ bytes: Data, at offset: UInt64, selectionBefore: Range<UInt64>,
        selectionAfter: Range<UInt64>, coalescing: Bool = false
    ) throws {
        if case .readOnly(let reason) = access { throw EditorSessionError.readOnly(reason) }
        if folder == nil { try protectBeforeFirstEdit() }
        let before = UndoStack.State(tree: buffer.tree, selection: selectionBefore)
        try buffer.overwrite(at: offset, with: bytes)
        let after = UndoStack.State(tree: buffer.tree, selection: selectionAfter)
        undoStack.record(before: before, after: after, coalescing: coalescing)
        journalChange(from: before.tree)
        notify(.edited)
    }

    /// Goes back one step; returns the version and selection to show, or nil.
    public func undo() -> UndoStack.State? { restore(undoStack.undo()) }

    /// Goes forward one step; returns the version and selection to show, or nil.
    public func redo() -> UndoStack.State? { restore(undoStack.redo()) }

    /// Goes back to the version on disk and forgets the undo history (Revert to Saved,
    /// and the close prompt's Discard).
    public func revert() {
        let old = buffer.tree
        buffer.restore(savedTree)
        journalChange(from: old)
        undoStack = UndoStack()
        notify(.edited)
    }

    /// Calls `handler` after every change for as long as `owner` lives.
    public func observe(_ owner: AnyObject, _ handler: @escaping @MainActor (Change) -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    private func restore(_ state: UndoStack.State?) -> UndoStack.State? {
        guard let state else { return nil }
        let old = buffer.tree
        buffer.restore(state.tree)
        journalChange(from: old)
        notify(.edited)
        return state
    }

    func notify(_ change: Change) {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler(change) }
    }
}
