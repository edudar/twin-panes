import Foundation

/// Saving a session (docs/plans/M3b.md, D-c and D-d).
extension EditorSession {
    /// A save is running or queued.
    public var isSaving: Bool { savesPending > 0 }

    /// Writes the current version to the file and makes it the saved one.
    ///
    /// - The save writes a snapshot of the version current when it starts, off the main
    ///   actor; edits made meanwhile stay unsaved (the session is still dirty after).
    /// - One save runs at a time. A save asked for while one runs is queued once and
    ///   writes the version current when its turn comes; further requests join it.
    /// - On failure nothing changes on disk or in the session, and the error is thrown.
    ///   A read-only session throws `EditorSessionError.readOnly`.
    public func save() async throws {
        if case .readOnly(let reason) = access { throw EditorSessionError.readOnly(reason) }
        if savesPending >= 2, let queued = saveTail { return try await queued.value }
        let previous = saveTail
        savesPending += 1
        if savesPending == 1 { notify(.saving) }
        let task = Task { @MainActor in
            _ = try? await previous?.value
            defer { self.finishSave() }
            try await self.performSave()
        }
        saveTail = task
        try await task.value
    }

    private func finishSave() {
        savesPending -= 1
        guard savesPending == 0 else { return }
        saveTail = nil
        notify(.saving)
    }

    /// Saves the version current now: plans against the saved version (the whole file if
    /// the disk no longer holds it), writes on a background queue, then records the result.
    private func performSave() async throws {
        let version = buffer.tree
        let onDisk = try? FileIdentity(url: url)
        let plan = SavePlan(
            saved: savedTree, current: version,
            diskMatchesSaved: onDisk?.isUnchanged(from: identity) ?? false)
        if plan.ranges.isEmpty, !plan.writesWholeFile {
            savedTree = version  // same bytes in the same places: nothing to write
            return notify(.saved)
        }
        let (saver, url, scope, snapshot) = (saver, url, scope, buffer.snapshot())
        // A dispatch queue, not Swift concurrency's few threads: a save blocks on disk
        // I/O, for long when a volume can't clone and the file is copied.
        identity = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try withExtendedLifetime(scope) {
                            try saver.save(snapshot, plan: plan, to: url)
                        }
                    })
            }
        }
        savedTree = version
        notify(.saved)
    }
}
