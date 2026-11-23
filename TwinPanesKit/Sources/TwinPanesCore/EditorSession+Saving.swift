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
        try await enqueueSave { try await self.performSave() }
    }

    /// Runs `perform` after the saves already running or queued, as one more save.
    private func enqueueSave(
        _ perform: @escaping @MainActor () async throws -> Void
    )
        async throws
    {
        let previous = saveTail
        savesPending += 1
        if savesPending == 1 { notify(.saving) }
        let task = Task { @MainActor in
            _ = try? await previous?.value
            defer { self.finishSave() }
            try await perform()
        }
        saveTail = task
        try await task.value
    }

    /// Writes the current version to `target` and makes it the session's file (Save As):
    /// `url`, `scope`, identity and access follow it, the version becomes the saved one,
    /// and the undo history stays. Waits its turn behind running saves like `save()`.
    /// On failure nothing changes.
    public func saveAs(to target: URL, scope: SecurityScope? = nil) async throws {
        try await enqueueSave {
            let (version, saver, snapshot) = (self.buffer.tree, self.saver, self.buffer.snapshot())
            let written = try await Self.offMain {
                try withExtendedLifetime(scope) { try saver.write(snapshot, to: target) }
            }
            if let old = self.scope { self.earlierScopes.append(old) }
            (self.url, self.scope, self.identity) = (target, scope, written)
            self.access = AccessMode.of(target)
            self.savedTree = version
            self.notify(.saved)
        }
    }

    /// Runs `body` on a dispatch queue, not Swift concurrency's few threads: a save
    /// blocks on disk I/O, for long when a volume can't clone and the file is copied.
    static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// Returns once no save is running or queued (quitting waits for this); a failed
    /// save counts as finished.
    public func finishSaving() async {
        while let tail = saveTail { _ = try? await tail.value }
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
        identity = try await Self.offMain {
            try withExtendedLifetime(scope) { try saver.save(snapshot, plan: plan, to: url) }
        }
        savedTree = version
        notify(.saved)
    }
}
