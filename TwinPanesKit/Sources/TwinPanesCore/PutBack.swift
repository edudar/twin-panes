import Foundation

/// Undo's way of moving items back to exactly where they were, under their old names
/// (docs/plans/M6.md, D-g): out of the Trash, back from a move, a rename undone. On one
/// volume each is renamed; across volumes it's moved with `TreeMover`. A taken name is
/// a conflict, asked like any other.
public struct PutBack: Sendable {
    let fileSystem: any FileOperationSystem

    public init(fileSystem: any FileOperationSystem) { self.fileSystem = fileSystem }

    /// Moves each item's `to` back to its `from`. The outcome's `moved` lists what went
    /// back (from where it was to where it is now).
    public func putBack(
        _ items: [MovedItem], control: OperationControl,
        resolve: (Conflict) -> ConflictAnswer, progress: (OperationProgress) -> Void
    ) -> MoveOutcome {
        var outcome = MoveOutcome()
        var state = OperationProgress(itemsTotal: items.count)
        var remembered: [Bool: ConflictAnswer] = [:]
        func ask(_ conflict: Conflict) -> ConflictAnswer {
            let isFolder = conflict.item.metadata.kind == .folder
            if let saved = remembered[isFolder], conflict.choices.contains(saved.choice) {
                return saved
            }
            let answer = resolve(conflict)
            if answer.applyToAll { remembered[isFolder] = answer }
            return answer
        }
        for item in items {
            guard control.checkpoint() else {
                outcome.wasCancelled = true
                break
            }
            state.currentItem = item.from.lastPathComponent
            let baseDone = state.itemsDone
            let baseTotal = state.itemsTotal
            var subProgress: OperationProgress?
            let keepGoing = putBack(
                item, into: &outcome, control: control, resolve: ask
            ) { report in
                subProgress = report
                var combined = report
                combined.itemsDone += baseDone
                combined.itemsTotal += baseTotal - 1
                progress(combined)
            }
            guard keepGoing else {
                outcome.wasCancelled = true
                break
            }
            if let subProgress {
                state.itemsDone += subProgress.itemsDone
                state.itemsTotal += max(subProgress.itemsTotal, 1) - 1
                state.bytesDone += subProgress.bytesDone
                state.bytesTotal += subProgress.bytesTotal
            } else {
                state.itemsDone += 1
            }
            progress(state)
        }
        return outcome
    }

    /// One item; false once cancelled or the user chose Stop.
    private func putBack(
        _ item: MovedItem, into outcome: inout MoveOutcome, control: OperationControl,
        resolve: (Conflict) -> ConflictAnswer, progress: (OperationProgress) -> Void
    ) -> Bool {
        var target = item.from
        let isCaseOnly =
            BookmarkStore.sameEntry(target, item.to)
            && target.lastPathComponent != item.to.lastPathComponent
        if BookmarkStore.sameEntry(target, item.to), !isCaseOnly {
            return true
        }
        let metadata: FileItemMetadata
        do {
            metadata = try fileSystem.metadata(of: item.to)
        } catch {
            outcome.failures.append(error)
            return true
        }
        if !isCaseOnly, let existing = try? fileSystem.metadata(of: target) {
            let planned = PlannedItem(
                source: item.to, relativePath: target.lastPathComponent, metadata: metadata)
            let conflict = Conflict(item: planned, existing: target, existingMetadata: existing)
            let answer = resolve(conflict)
            let choice = conflict.choices.contains(answer.choice) ? answer.choice : .skip
            switch choice {
            case .stop: return false
            case .skip: return true
            case .merge:
                return mergeFolder(
                    from: item.to, into: target, outcome: &outcome, control: control,
                    resolve: resolve, progress: progress)
            case .keepBoth:
                let name = KeepBothName.next(for: target.lastPathComponent) {
                    (try? fileSystem.metadata(
                        of: target.deletingLastPathComponent()
                            .appendingPathComponent($0))) != nil
                }
                target = target.deletingLastPathComponent().appendingPathComponent(name)
            case .replace:
                guard !conflict.isSameItem else { return true }
                do {
                    let trashed = try fileSystem.trash(target)
                    outcome.replaced.append(TrashedItem(original: target, trashed: trashed))
                } catch {
                    outcome.failures.append(error)
                    return true
                }
            }
        }
        do {
            try ensureParentExists(for: target)
            try fileSystem.rename(item.to, to: target)
            outcome.moved.append(MovedItem(from: item.to, to: target))
        } catch  where error.errno == EXDEV && target.lastPathComponent == item.to.lastPathComponent
        {
            let moved = TreeMover(fileSystem: fileSystem).move(
                [item.to], into: target.deletingLastPathComponent(), control: control,
                resolve: resolve, progress: progress)
            outcome.moved += moved.moved
            outcome.replaced += moved.replaced
            outcome.failures += moved.failures
            if moved.wasCancelled { return false }
        } catch {
            // Across volumes under another name: moving and renaming would be two steps
            // that could leave it half done, so it stays where it is.
            outcome.failures.append(error)
        }
        return true
    }

    private func mergeFolder(
        from source: URL, into target: URL, outcome: inout MoveOutcome,
        control: OperationControl, resolve: (Conflict) -> ConflictAnswer,
        progress: (OperationProgress) -> Void
    ) -> Bool {
        let children: [URL]
        do {
            children = try fileSystem.contents(of: source).sorted().map {
                source.appendingPathComponent($0)
            }
        } catch {
            outcome.failures.append(error)
            return true
        }
        if !children.isEmpty {
            let moved = TreeMover(fileSystem: fileSystem).move(
                children, into: target, control: control, resolve: resolve, progress: progress)
            outcome.moved += moved.moved
            outcome.replaced += moved.replaced
            outcome.failures += moved.failures
            if moved.wasCancelled { return false }
        }
        do {
            try fileSystem.remove(source)
        } catch  where error.errno == ENOTEMPTY {
            // Skipped or failed children stay inside.
        } catch {
            outcome.failures.append(error)
        }
        return true
    }

    /// Recreates missing ancestor folders of `target` (e.g. after undoing a merged move).
    private func ensureParentExists(for target: URL) throws(FileSystemError) {
        let parent = target.deletingLastPathComponent()
        if (try? fileSystem.metadata(of: parent)) != nil { return }
        var missing: [URL] = []
        var probe = parent
        while (try? fileSystem.metadata(of: probe)) == nil {
            missing.append(probe)
            let up = probe.deletingLastPathComponent()
            if up.path == probe.path { break }
            probe = up
        }
        for folder in missing.reversed() {
            do {
                try fileSystem.makeFolder(at: folder)
            } catch  where error.errno == EEXIST {
                // Created concurrently or by an earlier step.
            }
        }
    }
}
