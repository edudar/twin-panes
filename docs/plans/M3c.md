# M3c plan: protecting unsaved edits and crash recovery

_Status: done 2026-11-23. Steps 1–12 and the docs (14) are built (narrowed mode
reduced, see D-d; external changes use a vnode watch rather than `NSFilePresenter`, see
D-c; the fault suite runs on real files, see D-g). PLAN.md D34–D37 and the §4.2 As built
note are the record. Closed with two steps left, logged in PLAN.md §9: iCloud dataless
files (13) move to M6, and the crash smoke test with a child process to M5._

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

## What M3b built that M3c builds on

- `EditorSession` owns the `EditBuffer`, undo, `savedTree`, identity, access and scope,
  and saves through `Saver` → `FileSystem` on a dispatch queue (D30, D32).
- Pieces point at the file as opened; after a strategy-A replace the session reads the
  old inode through its descriptor (D33). M3c's clone replaces that with a file the
  session owns.
- `SavePlan` compares piece trees exactly (D31). The journal reuses that comparison to
  record what any tree change (edit, undo, redo, revert) did, so undo entries need no
  changed range after all.
- Only `Saver` writes through `FileSystem`; the add buffer and the journal join it here.

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

- **As built (step 10):** a vnode `DispatchSource` on the file is the watch, not
  `NSFilePresenter`, which only hears coordinated writes. Our own saves are told apart by
  identity: an event leaving the file as the session last saved it is ignored, and events
  during a save wait for it to finish. A deleted file is written back whole by Save. The
  sheet comes up for a change, not a deletion; the status line says "Deleted on disk".

### D-d: narrowed mode, on volumes without a clone (decided on review)

- The journal's header records the file's size, mtime and a hash of 16 sampled pages.
  Replay runs only if all of them still match. The status line shows "Limited recovery
  on this volume".
- **Saving:** strategy A only, and the journal is rebased onto the new file after each
  save. Strategy B is refused and Save As… offered, because remapping pieces waits for
  the external-volume spike.
- The private copy (§9.3) stays deferred.
- **As built (step 9, changed while building):** no journal at all for now. Replaying
  against the live file goes wrong once a save has run: the file then holds the saved
  bytes, so a record that undid an edit back to the opened bytes would replay to the
  saved ones. Rebasing the journal at each save needs more design, and narrowed mode only
  happens on volumes the spike hasn't measured. So a narrowed session journals nothing,
  marks its folder closed at once (the next launch deletes it), says "No crash recovery
  on this volume", and saves with strategy A only. Hashing, conditional replay and
  rebasing wait for the external-volume spike.

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
- **As built (steps 11–12):** `CrashingFileSystem` (in the tests) wraps the real file
  system instead of keeping files in memory, so sources and the add buffer read real
  files: it throws at operation N and from then on (a kill), and `powerLoss()` puts
  every file written since its last `F_FULLFSYNC` back to its flushed contents. The add
  buffer writes outside the seam, so its own power loss isn't simulated. The suites:
  saving with strategies A and B (old or new contents after recovery's rollback), and a
  scripted session (the state recovered is one it had: after a kill the last before the
  crash; the saved version is never one the file doesn't hold). Typing during a save,
  outside rewrites and a lost volume are covered by their own tests, not crash points.

## Commits

Each at most 250 lines, verified alone, committed as it's done.

1. **Core: `SessionFolder`.** `Sessions/<id>/` under a root (Application Support in the
   app, a temp folder in tests): created on demand, `manifest.json` (format version,
   file bookmark and path, identity at open), a `closed` marker, deletion, and a sweep
   of closed or empty folders at launch.
2. **Core: the edit buffer switches sources once.** `EditBuffer` starts without an add
   buffer; `attach(original:add:)` swaps in the clone and an add buffer in the session
   folder before the first edit. Snapshots taken earlier keep what they had.
3. **Core: the clone at the first edit.** `EditorSession` creates its folder, checks the
   file is unchanged since open (else reloads first, while clean), clones it, attaches.
   A clone that fails (another volume) leaves the session narrowed (step 9).
4. **Core: the journal format.** Framed records with a CRC32C; a reader that stops at
   a torn or corrupt tail. Fuzz: truncations and bit flips never misread a record.
5. **Core: journaling the session.** `replace` records (from the tree comparison) for
   every change, `saved` and `closed`; the add buffer's bytes before the record; the
   `F_FULLFSYNC` debounce (1 s) and flushes on save and close. Replay equals the live
   tree after random sessions.
6. **Core: recovery.** Scan the folders without `closed`, open the clone and add
   buffer, replay, and give back sessions that are dirty with no undo history.
7. **App: restore tabs at launch** with a "Recovered unsaved changes" status, then
   sweep. Smoke: a recovered folder prepared on disk comes back as a dirty tab.
8. **Core: strategy B** for hard-linked files (save journal, in-place write, commit
   record, launch rollback); M3b's refusal goes for sessions with a clone.
9. **Core: narrowed mode** where the clone fails: sampled-page hash in the manifest,
   conditional replay, strategy A only.
10. **Core/App: external changes.** `NSFilePresenter` on the session; saves coordinate
    with it so they raise nothing; a clean tab reloads, a dirty one gets Keep Mine /
    Reload / Save As.
11. **Tests: `FaultyFileSystem`** (durable and volatile bytes, throw or power loss at
    operation N), with the add buffer and journal writing through `FileSystem`.
12. **Tests: the fault suite** for strategy A, B and the journal.
13. **iCloud dataless files**, behind an injected flag.
14. **Docs.**

Steps that don't fit before the maintainer is back stay in this list for the next
session; the status line says how far it got.

**By hand (the maintainer):** the external APFS, HFS+ and exFAT part of the sandbox
spike. It decides whether D-d stays as written.
