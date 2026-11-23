import Foundation

/// Outside changes to the session's file (docs/plans/M3c.md, D-c).
extension EditorSession {
    /// Starts watching the file; called once the session is set up.
    public func startWatching() {
        if watcher == nil {
            watcher = FileWatcher { [weak self] in self?.fileMayHaveChanged() }
        }
        watcher?.watch(url)
    }

    /// Stops watching (the tab closed).
    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Looks at the file after an event: nothing if it's what the session last opened or
    /// saved (its own saves raise nothing); a clean session reloads; one with unsaved
    /// edits reports `.fileChanged`, its edits safe on the clone.
    func fileMayHaveChanged() {
        guard watcher != nil else { return }
        guard !isSaving else { return changeArrivedWhileSaving = true }
        watcher?.watch(url)  // the path may have a new inode now
        guard let now = try? FileIdentity(url: url) else {
            guard fileState != .deleted else { return }
            fileState = .deleted
            return notify(.fileChanged)
        }
        guard !now.isUnchanged(from: identity) else { return }  // our own save, or a touch
        guard isDirty else {
            close()  // the clone and journal were of the old contents
            try? reloadFromDisk()
            fileState = .unchanged
            return
        }
        guard fileState != .changed || now != lastOutsideChange else { return }
        lastOutsideChange = now
        fileState = .changed
        notify(.fileChanged)
    }

    /// Drops the unsaved edits and reads the file as it is now (Reload in the sheet).
    public func reloadDiscardingEdits() throws {
        guard !isSaving else { throw EditorSessionError.saveInProgress }
        close()
        try reloadFromDisk()
        fileState = .unchanged
        lastOutsideChange = nil
        watcher?.watch(url)
    }

    /// A save landed: the file is ours again; watch its new inode.
    func fileWasSaved() {
        fileState = .unchanged
        lastOutsideChange = nil
        watcher?.watch(url)
    }
}
