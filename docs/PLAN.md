# Filer — Plan

Status: draft v0.14 (2026-11-20). Living document; requirements will keep growing.
Open and deferred questions are collected in §9.

## 1. Goal

A native macOS file manager for Apple Silicon (arm64 only), intended as a ForkLift
replacement. The **first module** — and the primary driver — is a binary file
viewer/editor that opens, inspects, searches and edits files up to 4 GB. Offsets are
64-bit throughout, so 4 GB is the tested target, not a hard cap.

## 2. Decisions so far

| # | Decision | Implication |
|---|---|---|
| D1 | Filer is a file manager; the hex editor is its first module | Engine and viewer are separate frameworks the file-manager shell embeds. The hex editor ships first, as a tab in the main frame (D7). |
| D2 | Support current macOS + 2 previous → **macOS 15 Sequoia minimum** (macOS 27 is current; supported: 15, 26, 27). Raised from macOS 14 on 2026-11-20 because GitHub retired its hosted macOS 14 runners on 2026-11-02 | `@Observable`, modern Swift concurrency, SwiftUI 6 and `Synchronization.Mutex` are available. CI runs on GitHub-hosted runners for the oldest and newest supported releases, no self-hosted machine (§7). Raise the target as new releases ship and as hosted runners retire. |
| D3 | App Store is a possible future target | Build **sandbox-compatible from day one** (see §5). Anything that can't ship sandboxed is marked "Direct only". The M0 sandbox spike covers both browsing and the editor's write path, and its capability matrix drives the save policy and the App Store decision. |
| D4 | Overwrite-only editing is enough for the first usable version | Insert/delete stays a later milestone; the piece table still supports it so nothing is redesigned later. |
| D5 | Write our own engine (no Hex Fiend dependency) | Hex Fiend remains a design reference only. |
| D6 | File-manager core features: 2 panels, multiple tabs per panel, Norton Commander-style F-key hotkeys, hidden files, Finder-like collapsible left sidebar, collapsible right preview pane | See §4.7. |
| D7 | **Single main frame.** Viewing, editing, previewing, terminals and similar features never open new windows; they live inside the main window. Dialogs (sheets/alerts/modal panels) stay dialogs. | See §4.8. The editor uses a custom `EditorSession` instead of `NSDocument` (rationale in §4). |
| D8 | Multiple main windows are allowed but low priority (tabs cover most needs). Requires **Merge All Windows**: left-panel tabs from all windows merge into the target's left panel, right into right. | See §4.9. Data model must not assume one window. |
| D9 | Keep §4.8 defaults for now: F3 → quick view in the opposite panel, F4 → editor tab in the active panel (mode picked by file type, §4.10; hex only until M9a), terminal → bottom drawer + Ctrl+O | Revisit once in daily use; all key bindings stay configurable (command registry, §4.11). |
| D10 | Build order: hex editor to its first usable version (M3b), then the browser, then back to hex polish | See §6. |
| D11 | Bundle ID `io.github.edudar.filer` | Fixed once on the App Store. "Filer" remains a working display name. |
| D12 | The editor has three modes — **Hex, Plain text, Markdown** — with find/replace inside the file being edited in every mode | See §4.10. Text editing needs insert/delete, so insert/delete (M8) must land before the text modes (M9a). |
| D13 | Public GitHub repo `edudar/filer`, licence **Apache-2.0** | Free GitHub Actions minutes on macOS runners. Apache-2.0 is App Store–compatible. Never commit signing secrets — use GitHub encrypted secrets for CI signing later. |
| D14 | The editor opens **regular files only** | No block devices, no packages as files. Files without write permission, locked (`uchg`) or root-owned open read-only; no privileged save. |
| D15 | **Unsaved edits survive a crash**: the add buffer is always a file, and edit operations are journaled and replayed on relaunch | See §4.2. Lands with sessions in M3b. A recovered session has its edits but no undo history. The guarantee holds only where the bytes the edits sit on are durably kept (a clone or private copy); elsewhere it is narrowed and the UI says so (§4.1). |
| D16 | **APFS clone at open** protects unsaved edits from external modification | See §4.1. Where cloning isn't possible (non-APFS, or a volume the sandbox can't write to), fall back to detect-and-warn. |
| D17 | **Two save strategies, both crash-safe.** Preferred: clone the original to a staging file, patch the staging file, coordinated replace. Fallback where replacement isn't possible or inode identity must be kept: in-place patch with a durable journal and an explicit commit record. | See §4.3. Which strategy applies is decided per volume and grant type from the M0 spike's capability matrix. |
| D18 | Hex display settings (offset base, byte grouping, text-column encoding) are **user-selectable view options** | See §4.4. |
| D19 | Out of scope for now: **accessibility** (VoiceOver for custom views) and **localization**. Hex replace arrives with M9a, after insert/delete, so it is any-length from the start | Revisit after the daily-driver milestones. |
| D20 | **Single-package layout:** one local Swift package holds every library target; a thin Xcode project holds only the app target (Info.plist, entitlements, document types, assets, signing). No XcodeGen. | See §4. Module dependencies are enforced by `Package.swift` and point strictly down (§4); `swift test` runs all logic tests; UI tests go through `xcodebuild`. |
| D21 | **Command registry as a catalog:** every action is a command with a stable ID (used by bindings, the F-key bar and the item switcher) that maps to an AppKit action. Menus send actions through the responder chain and validate with AppKit menu validation; the registry intercepts only context-dependent keys | See §4.11. Built in M0 with default bindings; user-editable in M10. |
| D22 | **Testing frameworks:** swift-testing for logic tests; XCTest for `measure` performance tests and UI tests | See §7. |
| D23 | **State restoration** uses AppKit's restoration APIs (`NSWindowRestoration`, `encodeRestorableState(with:)` / `restoreState(with:)`) for windows, slots and tabs; crash recovery stays separate and independently durable | See §4.8. Follows the system's "Close windows when quitting an app" setting. Lands in M5, multi-window in M11. |

## 3. Constraints that drive the design

| Constraint | Consequence |
|---|---|
| 4 GB files | Never load the whole file. Opening is O(1). In hex mode and the large-text viewer, memory stays at tens of MB regardless of file size. Every operation whose output scales with file or match count (add buffer, piece count, find-all, copy, line index) needs a cap or lives on disk (§4.2). |
| Text mode memory | `NSTextStorage` holds the whole text as UTF-16 (~2× file size before layout), so TextKit text mode has its own budget, bounded by the text-mode threshold (§4.10), not by the tens-of-MB target. |
| Smooth scrolling | 4 GB / 16 bytes per row ≈ 268M rows. SwiftUI lists and a plain NSScrollView document view don't hold up at that scale — a custom virtualized view is needed. Target: 120 Hz on ProMotion displays. Drawing never waits on disk I/O (§4.1). |
| Editing huge files | Edits can't rewrite a buffer. Use a piece table; saves stream to disk. |
| Arm64 only | Swift 6, no Intel slice. NEON-friendly paths (memchr, SIMD) for search. |
| Swift 6 strict concurrency | **Main-thread boundary:** all AppKit and view state is `@MainActor`. Each session's mutations have one serialized owner (the main actor; edits are cheap tree operations). Blocking reads, file coordination and saves run on bounded background I/O (a small fixed pool, not unbounded tasks). Search and save work on immutable `Sendable` snapshots of the edit model (§4.2). Shared caches are lock-protected with synchronous APIs, not actors, because draw code can't `await`. |
| Sandbox-ready | Only access files the user granted; persist access with security-scoped bookmarks; scope lifetimes are owned explicitly (§5). |

## 4. Architecture

Dependencies point strictly **down**; each layer imports only layers below it.

```
FilerApp (app target, thin)   — app lifecycle, menus, the single main frame,
 │                              preferences, sandbox/bookmarks; wires the kits
 │                              together (e.g. injects the hex-view factory into
 │                              BrowserKit's preview pane)
 ├─ BrowserKit (later)        — panes, tabs, file listing, operations queue, preview pane
 ├─ EditorKit (AppKit)        — the editor item: mode switcher, find bar,
 │   │                          hosts the mode views over one EditorSession
 │   ├─ HexViewKit (AppKit)   — virtualized hex/text view, selection, inspector UI
 │   └─ TextEditKit (AppKit)  — plain-text + Markdown modes (TextKit 2), large-text viewer
 └─ WorkspaceKit              — `WorkspaceItem` protocol, `MainFrameLayout`,
     │                          command registry (§4.11); knows no concrete item types
     └─ FilerCore             — no UI imports; unit-tested with `swift test`
         ├─ ByteSource          — read-only file access (pread + LRU page cache,
         │                        plus an uncached sequential read path)
         ├─ PieceTable          — edit model: original file + add-buffer file; persistent tree
         ├─ UndoStack           — stack of earlier piece-tree roots (+ cursor/selection)
         ├─ EditorSession /     — per-file session, dirty state, save/revert, file identity,
         │  SessionRegistry       backing generations, crash journal, security scope
         ├─ Searcher            — streaming hex/text search, cancellable, progress
         ├─ Inspector           — decode bytes at cursor (ints, floats, dates, text)
         └─ Saver               — in-place patch or temp file + atomic replace
```

- `HexViewKit`, `TextEditKit` and `BrowserKit` each depend on `WorkspaceKit` and
  `FilerCore`; none of them imports a sibling kit. Anything that crosses kits (the
  preview pane's hex view, F4 opening an editor from the browser) goes through a
  protocol or factory defined in `WorkspaceKit` and supplied by `FilerApp`.
- **Project layout (D20):** one local Swift package with all library targets
  (FilerCore, WorkspaceKit, EditorKit, HexViewKit, TextEditKit, later BrowserKit) plus
  a thin Xcode app target. No XcodeGen; `swift test` covers every target that has
  logic worth testing. The dependency graph above is what M0's `Package.swift`
  encodes.
- The `WorkspaceItem` protocol (§4.8) is how the editor, viewers and terminal are
  hosted in panel tabs, the preview pane or the bottom drawer. Defining it now
  costs little and keeps the editor kits from depending on app-level code.
- **No `NSDocument`, but a document lifecycle.** `NSDocument` does support several
  window controllers, so "one window per document" isn't the reason. The reasons are
  that its views are window controllers, while ours are tabs embedded in file-manager
  panes that move between slots and windows, and that its save machinery (autosave
  in place, versions, safe-save) can't be steered into the save strategies of §4.3
  for 4 GB files. Instead an `EditorSession` (FilerCore, Foundation only) owns the
  file and the edit history: `ByteSource` + `PieceTable`, undo, dirty state,
  save/revert, and adopts `NSFilePresenter` + `NSFileCoordinator` for
  external-change detection and coordinated writes. **Tabs own presentation**:
  selection, scroll position, mode, view options.
- **One close workflow** for closing a tab, closing a window and quitting. A dirty
  session prompts (as a sheet on the main window) exactly once, when its *last* view
  is about to close or the app quits. Quitting uses
  `applicationShouldTerminate(_:)` → `.terminateLater`, walks the dirty sessions one
  sheet at a time, then `reply(toApplicationShouldTerminate:)`.
- **Open With without NSDocument (M1):** declare `CFBundleDocumentTypes` for
  `public.data` with `LSHandlerRank = Alternate` (so Filer never becomes the default
  app for everything) and no `NSDocumentClass`; handle `application(_:open:)`.
  `NSDocumentController.shared.noteNewRecentDocumentURL(_:)` still drives the Open
  Recent menu, with sandbox-safe bookmarks, without using NSDocument.

### 4.1 File access: `ByteSource`
- **pread with an LRU page cache** (e.g. 64 KB pages × 256 = 16 MB).
- **Thread-safe, synchronous.** Snapshots are read from background threads (Searcher,
  Saver, line indexer) while HexView draws on the main thread. The page cache is
  guarded by `Synchronization.Mutex` (available from the macOS 15 minimum). The read API is
  synchronous; `ByteSource` is not an actor.
- **Drawing never blocks on I/O.** On SMB or USB volumes a cache miss can take
  tens of ms. The view asks for visible rows ± N via an asynchronous prefetch on the
  background I/O pool; a prepared **viewport model** (bytes per visible row, or
  "pending") is published to the main actor, and `draw(_:)` only reads that model.
  Rows whose pages haven't arrived are drawn as placeholders and redrawn when the
  pages land.
- **Uncached sequential path.** Searcher and Saver don't go through the LRU (a 4 GB
  scan would evict everything the view needs). They use large sequential `pread`s on
  a descriptor with `F_NOCACHE` set and no caching on our side.
- Not mmap by default: if another process truncates the file, touching the mapping
  raises SIGBUS and crashes the app; pread returns a short read we can handle.
- Watch the file through the session's `NSFilePresenter` (plus
  `DispatchSource.makeFileSystemObjectSource` as a fallback) to detect external
  modification/deletion.
- **Our own writes are not external changes.** Saves go through an
  `NSFileCoordinator` created with the session's presenter (`filePresenter:`), so
  the presenter isn't notified of its own write. The DispatchSource fallback compares
  size and mtime against what the save just wrote before raising anything.
- **External changes with unsaved edits.** Pieces reference ranges of the original
  file; if another process rewrites it, unsaved edits silently sit on top of
  different bytes. **(D16)** `clonefile(2)` the original at open (instant, no extra
  space until it diverges) and have original-file pieces reference the clone.
  Policy when a change is detected: clean session → reload silently; dirty session →
  sheet with Keep mine / Reload / Save As.
  - **Clone location.** Clones must be on the same volume as the original and must
    survive a reboot (crash recovery depends on them), so not
    `itemReplacementDirectory`, which the system may purge.
    - Original on the boot volume → clone into the app container's
      `Application Support/Sessions/<session-id>/`, next to that session's journal
      and add-buffer file.
    - Original on another volume → try a private directory on that volume. If that
      isn't possible (non-APFS, or a sandboxed app with only file-level access can't
      create anything there), fall back to detect-and-warn and journal without a
      clone.
    - The M3b spike checks each case: boot volume, APFS external, HFS+/exFAT, SMB.
  - **Backing generations.** An immutable piece tree only freezes *references*; the
    bytes stay stable only if the files they point into stay stable. Every file a
    piece can point at — a clone, a private copy, an add-buffer file — is a
    **reference-counted backing generation**. A generation stays alive while anything
    needs it: the current root, any root in the undo history, the crash journal, or a
    running task (search, save, quick view) holding a snapshot. A save produces a new
    generation for the new file contents; older ones are deleted only when the last
    holder releases them. Orphans are swept on launch, after crash recovery has run.
  - **Recovery guarantee per volume.** The live original plus a size/mtime check
    can't reconstruct old bytes after an external rewrite, so it isn't a recovery
    basis.
    - Clone available → full guarantee (edits recoverable after a crash, safe against
      external rewrites).
    - No clone → **(proposed)** make a private copy into Application Support before
      enabling recoverable editing, if the file is under a size limit (e.g. 1 GB) and
      space allows. Otherwise the guarantee is **narrowed**: edits are journaled, but
      recovery works only if the original is unchanged, and the editor shows a
      "limited recovery on this volume" note. Size limit and default: §9.
- **Scope of openable things (D14):** regular files only. Anything else (devices,
  directories, packages) is refused with a message; files that can't be written open
  read-only, with the reason shown in the status bar.

### 4.2 Edit model: `PieceTable`
- Pieces reference the original file (or its clone) by (offset, length), or a range
  of the add-buffer file, stored in a balanced tree keyed by cumulative length →
  O(log n) lookup, insert, delete, overwrite.
- **Persistent (immutable, structurally shared) tree.** Each edit produces a new root;
  taking a snapshot is O(1). Search, save and the large-text line indexer read a
  `Sendable` snapshot while the user keeps editing. Decide and prototype before M3a.
- **Add buffer is always a file** (from M3b), in the session's directory, read
  through the same page cache as the original. Pasting or inserting a 1 GB blob never
  lives in RAM, and the same file is what crash recovery replays against. No
  in-memory phase, no spill threshold.
- **Piece-count bound.** Replace All with millions of matches would create millions of
  pieces and break the memory target. Coalesce adjacent pieces, and above a
  threshold apply bulk replaces as a streaming rewrite into a new add-buffer region
  instead of per-match pieces.
- v1 exposes overwrite only (D4); insert/delete use the same structure later.
- **Undo = earlier roots.** With a persistent tree, the undo stack is a stack of
  previous roots (plus cursor/selection), not inverse operations. Undo swaps the
  current root for the previous one; redo the reverse. Coalescing a typing burst
  replaces the top entry instead of pushing a new one. Undo history survives saves
  (see §4.3 for what that requires).
- Randomized model-based tests against a plain `[UInt8]` reference.
- **Crash recovery (D15):** each session's directory holds the add-buffer file, the
  clone (if any) and an append-only **operation journal**: one record per edit
  (offset, length, add-buffer range, kind), not tree nodes, so replay is
  deterministic and independent of the tree's in-memory format.
  - **Durability.** Each record is `write()`n immediately — that alone survives the
    app being killed or crashing, since the data is in the kernel. For power loss,
    `fcntl(F_FULLFSYNC)` (plain `fsync` doesn't flush the drive cache on macOS) runs
    on a ~1 s debounce and on every save/close; add-buffer bytes are written before
    the record that references them.
  - **Replay.** On relaunch, journals of sessions that didn't close cleanly are
    replayed against their backing generation (clone or private copy). On narrowed
    volumes (§4.1) replay runs against the original only if its size, mtime and a
    hash of sampled pages still match what the journal recorded; otherwise the user
    is told the edits can't be reapplied and is offered "Save edits as patch…".
    The tab comes back dirty with its edits, a banner "Recovered unsaved changes",
    and **no undo history**.
  - **Save race.** Saving takes a snapshot of revision A; the user may keep typing
    revision B while the save runs. When the save commits, A becomes the saved
    revision: the session's "saved" marker moves to A, the session stays dirty, and
    the journal is truncated only up to A. B's edits and journal records stay
    intact, re-based onto the new backing generation.
  - Journals, add-buffer files and generations are released on save+close, revert or
    discard (and deleted once nothing else holds them).
  - **Fault-injection tests are an M3b gate** (§7): kill and simulated power loss at
    every write/fsync/rename point of save and journal, external rewrites during
    edit and save, typing during save, volume disappearing mid-save.

### 4.3 Saving: `Saver`
`NSFileCoordinator` only coordinates with cooperating clients; atomicity and recovery
come from the save strategy itself (D17). The strategy is picked per save from the
volume/grant capability matrix (M0 spike, §5).

- **Strategy A — clone, patch, replace (preferred).** Works for overwrite-only v1 and
  for insert/delete later.
  1. `clonefile(2)` the original into a staging file on the same volume (instant on
     APFS; the original stays untouched while staging).
  2. Patch the staging file: dirty ranges only for overwrite edits; a streamed
     rewrite for insert/delete. `F_FULLFSYNC` it.
  3. Coordinated write: `replaceItemAt(_:withItemAt:…)` swaps it in atomically.
  - Keeps the speed of small overwrites on 4 GB files, and a crash at any point
    leaves either the old or the new file intact.
  - The swap gives the file a **new inode**: re-key the session in `SessionRegistry`,
    reopen `ByteSource` (the old descriptor still points at the unlinked original),
    and register the new file as a backing generation (§4.1).
  - Hard links break, and metadata must be checked: xattrs, Finder tags, ACLs,
    creation date. All tested in the M0 spike and the Saver round-trip suite.
  - Needs a staging location on the same volume. With a folder grant that's the
    parent directory or `itemReplacementDirectory`; whether a **file-only grant**
    allows either is a question the M0 spike answers.
  - Without a clone-capable volume, step 1 becomes a full copy: needs free space ≈
    file size (check first) and takes time proportional to file size, so it's
    offered only below a size limit; otherwise strategy B.
- **Strategy B — in place with a durable journal (fallback).** For file-only grants
  where staging isn't possible, non-clone volumes with large files, and when the user
  wants inode identity kept (hard links, other apps holding the file open). Overwrite
  edits only; insert/delete on such volumes needs a full rewrite (strategy A with a
  copy) or is refused.
  1. Write the dirty ranges' old bytes plus the target file's identity
     (volume, file ID, size, mtime) to a save journal; `F_FULLFSYNC`.
  2. Write the ranges into the file; `F_FULLFSYNC` the file.
  3. Append an explicit **commit record** to the journal; `F_FULLFSYNC`; then delete
     the journal.
  - On launch: a journal without a commit record → roll the file back from the old
    bytes (after checking identity); with a commit record → just delete it.
  - **Undo after save:** without a clone, before overwriting a range, copy its old
    bytes into the add buffer and remap the pieces — in the current root *and* every
    root in the undo history — that referenced that original range. Otherwise
    undo/revert after a save would restore the new bytes. With a clone, the undo
    history keeps referencing the old generation and nothing needs remapping.
- Optional "keep backup" preference later (both strategies).
- **Insert/delete (M8)** reuses strategy A with a streamed rewrite of the staging
  file instead of a range patch; no separate save path.
- Files without write permission, locked (`uchg`) or root-owned files open read-only
  (D14); "Save As…" is still available.

### 4.4 View: `HexView` (AppKit)
- Custom `NSView` drawing only visible rows with Core Text, using pre-shaped glyphs for
  hex digits and printable ASCII.
- **Virtual scrolling:** window-sized view; a custom scroller maps position to a top
  row index (UInt64). No gigantic document view, no float-precision drift. This is
  the riskiest part of M1 — build it first. Reuse native scrolling behaviour where it
  fits the virtual viewport (an `NSScrollView` with a small proxy document for
  momentum, elastic edges and overlay scrollers, mapped onto the row index), and fall
  back to a fully custom scroller only where that breaks.
- **Measured on real hardware while a search runs:** first paint, scroll hitches
  (frame time, not just average fps) and memory.
- Rows come from the asynchronous prefetch in §4.1; missing pages draw as
  placeholders.
- Columns: offset gutter | hex | text. Bytes per row 8/16/32/auto-fit.
- Shared cursor/selection between columns; keyboard-first navigation (arrows, Page
  Up/Down, Home/End, ⌘↑/⌘↓, Go to offset ⌘L).
- **Typing in the text column (M3a, overwrite mode):** in a single-byte encoding
  (ASCII, Latin-1, EBCDIC) a character overwrites one byte. In UTF-8/UTF-16 a
  character overwrites as many bytes as its encoding needs, starting at the cursor
  (file length unchanged). A character the column's encoding can't represent beeps,
  with a status-bar message.
- Changed (dirty) bytes are highlighted.
- Copy as hex/text of a huge selection is capped (e.g. 64 MB of output) with a
  prompt offering "Save selection to file…" instead.
- **View options (D18)**, in the View menu and the editor toolbar, per editor item,
  with defaults in Preferences:
  - offset base: hex / decimal / both;
  - byte grouping: 1 / 2 / 4 / 8 (with LE/BE display order for groups);
  - text-column encoding: ASCII, Latin-1, UTF-8 (multi-byte sequences drawn across
    their bytes), UTF-16LE/BE, EBCDIC; more can be added later.
- Accessibility is out of scope for now (D19); keep drawing and hit-testing
  separable so `NSAccessibility` can be added later (a baseline VoiceOver proposal
  for M1 was considered and declined on 2026-11-20).

### 4.5 Search: `Searcher`
- Hex bytes (`??` wildcards later), ASCII/UTF-8, UTF-16LE/BE, case-insensitive text.
- Chunked streaming with (pattern length − 1) overlap; memchr on first byte + verify,
  or Boyer–Moore–Horspool. Cancellable `Task` with progress.
- Reads through the uncached sequential path (§4.1), so a full scan doesn't evict
  the view's pages.
- Written against a byte-reading protocol from day one: `ByteSource` in M2, a
  `PieceTable` snapshot from M3a, so the switch is a data-source swap.
- "Find all" stores at most N results (e.g. 100k) and reports "more than N".
- Target: disk-bound speed on 4 GB (a few seconds on internal SSD).

### 4.6 Data inspector
At the cursor: Int/UInt 8/16/32/64 (LE/BE), Float16/32/64, binary, UTF-8/UTF-16
character, Unix time / Mac absolute time / Windows FILETIME. Editable later.

### 4.7 File manager (BrowserKit)

Window layout — one `NSSplitViewController` with three collapsible regions:

```
┌──────────┬──────────────────────┬──────────────────────┬──────────┐
│ Sidebar  │ [tab][tab][+]        │ [tab][+]             │ Preview  │
│ Favorites│ /Users/me/Code       │ /Volumes/Data        │ Quick    │
│ Locations│ name   size  date    │ name   size  date    │ Look +   │
│ Volumes  │ …                    │ …                    │ info     │
├──────────┴──────────────────────┴──────────────────────┴──────────┤
│ F3 View  F4 Edit  F5 Copy  F6 Move  F7 MkDir  F8 Delete  …        │
└───────────────────────────────────────────────────────────────────┘
```

- **Sidebar (left, collapsible):** Finder-like source list — Favorites (user-editable),
  Locations/volumes (mounted, ejectable), later Tags. Clicking navigates the active
  panel. Toggle ⌃⌘S as in Finder.
- **Two panels:** active panel has focus ring/highlight; Tab switches panels (only
  when a browser has focus — inside an editor Tab inserts a tab). Each panel owns its
  own **tab bar** (custom control — the system window tabbing is per-window, not
  per-panel). Each tab: location, back/forward history, sort order, selection. Tabs
  restore on relaunch (D23).
- **File list:** view-based `NSTableView` with columns (name, size, date, kind),
  async directory enumeration so 100k-entry folders don't block, live updates via
  FSEvents, type-to-select, sorting.
- **Selection:** standard macOS multi-select (⇧/⌘-click, ⇧-arrows) is the target of
  F5–F8. No Norton Commander muscle memory beyond the F-keys is required day one;
  NC-style marking (Insert/Space, +/−/`*`) and drive switching are later candidates.
- **Hidden files:** toggle ⌘⇧. (Finder's shortcut) per panel, with a global default
  in Preferences.
- **Preview pane (right, collapsible):** `QLPreviewView` for the selected file plus
  metadata (size, dates, permissions, xattrs). For files Quick Look can't show, offer
  a hex view. BrowserKit doesn't import HexViewKit: it asks a viewer factory
  (protocol in WorkspaceKit, implementation injected by FilerApp). The hex view here
  follows the quick-view rules in §4.8 (read-only `ByteSource`, no session).
- **Norton Commander-style keys + bottom function bar:**
  F3 View (quick view, §4.8), F4 Edit (editor tab; hex only until M9a, then mode by
  file type per §4.10), F5 Copy to other panel, F6 Move/Rename, F7 New folder, F8
  Delete (to Trash; ⇧F8 permanent, with confirmation), F2 Rename, F10/⌘Q quit. Bar
  is clickable and can be hidden.
  - Caveat: by default macOS maps F-keys to media/system functions (brightness,
    Mission Control…), so users need fn+F-key or the system setting "Use F1, F2, etc.
    keys as standard function keys". Every F-key action also gets a ⌘ shortcut and a
    menu item. Check for conflicts with system shortcuts (e.g. F11 Show Desktop).
  - F-keys are routed by focus (§4.8): inside an editor item, F3 may mean "find next"
    rather than "view" — resolved per item via the command registry (§4.11); the
    actual binding is deferred (§9).
- **File operations queue:** copy/move/delete run in a background queue with progress,
  pause/cancel, and conflict resolution (replace / skip / keep both / apply to all).
  Copy via `copyfile(3)` with `COPYFILE_CLONE` (instant APFS clones on same volume)
  and progress callbacks; delete via `FileManager.trashItem`. Cross-volume move is
  copy + delete: delete the source only after the copy is verified complete, and
  report partial failures per item.
- **Sandbox fit:** browsing needs user-granted folders (one-time grant of home folder
  and volumes, stored as bookmarks); copy/move need write access to the destination.
  Quick Look preview and Trash work sandboxed. Known limits even with a home-folder
  grant: TCC still gates Desktop/Documents/Downloads/iCloud Drive, ~/Library and
  other apps' containers need Full Disk Access, each external volume needs its own
  grant, stale bookmarks must be re-requested. These are what the M0 sandbox spike
  measures (§5). Each browser tab holds a `SecurityScope` token for its location
  (§5).

### 4.8 Single main frame: workspace model (D7)

**Prior art.**
- Far Manager / Midnight Commander: viewer, editor and command output are full-frame
  "screens" inside the one console window; Ctrl+O hides/shows the panels over the
  shell, Ctrl+Q turns the inactive panel into a quick view of the file under the
  cursor, F12/Ctrl+Tab switches between open screens.
- Nimble Commander (macOS, open source): internal viewer on F3; an *overlapped*
  terminal shown under the panels that follows the current directory, which can also
  go full-window like a tab.
- ForkLift 4: per-pane tabs; a right Preview Pane that switches between preview/info,
  activities and log; its users asked for a terminal docked at the bottom.
- VS Code / Path Finder: editors as tabs; terminal in a collapsible bottom drawer.

**Model.** Everything that isn't a dialog is a `WorkspaceItem` — Browser, Editor,
QuickView, Terminal, later Compare/Search results. An item can be hosted in any
*slot* of the main frame:

```
┌─────────┬───────────────────┬───────────────────┬─────────┐
│         │ Left panel tabs   │ Right panel tabs  │ Preview │
│ Sidebar │ [Browser][Hex*]   │ [Browser][Term]   │ (follows│
│         │                   │                   │ select.)│
│         ├───────────────────┴───────────────────┤         │
│         │ Bottom drawer: Terminal (follows dir) │         │
├─────────┴───────────────────────────────────────┴─────────┤
│ F-key bar                                                  │
└────────────────────────────────────────────────────────────┘
        + Zoom: any item temporarily fills the whole frame
```

| Slot | What goes there | Notes |
|---|---|---|
| Panel tabs (left/right) | Any item; Browser is the default | Tab bar shows item type icon and dirty dot. Tabs drag between panels. |
| Preview pane (right) | Read-only, follows the selection | Quick Look, metadata, hex view for unknown types. Can be "pinned" to stop following. |
| Bottom drawer | Terminal (later: operations queue, log, search results) | Toggle ⌃\`. Follows the active panel's directory unless detached. |
| Zoom | Any item, full frame | Like Far's Ctrl+O / hiding panels. Toggle and Esc return to the previous layout. |

**Proposed default behaviours** (all configurable later):
- **F3 View** → quick view in the *opposite* panel as a new tab (Far Ctrl+Q style):
  the file list stays visible, moving the cursor updates the view. ⇧F3 opens it in
  the same panel.
- **F4 Edit** → editor tab in the active panel; zoom (⌘⇧↩) for full frame.
- **Terminal** → bottom drawer, plus Ctrl+O full-frame toggle for the
  Far/mc/Nimble muscle memory; can also be opened as a panel tab. Note ⌃O is the
  Cocoa "open line" text binding — when a text editor has focus, Ctrl+O must either
  yield to the text view or the binding is overridden deliberately (deferred, §9).
- **Item switcher** → one shortcut lists every open item across slots (like Far's
  F12 screens list) for jumping between editors/terminals.
- Closing a dirty item, or quitting with dirty items, follows the single close
  workflow (§4): one sheet per dirty session, when its last view closes.
- The full layout (slots, tabs, items, zoom state) is restored on relaunch, each
  location backed by a security-scoped bookmark. Unsaved edits survive a crash via
  the session journal (D15, §4.2).

**QuickView is not an editor.** The F3 quick view (and the preview pane's hex view)
retargets on every cursor move, so it reads through a lightweight read-only
`ByteSource` and never creates an `EditorSession`. If `SessionRegistry` already has a
dirty session for that file, the quick view shows the session's bytes (via a
snapshot) with a marker that the view includes unsaved edits. "Edit" from a quick
view (F4) opens or focuses the real editor item.

**State restoration (D23).** AppKit's restoration APIs:
- Each main window has a `restorationClass` and identifier; its controller encodes
  the `MainFrameLayout` in `encodeRestorableState(with:)`: slots → items (type,
  per-item state, security-scoped bookmark data), active panel, zoom state. Each
  `WorkspaceItem` contributes its own state through the protocol's restoration
  hook. Changes call `invalidateRestorableState()` so AppKit re-encodes them.
- Encoded item state carries a small version number so an item can ignore state
  written by an older build rather than misreading it.
- Merging windows and moving tabs between windows (M11) only change which window
  encodes an item; nothing else is stored separately.
- AppKit restoration follows the system's "Close windows when quitting an app"
  setting and is skipped after the user chooses not to reopen windows. That's
  accepted: a fresh launch opens one window with a Browser tab per panel.
- **Crash recovery is independent (§4.2).** It doesn't rely on restoration: on
  launch, after AppKit has restored (or not restored) windows, any session with an
  unclean journal is reopened as a tab, in its restored tab if one exists, otherwise
  in a new tab of the frontmost window.

**Engineering consequences.**
- `WorkspaceKit`: `WorkspaceItem` protocol (view controller, title, icon, dirty state,
  can-close, state restoration, preferred slot) and a `MainFrameLayout` that owns
  slots and moves items between them. It defines the protocols and factories that let
  kits create each other's items without importing each other (§4).
- Items must tolerate being re-parented (moved between slots) without reloading:
  views are detached/attached, sessions live outside the view hierarchy.
- Keyboard routing: focus belongs to one item at a time; F-keys and panel keys act
  on the focused item's context, resolved through the command registry (§4.11).
- **Terminal and the sandbox:** SwiftTerm (MIT) is a mature embeddable VT100/xterm
  emulator for Swift on macOS. But a shell started from a sandboxed app inherits
  the sandbox, while users expect an unrestricted shell like Terminal.app. So
  the terminal is a **Direct-only** feature; the App Store build omits it or
  offers "Open in Terminal" instead.

### 4.9 Multiple main windows & merging (D8)

- Each main window is a self-contained main frame (§4.8). ⌘N opens a new one with a
  single Browser tab per panel.
- **Merge All Windows** (Window menu): into the frontmost window,
  - left-panel tabs of every other window → appended to the left panel, in window
    order; right-panel tabs → right panel;
  - bottom-drawer items (terminals) → appended to the drawer (drawer supports tabs);
  - preview pane: target window's stays; others are discarded (it's derived state);
  - zoom is cleared; the merged windows close.
- Also: drag a tab between windows; "Move Tab to New Window" as the inverse.
- Not the system `NSWindow` tabbing (`mergeAllWindows:`) — that merges whole
  windows as tabs, not per-panel tabs. Disable automatic window tabbing.
- **One session per file, app-wide.** A `SessionRegistry` owns `EditorSession`s
  keyed by file identity (volume + file ID, so renames/moves don't break it).
  File IDs aren't stable on every file system (SMB, FAT, exFAT) — fall back to the
  resolved path there. The key is updated when a save replaces the inode (§4.3).
  Opening a file that's already open focuses its tab, or offers a second view of
  the *same* session (shared undo, edits, dirty state). This keeps merges and
  cross-window drags conflict-free — two windows can never hold diverging unsaved
  edits to one file.
- **Several text-mode views of one session** share one `NSTextContentStorage`, each
  with its own `NSTextLayoutManager` (TextKit 2 supports this), so the TextKit sync
  layer (§4.10) still has exactly one text copy per session. If that proves fragile,
  fall back to allowing one text-mode view per session (other views stay in hex).
  Hex views of the same session are independent and cheap.
- State restoration saves all windows and their slots (D23); merge is just moving
  items between `MainFrameLayout`s, so it reuses the same re-parenting path as moving
  a tab between panels.
- Guard rail: an M0 smoke test opens two main windows, so the "no single-window
  assumption" rule is exercised long before M11.

### 4.10 Editor modes & in-file search (D12)

One editor item per file (one `EditorSession`), with a mode switcher in its tab
toolbar: **Hex · Text · Markdown** (shortcuts deferred — ⌘1/2/3 collide with
Finder's ⌘1–4 view modes in the browser; §9). F4 opens the mode matching the file's
type (`UTType`): Markdown → Markdown, other text types → Text, everything else → Hex.
Switching modes keeps edits, undo history, cursor/selection (mapped between byte and
character offsets) and dirty state.

**Single source of truth.** The `PieceTable` holds the file's bytes in every mode.
Text edits arrive from the text view as "replace character range with string",
are encoded (UTF-8/UTF-16/Latin-1…, detected on open, switchable) and applied to the
piece table as byte-range replacements. One undo stack, one save path, so hex and
text edits interleave safely.

**Syncing with TextKit.** `NSTextView` keeps its own `NSTextStorage`, so in text
modes there are really two copies kept in lockstep:
- The text view's own undo manager is disabled; its edits are intercepted
  (`shouldChangeText…`) and recorded in `UndoStack`. Undo/redo swaps piece-table
  roots and applies the corresponding change to the text storage.
- Marked (uncommitted IME) text is not forwarded to the piece table until it is
  committed.
- Hex-mode edits made while a text view exists are pushed into the text storage
  (or the text view is rebuilt on mode switch — pick whichever profiles better).
- One text storage per session, shared by all its text-mode views (§4.9).

**Unencodable input.** Typing or pasting a character the file's encoding can't
represent (an emoji into a Latin-1 file) leaves no bytes to write. The edit is
rejected with a beep and a status-bar message offering **"Convert to UTF-8…"**: a
whole-file re-encode, available because insert/delete (M8) lands first, applied as
one undo step. The hex text column follows the rules in §4.4.

**Plain text mode**
- Files up to a size threshold (start at **16 MB**, tune by profiling): TextKit 2
  `NSTextView` — native editing, IME, spell check off by default, line numbers,
  soft wrap toggle, monospaced font, line endings (LF/CRLF/CR) shown and convertible.
  Text mode has its own memory budget (§3), measured at the threshold.
  - TextKit 2 has known rough edges (line numbers via `NSRulerView`,
    large-document performance, scroll jumping). Spike before M9a, keeping
    `NSTextView`; TextKit 1 is the fallback. The spike must prove:
    - IME: marked text commit *and* cancel reach the piece table correctly (only on
      commit);
    - byte-preserving edits: untouched bytes, including invalid ones, survive an
      edit + save byte-for-byte;
    - undo across mode switches (text edit → hex edit → undo both);
    - the line-number implementation doesn't touch `layoutManager` or anything else
      that silently switches the view into TextKit 1 compatibility mode.
  - The text size limit is profiled on its own (memory and typing latency at the
    threshold), separately from the spike's correctness checks.
  - Line-ending conversion rewrites the whole file → needs insert/delete (M8).
- Above the threshold: **large-text viewer** — custom virtualized view over the
  piece table, built on a snapshot (§4.2), same scrolling approach as HexView.
  Read-only at first; editing large text is a later item.
  - **Sparse line index.** A 4 GB log at ~80 bytes/line has ~50M lines; a full
    `UInt64` offset index would be ~400 MB. Instead, store a checkpoint (byte offset,
    line number) every 64 KB or every N lines, built in the background; to reach a
    line, scan forward from the nearest checkpoint.
  - **Scan in code units, not bytes.** The indexer looks for the newline in the
    file's encoding: one byte for UTF-8/Latin-1, a two-byte unit aligned to the
    encoding for UTF-16LE/BE (a byte-level `0x0A` scan would split characters).
- **Invalid bytes, lossless:** undecodable bytes are shown as placeholders, and the
  decoder keeps a map from each placeholder back to its original bytes. Saving never
  rewrites bytes you didn't touch (no silent re-encoding). This mapping is a real
  piece of work, not a rendering detail.
- Encoding detection: BOM first, then UTF-8 validity, then
  `NSString.stringEncoding(for:…)` heuristics, Latin-1 as the last resort.

**Markdown mode**
- Source editing (same TextKit 2 view) with syntax highlighting, plus a rendered
  preview: split side-by-side or toggle (⌘⇧P). Parsed with Apple's `swift-markdown`;
  preview rendered in the same item, never a separate window (D7).
- **To decide:** preview renderer (`WKWebView` with generated HTML vs.
  `AttributedString` in a text view) and source highlighter (from the
  `swift-markdown` AST vs. a dedicated highlighter). Relative image links need
  sandbox access to sibling files (ask for the parent folder); remote images need the
  `com.apple.security.network.client` entitlement or are blocked by default.
- Size limit lower than plain text (a few MB) since preview re-renders on edits
  (debounced, incremental where possible).

**Find & replace inside the edited file (all modes)**
- ⌘F opens an inline find bar at the top of the editor item (not a window/panel);
  ⌘G / ⇧⌘G next/previous, ⌥⌘F replace, "Replace All".
- Hex mode: hex-byte or text patterns (§4.5), searching the whole file via
  `Searcher` with progress. Replace arrives with M9a, after insert/delete (M8), so
  replacement can be any length from the start. The first usable hex version (M3b)
  has find only.
- Text & Markdown modes: text, case-sensitive / whole word / regex, with match count
  and highlight-all. Regex is limited to files under the text-mode threshold;
  large-text viewer uses `Searcher` (plain text, no regex).
- Replace All is one undo step, and respects the piece-count bound (§4.2).
