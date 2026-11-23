# M3b plan: sessions and saving

_Status: approved 2026-11-22; built 2026-11-22. How it was done is in PLAN.md (D30–D33,
the M3b "As built" note in §4.3, §9 "From M3b"). Split from the original M3b on review:
the clone, external changes, crash recovery and the fault-injection suite are M3c
(docs/plans/M3c.md). Typing during a save is checked in unit tests only: the running app
can't hold a save._

## Context

M3a is done: overwrite editing, undo and redo, a changed-bytes fill, and searches over
snapshots. Edits still live only in the tab, and closing can only discard them (D29).

M3b makes the hex editor **save**. It adds sessions (one per open file) and the
read-only mode, and saves with strategy A on the boot volume, the one volume the M0
sandbox matrix has measured.

**Done when:**
- Editing and saving a 4 GiB file is near-instant (only the changed ranges are
  written).
- Undo after a save, then saving again, brings back the original bytes.
- Typing during a save keeps the new edits, and the tab stays dirty.
- A save that fails or is interrupted leaves the old file intact.
- Read-only files can't be edited, and Save As… still works.

What already exists and is reused:
- `EditBuffer`, `EditSnapshot`, `UndoStack` and `AddBuffer` (M3a).
- `SecurityScope`, `BookmarkStore` and `RecentFiles`, which recreate stale bookmarks.
- `CloseCoordinator` with `sessionKey` and `canSave`, and `makeCloseAlert`, which
  already has the Save / Cancel / Don't Save variant.
- `ByteReading.write(…to:)`, the existing Save Selection path.
- docs/SANDBOX-SPIKE.md: on the boot volume, strategy A works with file and folder
  grants via `itemReplacementDirectory`; replacing a hard-linked file fails.

## Decisions

### D-a: `EditorSession` in TwinPanesCore owns the file; tabs own presentation

- **`EditorSession`** (`@MainActor`, Foundation only) holds:
  - the `EditBuffer` and the `UndoStack`, moved off `HexEditorItem` (a §9 M3a deferral)
  - `savedTree`, the version on disk
  - the file's `URL`, its `SecurityScope` and its `FileIdentity` (device, inode, size,
    mtime, link count)
  - the access mode (D-b)
- **Undo entries** keep the selection of the view that made the edit. The range each
  entry changed, which only M3c's journal needs, is added in M3c (changed while
  building step 2).
- **`SessionRegistry`**, one per app, is keyed by `FileIdentity`, and re-keyed when a
  save gives the file a new inode.
  - Opening a file that is already open focuses its tab. A second view on the same
    session comes with M7 and M11.
  - The session still notifies observers, with weak references, so the tab, the status
    line and the inspector all update from one source. This settles the "multi-view
    observation" deferral from §9.
- **`HexEditorItem`** keeps the selection, the typing burst, find and the view options.
  Its `sessionKey` is the session's ID, and `isDirty` means
  `!tree.isSameVersion(as: savedTree)`.
- **Isolation:** the session and its `EditBuffer` are main-actor only (the §9
  isolation deferral). Background work only ever sees `EditSnapshot`s.

### D-b: read-only mode

The session opens read-only, with the reason in the status line, when:
- the file has no write permission
- it is locked (`uchg`/`schg`)
- its volume is mounted read-only

In read-only mode typing beeps (the delegate refuses the write), Save is disabled, and
Save As… works. `canSave` is false, so the close sheet keeps the Discard form.

### D-c: what a save writes

- **No rebasing.** Pieces keep pointing at the original and the add buffer for the
  whole session.
  - After a strategy-A replace, the original's open descriptor still reads the old
    inode, so the undo history stays valid.
  - The disk space of the old inode comes back when the tab closes.
  - M3c moves the original pieces onto a clone.
- **The save plan** (`SavePlan`) walks the pieces of `savedTree` and the current tree
  side by side and writes, with the current bytes, every stretch where they take their
  bytes from a different source or offset. That covers new edits and edits undone since
  the last save, which is how undo after a save restores the original, and skips edits
  already saved. (Planned as the union of both trees' modified ranges; the exact
  comparison is as cheap and writes less, changed while building step 5.)
- **If the file on disk no longer matches** the identity, size and mtime recorded at the
  last open or save, the plan becomes **the whole file**. Patching ranges onto someone
  else's content would be wrong. M3c adds watching for changes and the sheet; M3b only
  makes the save correct.

### D-d: `Saver`, strategy A only

1. `clonefile` the file on disk into `itemReplacementDirectory`, or copy it when the
   clone fails, after checking there's enough free space.
2. Patch the staging file per the plan, then `F_FULLFSYNC` it.
3. A coordinated `replaceItemAt`.
4. Record the new identity, re-key the session, and recreate the recent-file bookmark,
   which goes stale after a replace (seen in the M0 spike).

- **Metadata:** xattrs, Finder tags, mode and creation date get round-trip tests.
- **Hard-linked files** (`st_nlink > 1`) can't be replaced in the sandbox, and an
  in-place write would overwrite bytes the undo history points at until M3c's clone.
  For them, **Save says why and offers Save As…**. Strategy B lands in M3c.
- **The save race:** a save takes the snapshot of revision A and runs off the main
  actor. When it commits, `savedTree = A`, and the tab stays dirty if the user has
  typed B meanwhile.
- **Other details:**
  - One save at a time per session. ⌘S during a save is queued once.
  - Errors show a sheet, and the session stays dirty.
  - Quitting waits for running saves to finish.
- **The `FileSystem` seam:** every write, fsync, clone, rename, replace and unlink the
  `Saver` makes goes through a `FileSystem` protocol, with `RealFileSystem` as the
  real implementation. M3c's fault injection swaps in a fake, so it needs no
  refactoring later.

### D-e: Save As…

1. `NSSavePanel`.
2. Stream the snapshot with `readSequential` into staging in `itemReplacementDirectory`
   on the target's volume.
3. `F_FULLFSYNC`, then replace or move it into place.
4. The session then edits the new file: its scope, its identity, the registry key and
   `savedTree = current`. The undo history stays.
5. The new file becomes a recent file.

## Behaviour

- **File menu:**
  - **Save** (⌘S): enabled while the session is dirty and writable.
  - **Save As…** (⇧⌘S).
  - **Revert to Saved**: asks first, then restores `savedTree` and clears the undo
    history.
- **Status line:**
  - "Modified (saving comes in M3b)" becomes "Modified".
  - "Saving…" shows while a save runs.
  - "Read-only: <reason>" shows when it applies.
  - Saving a hard-linked file shows "Can't save a file with hard links in place; use
    Save As…".
- **Close:** a writable dirty session gets the standard Save / Cancel / Don't Save sheet
  (Don't Save is destructive, ⌘D). Save in the sheet saves, then closes, or cancels the
  close if the save fails.
- **Edit menu:** Undo and Redo are titled "Undo Typing" and "Redo Typing" while there is
  something to undo or redo.

## Commits

Each commit is at most 250 lines, builds and passes on its own, and goes interface →
failing tests → implementation. I stop for "commit" after each one.

1. **Core: `FileIdentity` and access mode.** Device, inode, size, mtime and link count,
   plus detecting write permission, `uchg` and read-only volumes. Tests on temp files
   with chmod and chflags (cleared again afterwards).
2. **Core: `EditorSession` with the undo stack.** The session owns the `EditBuffer`, the
   `UndoStack` and `savedTree`, refuses edits when read-only, notifies observers, and
   reverts. Tests: dirty versus saved, coalescing, refused edits leaving no trace, weak
   observers. The tab still has its own stack until step 3 moves it, with the M3a undo
   tests.
3. **EditorKit: `HexEditorItem` on a session.** The item reads and writes through the
   session, `sessionKey` is the session's ID, and read-only typing refuses with the
   reason. Tests in EditorKit, including every event that should update the tab from
   the session's notifications.
4. **Core/App: `SessionRegistry`.** Keyed by device and inode, sessions held weakly;
   Open, Recent, the browser and drops all go through it, and opening an open file
   focuses its tab. Tests in Core, plus a smoke check. Re-keying moved to step 7, the
   first change that gives a session a new identity (changed while building).
5. **Core: the save plan.** The ranges where the saved and current trees differ, and the
   decision to write the whole file. A fuzz test: after random edits, jumps through the
   history, saves and outside changes, applying each plan to a byte model of the disk
   gives the current bytes, and a ranged plan writes exactly where the versions differ.
6. **Core: the `FileSystem` seam and `Saver` strategy A.** Clone or copy, patch, fsync,
   coordinated replace, and the new identity. Round-trip tests with xattrs, tags, mode
   and creation date; the hard-link refusal; the free-space check.
7. **Core: saving from the session.** An off-main save over a snapshot, the race
   (`savedTree = A`), one save at a time, a queued ⌘S, re-keying the registry, and failures leaving
   the session dirty. Tests with a gated `FileSystem` while typing.
8. **App: Save, Revert to Saved, and Save in the close sheet.** The menu items and their
   validation, `canSave`, the status line, the error sheet, the Undo and Redo titles,
   and quit waiting for saves. No code for the bookmark refresh: `RecentFiles` already
   recreates a bookmark that resolves stale, which is what a replaced file's does
   (found while building).
9. **App: Save As….** The save panel, the streamed staging write, retargeting the
   session, and recents.
10. **Smoke: saving in the running app.** Through the real menus:
    - type, ⌘S, and compare the file's bytes
    - undo, ⌘S, and compare with the original
    - save from the close sheet
    - type during a gated save
    - open a read-only file and check typing is refused
    - save at the end of the 4 GiB file, with a timing line
11. **Docs.**
    - PLAN.md: decisions D30 onwards; "As built" notes in §4.1, §4.3 and §4.8; the
      components table (`EditorSession`, `SessionRegistry`, `Saver`, `FileSystem`); and
      §9: close the multi-view and isolation deferrals.
    - README: saving, and the roadmap.
    - The status line of this plan.

## Out of scope (M3c, docs/plans/M3c.md)

- the session folder and the clone at the first edit
- strategy B, used for hard-linked files
- watching for external changes, and the change sheet
- iCloud dataless files
- the operation journal and crash recovery
- narrowed mode on volumes without a clone
- the fault-injection suite

Later milestones: insert and delete (M8), several views of a session (M7, M11).

## Verification

After every commit:
- `swift format lint --strict --recursive TwinPanesKit TwinPanes`
- `swift test --package-path TwinPanesKit`, and `--sanitize=thread` for Core and
  EditorKit commits
- `swift build --triple x86_64-apple-macosx15.0`
- the `xcodebuild` build, and `--smoke-test` printing `SMOKE OK`

The rules from the M3a review apply throughout:
- no spin-waits
- wait on what the UI shows, not on the cache
- fuzz every parameter
- every event that invalidates state gets its own test
- smoke checks go through the real menus and sheets

By hand:
- Edit, save, reopen.
- Undo past a save and save again.
- Save a 4 GB patterned file.
- Open a locked file.
- Save a hard-linked file, which is refused and offers Save As.
