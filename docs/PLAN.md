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
