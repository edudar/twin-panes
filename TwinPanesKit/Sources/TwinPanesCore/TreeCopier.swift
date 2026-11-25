import Foundation

/// How far an operation has got, for its progress row.
public struct OperationProgress: Sendable, Equatable {
    public var bytesDone: UInt64 = 0
    public var bytesTotal: UInt64 = 0
    public var itemsDone = 0
    public var itemsTotal = 0
    /// The path, below the destination, of the item being copied.
    public var currentItem: String?
}

/// What a copy did: what it created at the top level of the destination (for undo),
/// the items that failed, and whether it was cancelled.
public struct CopyOutcome: Sendable {
    public var created: [URL] = []
    public var failures: [FileSystemError] = []
    public var wasCancelled = false
}

/// Copies walked sources into a folder through the seam (docs/plans/M6.md, D-c), off
/// the main actor. A failed item is recorded and the rest go on; a folder that can't
/// be made takes its contents with it. Cancelling stops within the current file and
/// removes its partial copy. Folders get their sources' metadata after their
/// contents, so the copies' dates match.
public struct TreeCopier: Sendable {
    let fileSystem: any FileOperationSystem

    public init(fileSystem: any FileOperationSystem) {
        self.fileSystem = fileSystem
    }

    /// Blocks until done. `progress` is called on this thread after every item and
    /// while a file's data is copied.
    public func copy(
        _ walks: [SourceWalk], into destination: URL, control: OperationControl,
        progress: (OperationProgress) -> Void
    ) -> CopyOutcome {
        var outcome = CopyOutcome()
        var state = OperationProgress(
            bytesTotal: walks.reduce(0) { $0 + $1.totalBytes },
            itemsTotal: walks.reduce(0) { $0 + $1.items.count })
        var madeFolders: [(source: URL, copy: URL)] = []
        // Folders that couldn't be made, as "path/", so their contents are skipped.
        var lostFolders: [String] = []
        copying: for walk in walks {
            outcome.failures += walk.unreadable
            for item in walk.items {
                guard control.checkpoint() else {
                    outcome.wasCancelled = true
                    break copying
                }
                let target = destination.appendingPathComponent(item.relativePath)
                state.currentItem = item.relativePath
                if lostFolders.contains(where: { item.relativePath.hasPrefix($0) }) {
                    // Its folder's failure stands for it.
                } else if item.metadata.kind == .folder {
                    do {
                        try fileSystem.makeFolder(at: target)
                        madeFolders.append((item.source, target))
                        if !item.relativePath.contains("/") { outcome.created.append(target) }
                    } catch {
                        outcome.failures.append(error)
                        lostFolders.append(item.relativePath + "/")
                    }
                } else {
                    switch copyFile(item, to: target, control: control, state: state, progress) {
                    case .copied:
                        if !item.relativePath.contains("/") { outcome.created.append(target) }
                    case .failed(let error): outcome.failures.append(error)
                    case .cancelled:
                        outcome.wasCancelled = true
                        break copying
                    }
                }
                state.itemsDone += 1
                state.bytesDone += item.metadata.size
                progress(state)
            }
        }
        for folder in madeFolders.reversed() {
            do {
                try fileSystem.copyMetadata(from: folder.source, to: folder.copy)
            } catch {
                outcome.failures.append(error)
            }
        }
        return outcome
    }

    private enum FileResult {
        case copied, failed(FileSystemError), cancelled
    }

    /// One file, symlink or other item; a partial copy left by a failure or a cancel
    /// is removed.
    private func copyFile(
        _ item: PlannedItem, to target: URL, control: OperationControl,
        state: OperationProgress, _ progress: (OperationProgress) -> Void
    ) -> FileResult {
        guard item.metadata.kind != .other else {
            return .failed(FileSystemError("copy", item.source.path, errno: ENOTSUP))
        }
        do {
            try fileSystem.copyFile(item.source, to: target) { copied in
                var during = state
                during.bytesDone += copied
                progress(during)
                return control.checkpoint()
            }
            return .copied
        } catch {
            // EEXIST means the name was taken before we started: it isn't ours to remove.
            // Otherwise a partial copy may or may not be there; the failure being reported
            // already covers this item, so a failed removal adds nothing to say.
            if error.errno != EEXIST { try? fileSystem.remove(target) }
            return control.isCancelled ? .cancelled : .failed(error)
        }
    }
}
