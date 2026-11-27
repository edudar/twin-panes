import Foundation

/// The session folder and the clone made at the first edit (docs/plans/M3c.md, D-a).
extension EditorSession {
    /// Checks that the session is ready for an edit before reading uncached bytes or
    /// making the session folder: refuses read-only files, reloads if changed on disk
    /// (throwing `.reloadedBeforeEdit`), and starts downloading evicted iCloud files
    /// (throwing `.downloadingBeforeEdit`).
    public func prepareForFirstEdit() throws {
        if case .readOnly(let reason) = access { throw EditorSessionError.readOnly(reason) }
        guard folder == nil, sessionsRoot != nil else { return }
        if try !FileIdentity(url: url).isUnchanged(from: identity) {
            try reloadFromDisk()
            fileState = .unchanged
            lastOutsideChange = nil
            watcher?.watch(url)
            throw EditorSessionError.reloadedBeforeEdit
        }
        // Evicted to iCloud since it was opened: a clone would share no bytes.
        if cloudDownloads.isDataless(url) {
            try cloudDownloads.startDownload(url)
            throw EditorSessionError.downloadingBeforeEdit
        }
    }

    /// Before the first edit: if the file changed since it was opened, reload it and throw
    /// `EditorSessionError.reloadedBeforeEdit` so the stale edit is dropped; otherwise make
    /// the folder, clone the file into it and switch the original pieces to the clone, so
    /// nothing another app does to the file can change the bytes under the edits. A clone
    /// that fails leaves the session narrowed. A file whose bytes are only in iCloud
    /// starts downloading and throws `.downloadingBeforeEdit`; the next edit after it has
    /// arrived goes ahead (docs/plans/M6.md, D-h).
    func protectBeforeFirstEdit() throws {
        try prepareForFirstEdit()
        guard folder == nil, let root = sessionsRoot else { return }
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let made = try SessionFolder.create(
            in: root, id: id,
            manifest: SessionManifest(path: url.path, bookmark: bookmark, identity: identity))
        do {
            let add = try AddBuffer(directory: made.url)
            var original = buffer.original
            let clone = made.file(Self.cloneName)
            if (try? saver.fileSystem.clone(url, to: clone)) != nil,
                let cloned = try? ByteSource(url: clone), cloned.length == original.length
            {
                original = cloned
            } else {
                isNarrowed = true
            }
            buffer.attach(original: original, add: add)
            if isNarrowed {
                // Without a clone the journal can't be replayed safely after a save (the
                // file then holds the saved bytes, not the opened ones), so a narrowed
                // session keeps none: the folder is only the add buffer's, and marked closed
                // so the next launch deletes it (docs/plans/M3c.md, D-d as built).
                try made.markClosed()
            } else {
                journal = try SessionJournal(folder: made, add: add, fileSystem: saver.fileSystem)
            }
        } catch {
            made.delete()
            throw error
        }
        folder = made
    }

    static let cloneName = "original.clone"

    /// Journals the change from `old` to the current tree. A journal that fails to write
    /// is dropped: the edits go on, no longer recoverable after a crash.
    func journalChange(from old: PieceTree) {
        do { try journal?.record(from: old, to: buffer.tree) } catch { journal = nil }
    }

    /// Reads the file afresh: a new edit model, the file's current identity, no history.
    func reloadFromDisk() throws {
        let source = try ByteSource(url: url)
        buffer = EditBuffer(original: source)
        identity = source.identity
        savedTree = buffer.tree
        undoStack = UndoStack()
        notify(.edited)
    }

    /// The session is done with its file (its tab closed, or the app quits): the folder
    /// is marked closed and deleted, and observers learn the session closed. Snapshots
    /// still reading the clone keep their open descriptors.
    public func close() {
        closeFolder()
        notify(.closed)
    }

    /// Closes the journal and deletes the session folder without notifying `.closed`.
    func closeFolder() {
        journal?.close()
        journal = nil
        guard let folder else { return }
        try? folder.markClosed()
        folder.delete()
        self.folder = nil
    }
}
