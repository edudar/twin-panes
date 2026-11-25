import Foundation

/// How far an operation has got, for its progress row.
public struct OperationProgress: Sendable, Equatable {
    public var bytesDone: UInt64 = 0
    public var bytesTotal: UInt64 = 0
    public var itemsDone = 0
    public var itemsTotal = 0
    /// The path, below the destination, of the item being copied.
    public var currentItem: String?
    /// The current item is being downloaded from iCloud before it's copied.
    public var isDownloading = false
}

/// An item a copy made, and the source it was made from.
public struct MadeItem: Sendable, Equatable {
    public let source: URL
    public let copy: URL
}

/// What a copy did: what it created (for undo), the items that failed, and whether it
/// was cancelled.
public struct CopyOutcome: Sendable {
    /// Items made where nothing of this copy's was: the top-level copies, and the new
    /// items inside folders it merged into.
    public var created: [MadeItem] = []
    /// Every item the copy finished, made or a folder merged into, by its path below
    /// the destination as walked, with where it is now: a move removes these sources.
    public var finished: [String: URL] = [:]
    /// What Replace sent to the Trash.
    public var replaced: [TrashedItem] = []
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
    /// while a file's data is copied; `resolve` when an item's name is taken, and the
    /// copy waits for its answer.
    public func copy(
        _ walks: [SourceWalk], into destination: URL, control: OperationControl,
        resolve: (Conflict) -> ConflictAnswer, progress: (OperationProgress) -> Void
    ) -> CopyOutcome {
        var run = CopyRun(destination: destination)
        // Cancelled before it began (while it waited its turn, say): the walks came back
        // empty, and nothing below would notice.
        guard control.checkpoint() else {
            run.outcome.wasCancelled = true
            return run.outcome
        }
        run.progress.bytesTotal = walks.reduce(0) { $0 + $1.totalBytes }
        run.progress.itemsTotal = walks.reduce(0) { $0 + $1.items.count }
        copying: for walk in walks {
            run.outcome.failures += walk.unreadable
            for item in walk.items {
                guard control.checkpoint() else {
                    run.outcome.wasCancelled = true
                    break copying
                }
                run.progress.currentItem = item.relativePath
                if !run.isLeftOut(item) {
                    guard copyItem(item, in: &run, control: control, resolve, progress) else {
                        run.outcome.wasCancelled = true
                        break copying
                    }
                }
                run.progress.itemsDone += 1
                run.progress.bytesDone += item.metadata.size
                progress(run.progress)
            }
        }
        for folder in run.madeFolders.reversed() {
            do {
                try fileSystem.copyMetadata(from: folder.source, to: folder.copy)
            } catch {
                run.outcome.failures.append(error)
            }
        }
        return run.outcome
    }

    /// Copies one item, first settling a conflict if its name is taken. False once the
    /// copy is to stop (cancelled, or the user chose Stop).
    private func copyItem(
        _ item: PlannedItem, in run: inout CopyRun, control: OperationControl,
        _ resolve: (Conflict) -> ConflictAnswer, _ progress: (OperationProgress) -> Void
    ) -> Bool {
        var target = run.target(of: item)
        let isFolder = item.metadata.kind == .folder
        if let existing = try? fileSystem.metadata(of: target) {
            let conflict = Conflict(item: item, existing: target, existingMetadata: existing)
            let answer = run.remembered[isFolder] ?? resolve(conflict)
            if answer.applyToAll { run.remembered[isFolder] = answer }
            // An answer remembered for all may not fit this conflict (Merge for a file).
            let choice = conflict.choices.contains(answer.choice) ? answer.choice : .skip
            switch choice {
            case .stop: return false
            case .skip:
                run.leaveOut(item)
                return true
            case .merge:
                run.outcome.finished[item.relativePath] = target
                return true
            case .keepBoth:
                let name = KeepBothName.next(for: target.lastPathComponent) {
                    (try? fileSystem.metadata(
                        of: target.deletingLastPathComponent()
                            .appendingPathComponent($0))) != nil
                }
                target = target.deletingLastPathComponent().appendingPathComponent(name)
                run.rename(item, to: target)
            case .replace:
                do {
                    let trashed = try fileSystem.trash(target)
                    run.outcome.replaced.append(TrashedItem(original: target, trashed: trashed))
                } catch {
                    run.outcome.failures.append(error)
                    run.leaveOut(item)
                    return true
                }
            }
        }
        if isFolder {
            do {
                try fileSystem.makeFolder(at: target)
                run.made(item, at: target)
            } catch {
                run.outcome.failures.append(error)
                run.leaveOut(item)
            }
            return true
        }
        switch copyFile(item, to: target, control: control, state: run.progress, progress) {
        case .copied: run.made(item, at: target)
        case .failed(let error): run.outcome.failures.append(error)
        case .cancelled: return false
        }
        return true
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
        if item.metadata.isDataless {
            var downloading = state
            downloading.isDownloading = true
            progress(downloading)
            do {
                try fileSystem.download(item.source) { control.isCancelled }
            } catch {
                return control.isCancelled ? .cancelled : .failed(error)
            }
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

/// One copy's bookkeeping: where each item lands, given the folders renamed by Keep
/// Both, merged, or left out by Skip or a failure.
private struct CopyRun {
    let destination: URL
    var outcome = CopyOutcome()
    var progress = OperationProgress()
    var madeFolders: [(source: URL, copy: URL)] = []
    /// Answers given with Apply to All, for folders (true) and everything else.
    var remembered: [Bool: ConflictAnswer] = [:]
    private var made: Set<String> = []
    private var leftOut: [String] = []
    /// Folders Keep Both renamed: original relative path to the new destination URL.
    private var renamed: [String: URL] = [:]

    init(destination: URL) { self.destination = destination }

    func target(of item: PlannedItem) -> URL {
        var parent = (item.relativePath as NSString).deletingLastPathComponent
        var tail = [(item.relativePath as NSString).lastPathComponent]
        while !parent.isEmpty {
            if let moved = renamed[parent] {
                return tail.reversed().reduce(moved) { $0.appendingPathComponent($1) }
            }
            tail.append((parent as NSString).lastPathComponent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        return destination.appendingPathComponent(item.relativePath)
    }

    func isLeftOut(_ item: PlannedItem) -> Bool {
        leftOut.contains { item.relativePath.hasPrefix($0) }
    }

    mutating func leaveOut(_ item: PlannedItem) { leftOut.append(item.relativePath + "/") }

    mutating func rename(_ item: PlannedItem, to target: URL) {
        renamed[item.relativePath] = target
    }

    /// Records a made item; it counts as created unless its folder was made by this copy.
    mutating func made(_ item: PlannedItem, at target: URL) {
        made.insert(item.relativePath)
        outcome.finished[item.relativePath] = target
        if item.metadata.kind == .folder { madeFolders.append((item.source, target)) }
        let parent = (item.relativePath as NSString).deletingLastPathComponent
        if !made.contains(parent) {
            outcome.created.append(MadeItem(source: item.source, copy: target))
        }
    }
}
