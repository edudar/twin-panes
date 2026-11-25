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
        for item in items {
            guard control.checkpoint() else {
                outcome.wasCancelled = true
                break
            }
            state.currentItem = item.from.lastPathComponent
            guard putBack(item, into: &outcome, control: control, resolve: resolve) else {
                outcome.wasCancelled = true
                break
            }
            state.itemsDone += 1
            progress(state)
        }
        return outcome
    }

    /// One item; false once the user chose Stop.
    private func putBack(
        _ item: MovedItem, into outcome: inout MoveOutcome, control: OperationControl,
        resolve: (Conflict) -> ConflictAnswer
    ) -> Bool {
        var target = item.from
        guard target.standardizedFileURL.path != item.to.standardizedFileURL.path else {
            return true
        }
        let metadata: FileItemMetadata
        do {
            metadata = try fileSystem.metadata(of: item.to)
        } catch {
            outcome.failures.append(error)
            return true
        }
        if let existing = try? fileSystem.metadata(of: target) {
            let planned = PlannedItem(
                source: item.to, relativePath: target.lastPathComponent, metadata: metadata)
            let conflict = Conflict(item: planned, existing: target, existingMetadata: existing)
            switch resolve(conflict).choice {
            case .stop: return false
            case .skip, .merge: return true
            case .keepBoth:
                let name = KeepBothName.next(for: target.lastPathComponent) {
                    (try? fileSystem.metadata(
                        of: target.deletingLastPathComponent()
                            .appendingPathComponent($0))) != nil
                }
                target = target.deletingLastPathComponent().appendingPathComponent(name)
            case .replace:
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
            try fileSystem.rename(item.to, to: target)
            outcome.moved.append(MovedItem(from: item.to, to: target))
        } catch  where error.errno == EXDEV && target.lastPathComponent == item.to.lastPathComponent
        {
            let moved = TreeMover(fileSystem: fileSystem).move(
                [item.to], into: target.deletingLastPathComponent(), control: control,
                resolve: resolve, progress: { _ in })
            outcome.moved += moved.moved
            outcome.replaced += moved.replaced
            outcome.failures += moved.failures
        } catch {
            // Across volumes under another name: moving and renaming would be two steps
            // that could leave it half done, so it stays where it is.
            outcome.failures.append(error)
        }
        return true
    }
}
