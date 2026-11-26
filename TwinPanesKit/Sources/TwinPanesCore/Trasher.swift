import Foundation

/// What moving items to the Trash did.
public struct TrashOutcome: Sendable {
    public var trashed: [TrashedItem] = []
    public var failures: [FileSystemError] = []
    public var wasCancelled = false
}

/// F8: moves items to their volume's Trash (docs/plans/M6.md, D-c). An item on a
/// volume without one fails (`ENOTSUP`); the rest go on.
public struct Trasher: Sendable {
    let fileSystem: any FileOperationSystem

    public init(fileSystem: any FileOperationSystem) { self.fileSystem = fileSystem }

    public func trash(
        _ items: [URL], control: OperationControl, progress: (OperationProgress) -> Void
    ) -> TrashOutcome {
        var outcome = TrashOutcome()
        var state = OperationProgress(itemsTotal: items.count)
        for item in items {
            guard control.checkpoint() else {
                outcome.wasCancelled = true
                break
            }
            state.currentItem = item.lastPathComponent
            do {
                let trashed = try fileSystem.trash(item)
                outcome.trashed.append(TrashedItem(original: item, trashed: trashed))
            } catch {
                outcome.failures.append(error)
            }
            state.itemsDone += 1
            progress(state)
        }
        return outcome
    }
}

/// What a permanent delete did.
public struct RemoveOutcome: Sendable {
    public var removed: [URL] = []
    /// True when at least one item (file or subfolder) was deleted, even if a parent
    /// folder stayed behind because another child failed.
    public var removedAny = false
    public var failures: [FileSystemError] = []
    public var wasCancelled = false
}

/// ⇧F8: deletes items for good, each tree deepest first (docs/plans/M6.md, D-c). An
/// item that can't be removed keeps the folders above it; the rest go on.
public struct TreeRemover: Sendable {
    let fileSystem: any FileOperationSystem

    public init(fileSystem: any FileOperationSystem) { self.fileSystem = fileSystem }

    public func remove(
        _ items: [URL], control: OperationControl, progress: (OperationProgress) -> Void
    ) -> RemoveOutcome {
        var outcome = RemoveOutcome()
        let planner = OperationPlanner(fileSystem: fileSystem)
        let walks = items.map { planner.walk($0, isCancelled: { control.isCancelled }) }
        // A walk cut short by a cancel would delete from a partial list: stop first.
        guard control.checkpoint() else {
            outcome.wasCancelled = true
            return outcome
        }
        var state = OperationProgress(itemsTotal: walks.reduce(0) { $0 + $1.items.count })
        removing: for (item, walk) in zip(items, walks) {
            outcome.failures += walk.unreadable
            // Paths below a failed item, as "path/": the folders above it stay.
            var kept: [String] = []
            for entry in walk.items.reversed() {
                guard control.checkpoint() else {
                    outcome.wasCancelled = true
                    break removing
                }
                state.currentItem = entry.relativePath
                if kept.contains(where: { $0.hasPrefix(entry.relativePath + "/") }) {
                    kept.append(entry.relativePath + "/")
                } else {
                    do {
                        try fileSystem.remove(entry.source)
                        outcome.removedAny = true
                    } catch {
                        outcome.failures.append(error)
                        kept.append(entry.relativePath + "/")
                    }
                }
                state.itemsDone += 1
                progress(state)
            }
            if kept.isEmpty && walk.unreadable.isEmpty { outcome.removed.append(item) }
        }
        return outcome
    }
}
