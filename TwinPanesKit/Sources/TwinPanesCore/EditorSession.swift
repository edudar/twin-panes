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
    }

    public let id = UUID()
    public let url: URL
    /// Keeps sandbox access to `url` for as long as the session lives (PLAN.md §5).
    public let scope: SecurityScope?
    public let buffer: EditBuffer
    /// The file as last opened or saved.
    public private(set) var identity: FileIdentity
    public let access: AccessMode
    /// The version that is on disk.
    public private(set) var savedTree: PieceTree
    public private(set) var undoStack = UndoStack()
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (Change) -> Void
    }

    /// Opens `url`. Throws `ByteSourceError` for anything but a readable regular file.
    public init(url: URL, scope: SecurityScope? = nil, addDirectory: URL? = nil) throws {
        self.url = url
        self.scope = scope
        let source = try ByteSource(url: url)
        buffer = try EditBuffer(original: source, addDirectory: addDirectory)
        identity = source.identity
        access = AccessMode.of(url)
        savedTree = buffer.tree
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
        let before = UndoStack.State(tree: buffer.tree, selection: selectionBefore)
        try buffer.overwrite(at: offset, with: bytes)
        let after = UndoStack.State(tree: buffer.tree, selection: selectionAfter)
        undoStack.record(before: before, after: after, coalescing: coalescing)
        notify(.edited)
    }

    /// Goes back one step; returns the version and selection to show, or nil.
    public func undo() -> UndoStack.State? { restore(undoStack.undo()) }

    /// Goes forward one step; returns the version and selection to show, or nil.
    public func redo() -> UndoStack.State? { restore(undoStack.redo()) }

    /// Goes back to the version on disk and forgets the undo history (Revert to Saved,
    /// and the close prompt's Discard).
    public func revert() {
        buffer.restore(savedTree)
        undoStack = UndoStack()
        notify(.edited)
    }

    /// Calls `handler` after every change for as long as `owner` lives.
    public func observe(_ owner: AnyObject, _ handler: @escaping @MainActor (Change) -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    private func restore(_ state: UndoStack.State?) -> UndoStack.State? {
        guard let state else { return nil }
        buffer.restore(state.tree)
        notify(.edited)
        return state
    }

    private func notify(_ change: Change) {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler(change) }
    }
}
