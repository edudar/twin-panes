# M3c plan: protecting unsaved edits and crash recovery

_Status: draft 2026-11-22, written with the M3b split. It gets reviewed again, updated
from how M3b was actually built, before M3c starts._

## Context

After M3b the hex editor saves with strategy A, but its unsaved edits sit on the live
file:
- An external in-place rewrite changes the bytes under them.
- A crash loses them.
- Hard-linked files can't be saved in place.

M3c delivers the rest of PLAN.md's first-usable guarantees (D15–D17).

**Done when:**
- Killing the app mid-edit or mid-save loses nothing.
- A power loss loses at most the last ~1 s of edits.
- Typing during a save keeps the new edits and their journal.
- Saving never triggers the external-change sheet.
- An external change never corrupts unsaved edits.
- The fault-injection suite (PLAN.md §7) passes.

## Decisions (agreed when M3b was split)

### D-a: a session folder created on the first edit, holding the clone

- **Folder:** `Application Support/Sessions/<session-id>/` in the container holds:
  - `manifest.json`: a bookmark of the file, its identity, sizes, the clone's name and a
    format version
  - `add.bin`: the `AddBuffer`, moved here from its temp folder
  - `journal.bin` (D-e)
  - `original.clone`
- **Created on the first edit, not at open**, as decided on review. Viewing a file never
  writes anything, and this settles the "lazy `AddBuffer`" deferral from §9.
- **At the first edit:**
  1. Check the file's identity, size and mtime against what was seen at open. If they
     changed, reload first (the session is still clean).
  2. `clonefile` the file into the folder.
  3. Swap `EditBuffer.original` to a `ByteSource` on the clone. The offsets are the
     same, so the tree doesn't change.
- **The clone is the session's backing generation** for its whole life. Saves never
  rebase pieces, so the clone keeps the undo history and journal replay valid.
- **iCloud dataless files** (`SF_DATALESS`, a §9 deferral) are read in the background so
  they download before the clone. The status line says "Downloading from iCloud…".
- **Cleaning up:**
  - A clean close, Discard or Revert deletes the folder once no snapshot holds it.
  - Orphans are swept at launch, after recovery.

### D-b: strategy B for hard-linked files

Strategy B is used when `st_nlink > 1`, or when staging fails on a volume with a clone:
1. Write the old bytes of the ranges and the file's identity to a save journal in the
   session folder, then `F_FULLFSYNC`.
2. Write the ranges in place, then `F_FULLFSYNC`.
3. Append a commit record, `F_FULLFSYNC`, and delete the save journal.

- At launch, a save journal without a commit record rolls the file back once its
  identity checks out; one with a commit record is just deleted.
- The pieces point into the clone, so no remapping is needed.

### D-c: external changes, and our own writes

- The session is an `NSFilePresenter`, and saves coordinate with it, so our own writes
  don't notify it. A `DispatchSource` vnode watch is the fallback; it compares size,
  mtime and inode with what the last save wrote.
- **Clean session:** reload silently, with a new tree, an empty undo history, and the
  selection clamped to the new length.
- **Dirty session:** a sheet offering **Keep Mine** (the next save writes the whole
  file, per M3b's D-c), **Reload** and **Save As…**.
- **Deleted file:** the tab stays open, dirty and backed by the clone. Save writes the
  file back.

### D-d: narrowed mode, on volumes without a clone (decided on review)

- The journal's header records the file's size, mtime and a hash of 16 sampled pages.
  Replay runs only if all of them still match. The status line shows "Limited recovery
  on this volume".
- **Saving:** strategy A only, and the journal is rebased onto the new file after each
  save. Strategy B is refused and Save As… offered, because remapping pieces waits for
  the external-volume spike.
- The private copy (§9.3) stays deferred.

### D-e: the operation journal

- `journal.bin` is append-only, framed records with a length, a type, a payload and a
  CRC32C. Replay stops at the first bad record.
- **Record types:**
  - `header`
  - `replace(range, pieces)`, for edits, undo, redo and Discard alike
  - `saved(recordIndex)`
  - `closed`
- **Durability:**
  - Each record is `write()`n at once.
  - `F_FULLFSYNC` of `add.bin` and then `journal.bin` runs on a 1 s debounce, and on
    every save, close and app deactivation.
  - The add buffer's bytes are always appended before the record that uses them.

### D-f: crash recovery at launch

- Every session folder without a `closed` record is reopened:
  1. Resolve the bookmark and open the clone.
  2. Resolve any strategy-B save journal.
  3. Replay the journal.
  4. Treat the version at the last `saved` record as the saved one.
- The tab comes back dirty, with a "Recovered unsaved changes" banner and **no undo
  history** (D15).
- If the file can't be found or reached, the tab opens from the clone, and Save As…
  is the way out.

### D-g: fault injection

- `FaultyFileSystem`, behind M3b's `FileSystem` seam, is an in-memory file system that
  keeps durable and volatile bytes for each file. Metadata operations count as durable
  at once. It can throw at operation N, standing in for a kill, or simulate a power
  loss at N.
- **The suite covers:**
  - every operation of strategies A and B, journal appends and the fsync debounce
  - typing during a save
  - external rewrites during an edit and during a save
  - a lost volume
- **Each case must end** with the old or the new file intact, and with a recovered tree
  that matches the reference model up to the last durable record.
- The kill cases also run once against `RealFileSystem`.

## Commits (outline; detailed at the re-review)

1. The session folder and manifest, lazy creation, the launch sweep.
2. The clone at the first edit, with the identity check and the reload-first path.
3. Strategy B and the launch rollback, which removes M3b's hard-link refusal.
4. File watching with our own writes suppressed.
5. The external-change policy and sheet.
6. iCloud dataless files.
7. The journal format.
8. Journaling the session.
9. Recovery.
10. Restoring tabs at launch.
11. Narrowed mode.
12. `FaultyFileSystem`.
13. The fault suite, in several parts.
14. The crash smoke test: a child app run in `--crash-after-edit` mode, then relaunched.
15. Docs.

**By hand (the maintainer):** the external APFS, HFS+ and exFAT part of the sandbox
spike. It decides whether D-d stays as written.
