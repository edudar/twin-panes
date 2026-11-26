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
                state.itemsDone += 1
                progress(state)
            } catch  where error.errno == EXDEV || error.errno == EEXIST {
                toCopy.append(source)
            } catch {
                outcome.failures.append(error)
                state.itemsDone += 1
                progress(state)
            }
        }
        guard !toCopy.isEmpty else { return outcome }
        let planner = OperationPlanner(fileSystem: fileSystem)
        let walks = toCopy.map { planner.walk($0, isCancelled: { control.isCancelled }) }
        let baseDone = state.itemsDone
        let copy = TreeCopier(fileSystem: fileSystem).copy(
            walks, into: destination, control: control, resolve: resolve
        ) { report in
            var combined = report
            combined.itemsDone += baseDone
            combined.itemsTotal += baseDone
            progress(combined)
        }
        outcome.replaced += copy.replaced
        outcome.failures += copy.failures
        outcome.wasCancelled = copy.wasCancelled
        let removal = removeSources(of: walks, finished: copy.finished)
        outcome.failures += removal.failures
        outcome.moved += Self.movedItems(from: walks, copy: copy, removed: removal.removed)
        return outcome
    }

    /// Top-most removed items that were created (not merged into an existing folder) at
    /// the destination, so `PutBack` restores only what this move actually moved.
    private static func movedItems(
        from walks: [SourceWalk], copy: CopyOutcome, removed: Set<String>
    ) -> [MovedItem] {
        var moved: [MovedItem] = []
        var covered: Set<String> = []
        for item in walks.flatMap(\.items) {
            let parent = (item.relativePath as NSString).deletingLastPathComponent
            if covered.contains(parent) {
                covered.insert(item.relativePath)
                continue
            }
            guard removed.contains(item.relativePath),
                !copy.merged.contains(item.relativePath),
                let destination = copy.finished[item.relativePath]
            else { continue }
            moved.append(MovedItem(from: item.source, to: destination))
            covered.insert(item.relativePath)
        }
        return moved
    }

    /// Removes each source item whose copy finished, deepest first: a file once its copy
    /// is the right size, a folder once it's empty. A folder still holding what wasn't
    /// moved stays, and that isn't a failure.
    private func removeSources(
        of walks: [SourceWalk], finished: [String: URL]
    ) -> (removed: Set<String>, failures: [FileSystemError]) {
        var removed: Set<String> = []
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
                removed.insert(item.relativePath)
            } catch  where item.metadata.kind == .folder && error.errno == ENOTEMPTY {
                // Skipped or failed items are still inside.
            } catch {
                failures.append(error)
            }
        }
        return (removed, failures)
    }
}
