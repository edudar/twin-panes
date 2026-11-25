import Foundation

/// A finished file operation as undo sees it (docs/plans/M6.md, D-g): what it did, item
/// by item, so it can be undone, and the request that does it again.
public struct FileChange: Sendable {
    public let request: OperationRequest
    public let result: OperationResult

    /// Nil for what changed nothing (a refused name, an operation that did nothing).
    public init?(request: OperationRequest, result: OperationResult) {
        let changedSomething =
            switch result {
            case .copied(let outcome): !outcome.created.isEmpty || !outcome.replaced.isEmpty
            case .moved(let outcome): !outcome.moved.isEmpty || !outcome.replaced.isEmpty
            case .trashed(let outcome): !outcome.trashed.isEmpty
            // Even a delete that failed partway may have removed something: always a
            // barrier.
            case .removed: true
            case .renamed(let outcome): (try? outcome.get()) != nil
            case .madeFolder(let outcome): (try? outcome.get()) != nil
            }
        guard changedSomething else { return nil }
        self.request = request
        self.result = result
    }

    /// For the Edit menu: "Copy of 3 Items", "Rename".
    public var title: String {
        switch request {
        case .copy(let items, _): "Copy of \(Self.describe(items))"
        case .move(let items, _): "Move of \(Self.describe(items))"
        case .putBack(let items): "Move of \(Self.describe(items.map(\.to)))"
        case .trash: "Move to Trash"
        case .delete: "Delete"
        case .rename: "Rename"
        case .makeFolder: "New Folder"
        }
    }

    /// The requests that undo it, to run in order; nil for a permanent delete.
    public var undoRequests: [OperationRequest]? {
        switch result {
        case .copied(let outcome):
            Self.nonEmpty([.trash(outcome.created.map(\.copy))])
                + Self.puttingBack(outcome.replaced)
        case .moved(let outcome):
            Self.nonEmpty([.putBack(outcome.moved)]) + Self.puttingBack(outcome.replaced)
        case .trashed(let outcome): Self.puttingBack(outcome.trashed)
        case .removed: nil
        case .renamed(let outcome): (try? outcome.get()).map { [.putBack([$0])] } ?? []
        case .madeFolder(let outcome): (try? outcome.get()).map { [.trash([$0])] } ?? []
        }
    }

    /// "“a.txt”" for one item, "3 Items" for more.
    private static func describe(_ items: [URL]) -> String {
        items.count == 1 ? "“\(items[0].lastPathComponent)”" : "\(items.count) Items"
    }

    private static func puttingBack(_ trashed: [TrashedItem]) -> [OperationRequest] {
        nonEmpty([.putBack(trashed.map { MovedItem(from: $0.original, to: $0.trashed) })])
    }

    /// `requests` without any that would act on nothing.
    private static func nonEmpty(_ requests: [OperationRequest]) -> [OperationRequest] {
        requests.filter {
            switch $0 {
            case .trash(let items): !items.isEmpty
            case .putBack(let items): !items.isEmpty
            default: true
            }
        }
    }
}

/// One app-wide history of file operations, as Finder keeps (docs/plans/M6.md, D-g).
/// A permanent delete is a barrier: undo stops there. Not kept across launches.
@MainActor
public final class FileOperationHistory {
    private var undoable: [FileChange] = []
    private var redoable: [FileChange] = []

    public init() {}

    /// Records a finished operation; anything to redo is forgotten.
    public func record(_ change: FileChange) {
        undoable.append(change)
        redoable = []
    }

    /// What ⌘Z would undo, if anything can be undone.
    public var nextUndo: FileChange? {
        undoable.last.flatMap { $0.undoRequests == nil ? nil : $0 }
    }
    public var nextRedo: FileChange? { redoable.last }
    /// True when undo is stopped by a permanent delete.
    public var isBlockedByDelete: Bool { undoable.last.map { $0.undoRequests == nil } ?? false }

    /// Takes the change to undo; once its undo requests have run, `didUndo` files it
    /// for redo.
    public func takeUndo() -> FileChange? {
        guard nextUndo != nil else { return nil }
        return undoable.removeLast()
    }

    public func didUndo(_ change: FileChange) { redoable.append(change) }
    /// Takes the change to redo; its request runs again and `didRedo` records the new
    /// change, keeping what's left to redo.
    public func takeRedo() -> FileChange? { redoable.popLast() }
    public func didRedo(_ change: FileChange) { undoable.append(change) }
}
