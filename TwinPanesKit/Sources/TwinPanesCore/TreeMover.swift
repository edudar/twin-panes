import Foundation

/// An item now somewhere else: undo moves it back.
public struct MovedItem: Sendable, Equatable {
    public let from: URL
    public let to: URL
}

/// What a move did.
public struct MoveOutcome: Sendable {
    public var moved: [MovedItem] = []
    /// What Replace sent to the Trash.
    public var replaced: [TrashedItem] = []
    public var failures: [FileSystemError] = []
    public var wasCancelled = false
}

/// Moves items into a folder (docs/plans/M6.md, D-c), off the main actor. On one volume
/// each item is renamed, atomically. An item on another volume, or whose name is taken
/// (the copier settles the conflict), is copied; then each source item whose copy is
/// complete and the right size is removed, deepest first. Whatever was skipped, failed
/// or not reached when cancelled keeps its source, so nothing is lost.
public struct TreeMover: Sendable {
    let fileSystem: any FileOperationSystem

    public init(fileSystem: any FileOperationSystem) {
        self.fileSystem = fileSystem
    }

    /// Blocks until done; `resolve` and `progress` as for `TreeCopier.copy`.
    public func move(
        _ sources: [URL], into destination: URL, control: OperationControl,
        resolve: (Conflict) -> ConflictAnswer, progress: (OperationProgress) -> Void
    ) -> MoveOutcome {
        var outcome = MoveOutcome()
        var state = OperationProgress(itemsTotal: sources.count)
        var toCopy: [URL] = []
        for source in sources {
            guard control.checkpoint() else {
                outcome.wasCancelled = true
                return outcome
            }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            state.currentItem = source.lastPathComponent
            // Already there: nothing to move, and nothing for undo to move back.
            if BookmarkStore.pathsEqual(source.deletingLastPathComponent(), destination) {
                state.itemsDone += 1
                progress(state)
                continue
            }
            do {
                try fileSystem.rename(source, to: target)
                outcome.moved.append(MovedItem(from: source, to: target))
            } catch  where error.errno == EXDEV || error.errno == EEXIST {
                toCopy.append(source)
            } catch {
                outcome.failures.append(error)
            }
            state.itemsDone += 1
            progress(state)
        }
        guard !toCopy.isEmpty else { return outcome }
        let planner = OperationPlanner(fileSystem: fileSystem)
        let walks = toCopy.map { planner.walk($0, isCancelled: { control.isCancelled }) }
        let copy = TreeCopier(fileSystem: fileSystem).copy(
            walks, into: destination, control: control, resolve: resolve, progress: progress)
        outcome.replaced += copy.replaced
        outcome.failures += copy.failures
        outcome.wasCancelled = copy.wasCancelled
        outcome.failures += removeSources(of: walks, finished: copy.finished)
        for made in copy.created where (try? fileSystem.metadata(of: made.source)) == nil {
            outcome.moved.append(MovedItem(from: made.source, to: made.copy))
        }
        return outcome
    }

    /// Removes each source item whose copy finished, deepest first: a file once its copy
    /// is the right size, a folder once it's empty. A folder still holding what wasn't
    /// moved stays, and that isn't a failure.
    private func removeSources(
        of walks: [SourceWalk], finished: [String: URL]
    )
        -> [FileSystemError]
    {
        var failures: [FileSystemError] = []
        for item in walks.flatMap(\.items).reversed() {
            guard let copy = finished[item.relativePath] else { continue }
            if item.metadata.kind == .file,
                (try? fileSystem.metadata(of: copy).size) != item.metadata.size
            {
                failures.append(FileSystemError("verify the copy of", item.source.path, errno: EIO))
                continue
            }
            do {
                try fileSystem.remove(item.source)
            } catch  where item.metadata.kind == .folder && error.errno == ENOTEMPTY {
                // Skipped or failed items are still inside.
            } catch {
                failures.append(error)
            }
        }
        return failures
    }
}
