# Twin Panes — Plan

Status: draft v0.27 (2026-11-24). Living document; requirements will keep growing.
Open and deferred questions are collected in §9.

## 1. Goal

A native macOS file manager for Apple Silicon (arm64 only), intended as a ForkLift
replacement. The **first module** — and the primary driver — is a binary file
viewer/editor that opens, inspects, searches and edits files up to 4 GB. Offsets are
64-bit throughout, so 4 GB is the tested target, not a hard cap.

## 2. Decisions so far

| # | Decision | Implication |
|---|---|---|
| D1 | Twin Panes is a file manager; the hex editor is its first module | Engine and viewer are separate frameworks the file-manager shell embeds. The hex editor ships first, as a tab in the main frame (D7). |
| D2 | Support current macOS + 2 previous → **macOS 15 Sequoia minimum** (macOS 27 is current; supported: 15, 26, 27). Raised from macOS 14 on 2026-11-20 because GitHub retired its hosted macOS 14 runners on 2026-11-02 | `@Observable`, modern Swift concurrency, SwiftUI 6 and `Synchronization.Mutex` are available. CI runs on GitHub-hosted runners for the oldest and newest supported releases, no self-hosted machine (§7). Raise the target as new releases ship and as hosted runners retire. |
| D3 | App Store is a possible future target | Build **sandbox-compatible from day one** (see §5). Anything that can't ship sandboxed is marked "Direct only". The M0 sandbox spike covers both browsing and the editor's write path, and its capability matrix drives the save policy and the App Store decision. |
| D4 | Overwrite-only editing is enough for the first usable version | Insert/delete stays a later milestone; the piece table still supports it so nothing is redesigned later. |
| D5 | Write our own engine (no Hex Fiend dependency) | Hex Fiend remains a design reference only. |
| D6 | File-manager core features: 2 panels, multiple tabs per panel, Norton Commander-style F-key hotkeys, hidden files, Finder-like collapsible left sidebar, collapsible right preview pane | See §4.7. |
| D7 | **Single main frame.** Viewing, editing, previewing, terminals and similar features never open new windows; they live inside the main window. Dialogs (sheets/alerts/modal panels) stay dialogs. | See §4.8. The editor uses a custom `EditorSession` instead of `NSDocument` (rationale in §4). |
| D8 | Multiple main windows are allowed but low priority (tabs cover most needs). Requires **Merge All Windows**: left-panel tabs from all windows merge into the target's left panel, right into right. | See §4.9. Data model must not assume one window. |
| D9 | Keep §4.8 defaults for now: F3 → quick view in the opposite panel, F4 → editor tab in the active panel (mode picked by file type, §4.10; hex only until M9a), terminal → bottom drawer + Ctrl+O | Revisit once in daily use; all key bindings stay configurable (command registry, §4.11). |
| D10 | Build order: hex editor to its first usable version (M3b), then the browser, then back to hex polish. A basic real browser (M1b) comes right after the read-only viewer, so every later milestone works on files you navigate to | See §6. M1b was added 2026-11-21: without it the only ways to real files were File › Open, drops and Open With. |
| D11 | Bundle ID `io.github.edudar.twinpanes` (was `io.github.edudar.filer` until 2026-11-20) | Fixed once on the App Store. The app's name is Twin Panes (D25). |
| D12 | The editor has three modes — **Hex, Plain text, Markdown** — with find/replace inside the file being edited in every mode | See §4.10. Text editing needs insert/delete, so insert/delete (M8) must land before the text modes (M9a). |
| D13 | Public GitHub repo `edudar/twin-panes` (was `edudar/filer` until 2026-11-20), licence **Apache-2.0** | Free GitHub Actions minutes on macOS runners. Apache-2.0 is App Store–compatible. Never commit signing secrets — use GitHub encrypted secrets for CI signing later. |
| D14 | The editor opens **regular files only** | No block devices, no packages as files. Files without write permission, locked (`uchg`) or root-owned open read-only; no privileged save. |
| D15 | **Unsaved edits survive a crash**: the add buffer is always a file, and edit operations are journaled and replayed on relaunch | See §4.2. Lands in M3c, after sessions (M3b). A recovered session has its edits but no undo history. The guarantee holds only where the bytes the edits sit on are durably kept (a clone or private copy); elsewhere it is narrowed and the UI says so (§4.1). |
| D16 | **APFS clone at the first edit** protects unsaved edits from external modification (was "at open" until 2026-11-22; viewing never writes) | See §4.1; lands in M3c. Where cloning isn't possible (non-APFS, or a volume the sandbox can't write to), fall back to detect-and-warn. |
| D17 | **Two save strategies, both crash-safe.** Preferred: clone the original to a staging file, patch the staging file, coordinated replace. Fallback where replacement isn't possible or inode identity must be kept: in-place patch with a durable journal and an explicit commit record. | See §4.3. Which strategy applies is decided per volume and grant type from the M0 spike's capability matrix. |
| D18 | Hex display settings (offset base, byte grouping, text-column encoding) are **user-selectable view options** | See §4.4. |
| D19 | Out of scope for now: **accessibility** (VoiceOver for custom views) and **localization**. Hex replace arrives with M9a, after insert/delete, so it is any-length from the start | Revisit after the daily-driver milestones. |
| D20 | **Single-package layout:** one local Swift package holds every library target; a thin Xcode project holds only the app target (Info.plist, entitlements, document types, assets, signing). No XcodeGen. | See §4. Module dependencies are enforced by `Package.swift` and point strictly down (§4); `swift test` runs all logic tests; UI tests go through `xcodebuild`. |
| D21 | **Command registry as a catalog:** every action is a command with a stable ID (used by bindings, the F-key bar and the item switcher) that maps to an AppKit action. Menus send actions through the responder chain and validate with AppKit menu validation; the registry intercepts only context-dependent keys | See §4.11. Built in M0 with default bindings; user-editable in M10. |
| D22 | **Testing frameworks:** swift-testing for logic tests; XCTest for `measure` performance tests and UI tests | See §7. |
| D23 | **State restoration** uses AppKit's restoration APIs (`NSWindowRestoration`, `encodeRestorableState(with:)` / `restoreState(with:)`) for windows, slots and tabs; crash recovery stays separate and independently durable | See §4.8. Follows the system's "Close windows when quitting an app" setting. Lands in M5, multi-window in M11. |
| D24 | **One app icon: Twin Panes, Navy + coral**, as an Icon Composer `.icon` with default, dark, clear and tinted styles. Byte Panes and the Midnight mint palette stay as reference designs; no in-app icon picker | See §4.12. macOS can't switch an app's icon outside a running session, so a picker isn't worth it. Shipped in M0. |
| D25 | **The app is named Twin Panes** (was Filer until 2026-11-20) | Display and product name "Twin Panes"; project, target and scheme `TwinPanes`; package `TwinPanesKit`; core module `TwinPanesCore`; bundle ID per D11. |
| D26 | **Piece tree = persistent AVL with join/split** (M3a, 2026-11-22) | Immutable `final class` nodes caching height, length and piece count; every edit is split + join, copying O(log n) nodes, so a snapshot or undo entry is an old root. Adjacent pieces that continue each other in one source merge. Chosen over a treap (random shape, harder to replay) and a B-tree (more code). See §4.2. |
| D27 | **The add buffer is a file from M3a on** | An append-only temp file with the open partial page and an LRU of full pages in memory; bytes never change once written, so snapshots read it from any thread. M3c moves it into the session folder. See §4.2. |
| D28 | **Edit model in TwinPanesCore, undo held by the tab** | `EditBuffer` (original + add buffer + current tree) hands out `Sendable` `EditSnapshot`s that are `ByteReading`; the `UndoStack` sits on the editor item because entries carry its selection. Undo/Redo are ordinary `undo:`/`redo:` actions on the editor's view controller, not `NSUndoManager`. M3b's `EditorSession` wraps these. |
| D29 | **Closing an edited tab before saving exists** | `WorkspaceItem.canSave` (default true); when false the close sheet offers only Discard Changes and Cancel. Since M3b the hex editor returns false only for read-only files. |
| D30 | **`EditorSession` owns a file; `SessionRegistry` keeps one per file** (M3b) | The session holds the `EditBuffer`, the `UndoStack` (moved off the tab), `savedTree`, the file's `FileIdentity`, `AccessMode` and scope, and notifies observers; tabs keep presentation. The registry keys sessions by device and inode, holds them weakly, and follows a session to its new inode after a save; opening an open file brings its tab forward. |
| D31 | **A save writes where the saved and current versions differ** (M3b) | `SavePlan` walks both piece trees side by side and writes every stretch taken from a different source or offset; that covers undone edits (undo after a save restores the original) and skips edits already saved. The whole file is written when the disk no longer matches the saved identity, size and mtime, or the length changed. Planned as the union of modified ranges; the exact comparison is as cheap. |
| D32 | **Saving: strategy A behind a `FileSystem` seam, off the main actor, one at a time** (M3b) | `Saver` clones (or copies, after a free-space check) into `itemReplacementDirectory`, patches, `F_FULLFSYNC`s and swaps the file in with a coordinated replace. Every write goes through `FileSystem`, for M3c's fault injection. Saves run on a dispatch queue over a snapshot; edits typed meanwhile stay unsaved (`savedTree` = the version written). A save asked for while one runs is queued once. Hard-linked files get Save As until M3c's strategy B. |
| D33 | **No rebasing after a save** (M3b) | Pieces keep pointing at the file as opened: after a replace the session reads the old inode through its open descriptor, so undo across saves needs no remapping. M3c moves the original pieces onto a clone made at the first edit. Save As moves the session (URL, scope, identity, access) to the new file and keeps its undo history. |
| D34 | **Session folder and clone at the first edit; a journal of tree changes** (M3c) | `Sessions/<id>/` holds the manifest, the clone the original pieces read, the add buffer and `journal.bin`. Viewing writes nothing. Journal records are `replace(range, pieces)` for whatever the tree comparison finds changed (edits, undo, redo, revert alike), `saved(n)` and `closed`, framed with a CRC32C. Recovery replays over the clone; the tab comes back dirty without undo history. |
| D35 | **Strategy B for hard-linked files, needing the clone** (M3c) | Old bytes and the file's identity go to a save journal, the ranges are written in place, a commit mark is appended; recovery rolls back an uncommitted one. Whole-file plans and narrowed sessions still get Save As. |
| D36 | **Outside changes by vnode watch, our saves told apart by identity** (M3c) | A `DispatchSource` on the file instead of `NSFilePresenter` (which only hears coordinated writes); an event leaving the file as last saved is ignored. Clean tabs reload; dirty ones ask Keep Mine / Reload / Save As. |
| D37 | **Narrowed sessions keep no journal, for now** (M3c) | Replaying against the live file after a save would bring back saved bytes where an undo had restored the opened ones. Until the external-volume spike, a session without a clone isn't recoverable and says so. |
| D38 | **Folders list off the main actor in growing batches** (M4) | `FolderLister` enumerates with cheap keys only (Finder's type descriptions made 100k entries take 7.5 s, now 0.73 s); kind and icon come from the name's `UTType`, cached per type. Batches start at 500 entries and grow to 20,000, and every navigation supersedes the last listing. See docs/plans/M4.md, D-a, D-b. |
| D39 | **The folder model is a `Sendable` value; 100k-row work never runs on the main actor** (M4) | `FolderListing` sorts (`ListingOrder`, folders on top), filters hidden entries, merges batches and live updates, and works out a live update's `RowChanges` and the selection's rows. Past 500 entries a run happens off the main actor; the main actor only applies the result. Old listings are freed off it too. |
| D40 | **Live updates by FSEvents, row by row when small** (M4) | `FolderWatcher` streams one folder's direct changes (paths by `realpath`); changed names are read again and merged; dropped events or over 1,000 names mean one full re-list at a time, never during the listing. Up to 100 rows change in place; the folder going away sends the tab to the nearest folder above. |
| D41 | **Per-tab history, hidden files and sort order** (M4) | Back/Forward (⌘[ ⌘]) with the selection kept; ⇧⌘. filters without listing again; header clicks sort. All outlive navigation; tab restore keeps them in M5. |
| D42 | **Access asks for as much as the user means** (M4) | The prompt asks for a whole external volume, the home folder, or a grant that stopped resolving (kept as lost, with its last path). Recent files that moved stay in the menu and offer to find them. A tab keeps its access token while it stays under one grant. |
| D43 | **Path bar, packages** (M4) | A clickable `NSPathControl` (items built with the cached folder icon) that ⇧⌘G turns into the path field. Packages list as files, as in Finder; Show Package Contents (⌥⌘↓) enters one (§9 question 2). |
| D44 | **Row drawing is cached; icon lookups never run on the main actor** (M4 performance pass) | Each icon is drawn once into a bitmap per type (or app path), screen scale and appearance, on the cache's own queue; until it's ready a cell has none. Each cell keeps its laid-out text line until its text, width or style changes, and takes its colour when drawn. The rows on screen are refreshed in place, and each row draws its cells into one layer. Kind is stored with each entry. See docs/plans/M4.md, "Performance pass". |
| D45 | **Two panels, always** (M5) | Every window shows a browser in each panel, as halves at first. A panel's only browser tab can't be closed or moved out; any other last tab leaves a browser at the other panel's folder. The status line takes only the messages of the item in front. See docs/plans/M5.md, D-a. |
| D46 | **The active panel follows focus** (M5) | Clicking or tabbing into a panel activates it. Tab and ⇧Tab switch panels while a file list has focus; tabs move by dragging or Window › Move Tab to Other Panel, as the same item. See docs/plans/M5.md, D-b. |
| D47 | **Restoration: versioned state through AppKit** (M5) | Each window keeps a `WindowState` (tabs, selection, active panel, zoom, divider, sidebar) as one JSON value in its restorable state; items save versioned `ItemState`, and kinds or versions a build doesn't know are skipped. Crash recovery runs before restoration, so a restored editor tab claims its recovered session (`LaunchRecovery`). Smoke and bench runs never read or write saved windows. See docs/plans/M5.md, D-c. |
| D48 | **The sidebar** (M5) | Favorites as paths in user defaults (access from folder grants, D42) and Locations: Home, the mounted volumes (kept current by NSWorkspace's notifications) and the Trash, greyed out unless the app can list `~/.Trash` (Full Disk Access), checked again whenever the app becomes active; ejectable volumes get an eject button, which the sandbox allows. ⌃⌘S toggles it; edits show in every window. See docs/plans/M5.md, D-d. |
| D49 | **Path completion** (M5) | Tab in the path field completes as a shell does (§4.7). Names are read and matched off the main actor and cached while the field is open; a second Tab opens AppKit's completion list. See docs/plans/M5.md, D-e. |

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

The app target sits at the repo root; every library module is a sibling folder under
`TwinPanesKit/Sources/`. Modules aren't nested in each other; how they depend on
each other is in the second table. The milestone is where a module gets real
content; the `M0` rows exist now.

**Modules**

| Module | Folder | Milestone | Contents |
|---|---|---|---|
| app target | `TwinPanes/` | M0 | entry point, app delegate, main menu, command catalog and default bindings, recent files, window restoration, placeholder items, smoke test (`SmokeChild`), app icon. Later: preferences, and wiring the kits together (e.g. the hex-view factory for BrowserKit's preview pane) |
| TwinPanesCore | `TwinPanesKit/Sources/TwinPanesCore` | M0: module only | the UI-free engine, no AppKit imports (components below) |
| WorkspaceKit | `TwinPanesKit/Sources/WorkspaceKit` | M0, M5 | the single main frame, independent of item types: `WorkspaceItem`, `MainFrameLayout` and its view controller, main window and controller, tab bar (with tab dragging, M5), `WindowState` and `ItemRestorer` (M5), the hosted sidebar (M5), close workflow, workspace registry, command registry and dispatcher, focus chain, menu bindings (§4.8, §4.11) |
| HexViewKit | `TwinPanesKit/Sources/HexViewKit` | M1 | virtualized hex/text view, selection, inspector UI |
| EditorKit | `TwinPanesKit/Sources/EditorKit` | M1, M5 | the editor item: mode switcher, find bar, editor state restoration (M5); hosts the mode views over one `EditorSession` |
| BrowserKit | `TwinPanesKit/Sources/BrowserKit` | M1b, M4, M5 | the browser tab: async listing, sorting, hidden files, history, live updates, path bar, folder access (M1b, M4); the sidebar, path completion and the tab's saved state (M5); later (M6–M7) operations queue, preview pane |
| TextEditKit | `TwinPanesKit/Sources/TextEditKit` | M9 | plain-text and Markdown modes, large-text viewer |
| SandboxProbe | `TwinPanesKit/Sources/SandboxProbe` | M0, M3c | Foundation-only probes for the sandbox spike (§5); only the app's Debug menu uses it. Stays until the M3c volume checks (external drives) are done, then goes away with that menu |

`EditorKit`, `HexViewKit` and `TextEditKit` are empty modules in M0; they exist so
the dependency rules below are enforced by `Package.swift` from the first commit.
`BrowserKit` is added in M1b.

**Dependencies** (what each module may import; enforced by `Package.swift`)

| Module | Imports |
|---|---|
| TwinPanesCore | Foundation only |
| WorkspaceKit | TwinPanesCore |
| HexViewKit, TextEditKit, BrowserKit | WorkspaceKit, TwinPanesCore |
| EditorKit | HexViewKit, TextEditKit, WorkspaceKit, TwinPanesCore |
| SandboxProbe | Foundation only |
| app target | links WorkspaceKit, EditorKit, BrowserKit and SandboxProbe; imports those and TwinPanesCore (which comes with them) |

No module imports one at its own level: HexViewKit, TextEditKit and BrowserKit never
import each other. Anything that crosses kits (the preview pane's hex view, F4
opening an editor from the browser) goes through a protocol or factory defined in
`WorkspaceKit` and supplied by the app target.

**TwinPanesCore components** (planned; all inside the one module)

| Component | Milestone | Role |
|---|---|---|
| `ByteSource` | M1 | read-only file access: pread + LRU page cache, plus an uncached sequential read path (§4.1) |
| `Searcher` | M2 | streaming hex/text search, cancellable, with progress (§4.5) |
| `Inspector` | M2 | decode bytes at the cursor: ints, floats, dates, text (§4.6) |
| `PieceTree` | M3a | the edit model's pieces over the original file and the add-buffer file; persistent AVL tree (§4.2, D26) |
| `AddBuffer` | M3a | append-only file of typed and pasted bytes, with in-memory recent pages (D27) |
| `EditBuffer`, `EditSnapshot` | M3a | one file's original + add buffer + current tree; immutable `Sendable` snapshots that implement `ByteReading` (D28) |
| `UndoStack` | M3a | stack of earlier piece-tree roots plus selection, with coalescing |
| `FileIdentity`, `AccessMode` | M3b | which file (device, inode) and how it looked (size, mtime, links); writable or read-only with the reason |
| `EditorSession`, `SessionRegistry` | M3b, M3c | per-file session: undo, saved version, save, Save As, revert, file identity, access, security scope (M3b, D30); backing generations, crash journal (M3c) |
| `SavePlan` | M3b | the ranges a save writes, or the whole file (D31) |
| `Saver`, `FileSystem`, `SaveJournal` | M3b, M3c | save strategy A (clone, patch, replace) and Save As in M3b, B (in place + save journal) in M3c (§4.3, D32, D35); the saver and journal write through the `FileSystem` seam |
| `SessionFolder`, `SessionJournal`, `JournalFormat` | M3c | the session's folder and manifest, its operation journal and its format and replay (D34) |
| `FileWatcher` | M3c | the vnode watch behind outside-change handling (D36) |
| `DirectoryReader`, `FolderLister` | M1b, M4 | one folder's entries: synchronous (M1b), then off the main actor in growing batches with kinds by type (D38) |
| `FolderListing`, `ListingOrder`, `RowChanges` | M4 | a folder's sorted, filtered entries; live updates and the table's row changes (D39) |
| `FolderWatcher` | M4 | FSEvents on one folder, coalesced into changed names, a re-list or folder-gone (D40) |
| `FolderGrants`, `BookmarkStore`, `SecurityScope` | M1b, M4 | granted folders and recent files as app-scoped bookmarks (lost ones kept with their path, D42) and reference-counted sandbox scope tokens (§5) |
| `GapMeter`, `StallLimit` | M4 | main-thread CPU-time heartbeat meter and machine-scaled stall limit for smoke checks |
| `Favorites`, `MountedVolumes` | M5 | the sidebar's favorite folders (paths in user defaults) and the volumes Finder would show (D48) |
| `PathCompletion`, `CompletionNames` | M5 | shell-style completion rules, and one folder's names read off the main actor for them (D49) |
| `LaunchRecovery` | M5 | holds recovered sessions until restored tabs claim them (D47) |

**BrowserKit components** (M1b, M4, M5)

| Component | Milestone | Role |
|---|---|---|
| `BrowserItem` (`+History`, `+Live`, `+Restoring`) | M1b, M4, M5 | folder tab `WorkspaceItem`, back/forward history, async listing and live-update pipeline, saved state (M5) |
| `BrowserViewController` (`+PathBar`, `+Completion`) | M1b, M4, M5 | file list controller, path bar / path field (⇧⌘G) with Tab completion (M5), access prompt |
| `SidebarViewController` (`+Editing`), `VolumeWatcher` | M5 | the sidebar's Favorites and Locations, editing favorites, live volumes and ejecting (D48) |
| `FileListTable`, `IconCache` | M1b, M4 | striped `NSTableView`, cached icon bitmaps (dark/light, lazy custom icons) and text-layout cells |
| `AccessRequest` | M4 | sandbox access prompt targeting (volume, home folder, or lost grant) |
| `StepTiming`, `StepRecorder` | M4 | main-actor step timing for smoke-test stall diagnostics |

- **Project layout (D20):**

  | Path | What |
  |---|---|
  | `TwinPanes.xcodeproj` | the thin app target, scheme `TwinPanes`; links the package's `WorkspaceKit`, `EditorKit`, `BrowserKit` and `SandboxProbe` products |
  | `TwinPanes/` | app sources and `AppIcon.icon`; a synchronized folder, so new files need no project edit |
  | `Config/` | `Project.xcconfig`, `TwinPanes.xcconfig` (build settings), `TwinPanes.entitlements` |
  | `TwinPanesKit/` | the Swift package: every library target under `Sources/`, tests under `Tests/` |
  | `docs/` | this plan, the sandbox spike runbook, the icon preview |

  The package lives in its own folder so it never encloses the project that uses it
  (Xcode mishandles a local package that contains its own client project). No
  XcodeGen. `swift test --package-path TwinPanesKit` covers every target that has
  logic worth testing.
- The `WorkspaceItem` protocol (§4.8) is how the editor, viewers and terminal are
  hosted in panel tabs, the preview pane or the bottom drawer. Defining it now
  costs little and keeps the editor kits from depending on app-level code.
- **No `NSDocument`, but a document lifecycle.** `NSDocument` does support several
  window controllers, so "one window per document" isn't the reason. The reasons are
  that its views are window controllers, while ours are tabs embedded in file-manager
  panes that move between slots and windows, and that its save machinery (autosave
  in place, versions, safe-save) can't be steered into the save strategies of §4.3
  for 4 GB files. Instead an `EditorSession` (TwinPanesCore, Foundation only) owns the
  file and the edit history: `ByteSource` + `PieceTable`, undo, dirty state,
  save/revert, and adopts `NSFilePresenter` + `NSFileCoordinator` for
  external-change detection and coordinated writes. **Tabs own presentation**:
  selection, scroll position, mode, view options.
- **One close workflow** for closing a tab, closing a window and quitting. A dirty
  session prompts (as a sheet on the main window) exactly once, when its *last* view
  is about to close or the app quits. Quitting uses
  `applicationShouldTerminate(_:)` → `.terminateLater`, walks the dirty sessions one
  sheet at a time, then `reply(toApplicationShouldTerminate:)`. Once a tab's close is
  agreed, or its window closes, the item gets `willClose()` to stop background work
  (the hex editor cancels its search there).
- **Open With without NSDocument (M1):** declare `CFBundleDocumentTypes` for
  `public.data` with `LSHandlerRank = Alternate` (so Twin Panes never becomes the default
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
- **Evicted iCloud files.** A file evicted to the cloud (`SF_DATALESS` in `st_flags`)
  downloads on its first read, which can take minutes for a large file. Check the flag
  at open, show "Downloading from iCloud…" with progress instead of placeholders that
  never fill, and start the recovery clone (below) only once the file is local. Seen in
  the M0 spike: such a file reads and saves fine with a file grant alone.
- **Uncached sequential path.** Searcher and Saver don't go through the LRU (a 4 GB
  scan would evict everything the view needs). They use large sequential `pread`s on
  a descriptor with `F_NOCACHE` set and no caching on our side.
- Not mmap by default: if another process truncates the file, touching the mapping
  raises SIGBUS and crashes the app; pread returns a short read we can handle.
  **As built (after the M0–M2 review):** `cachedBytes` returns all of a range or nil,
  and `prefetch` reports `.truncated`; the hex view shows placeholders, reports the
  error once and doesn't retry that range until it scrolls or reloads (the same for any
  persistent read error). A newer prefetch makes queued older ones stop, so on slow
  volumes the visible rows don't wait behind rows already scrolled past.
- Watch the file through the session's `NSFilePresenter` (plus
  `DispatchSource.makeFileSystemObjectSource` as a fallback) to detect external
  modification/deletion.
- **Our own writes are not external changes.** Saves go through an
  `NSFileCoordinator` created with the session's presenter (`filePresenter:`), so
  the presenter isn't notified of its own write. The DispatchSource fallback compares
  size and mtime against what the save just wrote before raising anything.
- **External changes with unsaved edits.** Pieces reference ranges of the original
  file; if another process rewrites it, unsaved edits silently sit on top of
  different bytes. **(D16)** `clonefile(2)` the original at the first edit (instant, no
  extra space until it diverges; viewing never writes, and a clean session just reloads
  on a change; decided 2026-11-22, docs/plans/M3c.md) and have original-file pieces
  reference the clone.
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
    - The boot volume was checked in the M0 spike. The M3c spike checks external
      APFS, HFS+ and exFAT; SMB and other network volumes wait for M13+.
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
- **Add buffer is always a file**, in the session's directory from M3c, read through
  the same page cache as the original. Pasting or inserting a 1 GB blob never lives in
  RAM, and the same file is what crash recovery replays against. No in-memory phase,
  no spill threshold.
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
- **As built (M3a):** `PieceTree` is a join-based AVL tree (D26); `replacing(_:with:)`
  is split, split, join, and overwrite/insert/delete are one line each on top of it.
  A piece that continues its left or right neighbour in the same source merges into
  it, so sequential typing stays one piece and deleting an insert rejoins the
  original. `AddBuffer` (D27) is an append-only file in its own temp folder, deleted
  with the buffer; the partial last page and a 64-page LRU stay in memory.
  `EditBuffer` holds the original `ByteSource`, the add buffer and the current tree;
  `EditSnapshot` maps every read (cached, blocking, uncached sequential, prefetch,
  `modifiedRanges`) through the pieces. Undo entries hold the tree and selection from
  before and after an edit; the editor coalesces typing that continues at the cursor
  in the same column within 2 s, and a tab is clean again when undo reaches the tree
  it opened with. Fuzz tests: random splits/joins, random edits with snapshots, random
  overwrites through every read path, random undo/redo against the full history.
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
  - **Fault-injection tests are an M3c gate** (§7): kill and simulated power loss at
    every write/fsync/rename point of save and journal, external rewrites during
    edit and save, typing during save, volume disappearing mid-save.
- **As built (M3c):** D34. The clone is made at the first edit after a
  check that the file is still as opened (else a reload first); `EditBuffer.attach`
  switches the original and add buffer once. Records are written at once through the
  `FileSystem` seam; `F_FULLFSYNC` of the add buffer then the journal runs within 1 s
  and at each save and close. The save race needs no truncation: `saved(n)` names the
  record count behind the version written. Launch sweeps the sessions root, deleting
  closed folders and reopening the rest as tabs ("Recovered unsaved changes"); a torn
  journal tail is cut off and journaling goes on in the same folder. Saves rewrite the
  manifest so a recovered session saves against what was saved last. Narrowed sessions
  journal nothing (D37). The fault-injection gate (§7) runs on real files through a
  crashing `FileSystem` wrapper: a kill or a power loss at every operation of strategies
  A and B leaves the old or new contents after recovery's rollback, and a crashed
  session recovers a state it really had (docs/plans/M3c.md, D-g as built; the add
  buffer's own power loss isn't simulated). M3c closed without iCloud dataless files
  and a crash smoke test with a child process; both are in §9 ("From M3c").

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
    and register the new file as a backing generation (§4.1). Bookmarks to the file
    (recents, restoration) go stale after the swap and resolve by path: recreate them
    after each save (seen in the M0 spike).
  - Metadata must be checked: xattrs, Finder tags, ACLs, creation date. The M0 spike
    found mode, xattrs, tags and creation date kept on the boot volume; the Saver
    round-trip suite keeps checking them.
  - **Not for hard-linked files** (`st_nlink` > 1): the swap would break the link, and
    the M0 spike found the sandbox refuses the replace anyway. Those use strategy B.
  - Needs a staging location on the same volume: `itemReplacementDirectory`, which the
    M0 spike found works with a file-only grant as well as a folder grant. A file-only
    grant can't create files in the parent directory.
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
- **As built (M3b):** strategy A only (D32). `EditorSession.save()` plans with
  `SavePlan` (D31), runs `Saver` on a dispatch queue over a snapshot and, when it lands,
  sets `savedTree` to the version written and takes the file's new identity; the
  registry re-keys the session. One save runs at a time and one more can queue; quitting
  waits for both (`finishSaving`). `AccessMode` reads a read-only volume, then a lock
  (`uchg`/`schg`), then write permission; read-only tabs refuse typing with the reason
  in the status line. Save As stages the whole version next to the target and moves or
  swaps it in. Hard-linked files are refused with a pointer to Save As until M3c. The
  4 GiB smoke save (clone, one byte, swap) takes about 70 ms. Undo across saves needs no
  remapping because the session keeps reading the inode it opened (D33).

### 4.4 View: `HexView` (AppKit)
- Custom `NSView` drawing only visible rows with Core Text, using pre-shaped glyphs for
  hex digits and printable ASCII. **As built:** `HexGlyphTable` pre-shapes printable ASCII,
  Latin-1, hex digits and placeholder dots once per font change and draws each row with
  `CTFontDrawGlyphs`. A horizontal `NSScroller` appears automatically when a wide layout
  (e.g. 32 bytes/row or `both` offsets) exceeds the viewport. Copying reads through
  `ByteSource.readSequential` (async off the main actor above 256 KiB) so copying doesn't
  evict the view's LRU pages.
- **Virtual scrolling:** window-sized view; a custom scroller maps position to a top
  row index (UInt64). No gigantic document view, no float-precision drift. This is
  the riskiest part of M1 — build it first. **As built (M1):** the scroll position is
  a `Double` pixel offset into the full content (exact for whole pixels up to 2^53,
  so ~4.3e9 px for 4 GB at 16 bytes per row is fine), driven by an `NSScroller`
  subview and `scrollWheel(with:)`; trackpad momentum comes with the events. No
  `NSScrollView` proxy: with a proxy, one proxy pixel spans many rows in a big file,
  so wheel scrolling jumps. Elastic edges and overlay scrollers are not done; revisit
  in M10.
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
- **As built (M3a):** `HexView.insertText` handles typing; the view works out the byte
  and asks `HexViewDelegate.hexView(_:overwrite:at:column:cursorAfter:)` to write it
  (default: refuse, so views are read-only unless the delegate edits). In the hex
  column the first digit sets the high nibble and keeps the cursor (the cursor box
  shrinks to the low digit), the second sets the low nibble and moves on; uncached
  bytes fall back to a 1-byte read; any move or Tab drops a half-typed byte and breaks
  undo coalescing. The text column writes one printable byte per character in ASCII or
  Latin-1; other characters beep and the status line says why. Typing with a selection
  starts at its first byte; at the last byte the cursor stays put; Backspace/Delete
  beep until M8. `HexViewDataSource.modifiedRanges(in:)` drives an accent-tinted fill
  under the find highlights and the selection. A search running during an edit keeps
  its snapshot and reports the pre-edit count/offset without overwriting the cursor or
  caching stale `Find All` results; every edit clears Find All highlights.
- Copy as hex/text of a huge selection is capped (e.g. 64 MB of output) with a
  prompt offering "Save selection to file…" instead.
- **View options (D18)**, in the View menu and the editor toolbar, per editor item,
  with defaults in Preferences:
  - offset base: hex / decimal / both;
  - byte grouping: 1 / 2 / 4 / 8 (M1); LE/BE display order for groups comes in M10;
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
- **As built (M2):** `Searcher` takes any `ByteReading`, which gained
  `readSequential` (uncached for `ByteSource`, a plain read by default). 4 MB chunks,
  `memchr` on the first exact byte, then verify; case-insensitive text folds ASCII
  letters only. Calls are synchronous with a `SearchCancellation` token and a progress
  callback per chunk; `Searcher.run` runs one on an app-wide pool of two and cancels it
  with the calling task. Find next/previous wraps once and says so; Find All keeps
  non-overlapping matches up to 100,000 and highlights them, and next/previous then
  step through that list without rescanning. Pattern kinds: hex, UTF-8, UTF-16 LE/BE
  text. Smoke test: a full search of a 4 GiB file takes ~0.6–0.8 s on the dev Mac
  (sparse file, so not disk-bound) and leaves the view's cached pages in place.

### 4.6 Data inspector
At the cursor: Int/UInt 8/16/32/64 (LE/BE), Float16/32/64, binary, UTF-8/UTF-16
character, Unix time / Mac absolute time / Windows FILETIME. Editable later.
**As built (M2):** `Inspector` (TwinPanesCore) decodes up to 8 bytes; `InspectorView`
(HexViewKit) is a panel on the right of the hex editor with a byte-order switch,
hidden by default and toggled with View › Show Inspector (⌥⌘I). Dates show as ISO 8601
UTC, Unix time as 32-bit seconds. Uncached cursor reads use a non-superseding
`ByteSource.prefetch` (and refresh when `HexView`'s viewport prefetch lands) so the
inspector and viewport never cancel each other.

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
  Locations (Home, mounted and ejectable volumes, the Trash with Full Disk Access),
  later Tags. Clicking navigates the active
  panel. Toggle ⌃⌘S as in Finder.
- **Two panels:** active panel has focus ring/highlight; Tab switches panels (only
  when a browser has focus — inside an editor Tab inserts a tab). Each panel owns its
  own **tab bar** (custom control — the system window tabbing is per-window, not
  per-panel). Each tab: location, back/forward history, sort order, selection. Tabs
  restore on relaunch (D23).
- **File list:** view-based `NSTableView` with columns (name, size, date, kind),
  async directory enumeration so 100k-entry folders don't block, live updates via
  FSEvents, type-to-select, sorting.
- **Path completion in the path field** (requested 2026-11-23, M5): typing a path in
  the field ⇧⌘G opens completes it the way a terminal shell does:
  - **Tab** completes the last component to the longest prefix all matching entries
    share. A folder that's the only match gets its trailing `/`, so the next
    component can follow at once.
  - **A second Tab** with several matches lists them under the field (folders
    first, as in the file list). The arrow keys pick one and Return takes it.
  - **Matching:** case-insensitive, like the default APFS volume, and `~` expands to
    the real home folder, not the app's container. Hidden entries are offered only
    when the typed component starts with `.`, whatever the tab's hidden-files toggle
    says.
  - **Listing:** the folder being completed is read off the main actor with the
    lister's cheap keys, and the read is cached while the field is open, so a
    100k-entry folder never stalls typing. A folder without a sandbox grant offers
    nothing; it doesn't prompt for access.
  - **Keys:** while the field has focus, Tab completes instead of moving focus,
    bound through the field's own command scope (§4.11). Escape closes the list,
    then the field.
- **Selection:** standard macOS multi-select (⇧/⌘-click, ⇧-arrows) is the target of
  F5–F8. No Norton Commander muscle memory beyond the F-keys is required day one;
  NC-style marking (Insert/Space, +/−/`*`) and drive switching are later candidates.
- **Hidden files:** toggle ⌘⇧. (Finder's shortcut) per panel, with a global default
  in Preferences.
- **Preview pane (right, collapsible):** `QLPreviewView` for the selected file plus
  metadata (size, dates, permissions, xattrs). For files Quick Look can't show, offer
  a hex view. BrowserKit doesn't import HexViewKit: it asks a viewer factory
  (protocol in WorkspaceKit, implementation injected by the TwinPanes app target). The hex view here
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
- **As built (M1b, visible way up):** the file list's first row is "..", the parent
  folder, in every folder but `/`. It's a view row only (`BrowserViewController`
  offsets rows by one; `BrowserItem.entries` never holds it), so status counts and
  later F5–F8 selections leave it out. It's selected on entering a folder; Return or
  double-click on it goes up and selects the folder you came from; F3/F4 on it beep;
  type-to-select skips it. ⌘↑/Backspace still go up. The smoke test goes up with
  Return and with a real double-click on the row.
- **As built (M4, docs/plans/M4.md):** D38–D43. A navigation checks the folder at
  once, then a `FolderLister` lists it in growing batches while the rows fill in;
  every navigation bumps a generation, so nothing from an older one lands. Each run
  of the tab's pipeline (batches, sort, hidden filter, live update, re-list) works
  out the new `FolderListing`, a small update's `RowChanges` and the selection's rows
  together, off the main actor past 500 entries; a run that includes listing batches
  is never applied row by row. The table only refreshes the row views it has, cells
  draw their own icon and text, and the row stripes come from the row views:
  NSTableView's own stripes cost 100–180 ms of drawing per navigation at 100k rows.
  The watcher starts its stream on its own queue, the path bar is built with a
  cached folder icon and gives way rather than widen the tab, and the tab keeps its
  access token under one grant. The smoke test lists, sorts, filters, scrolls and
  live-updates a real 100k-file folder with a main-thread heartbeat and fails on any
  gap whose main-thread CPU time exceeds the limit (50 ms on the dev Mac, scaled up
  to 4× from two reference workloads; worst on the dev Mac: about 30–48 ms while
  listing before the performance pass).
- **As built (M4 performance pass, docs/plans/M4.md):** D44. CI failed the 50 ms gate
  on all three runners (listing up to 915 ms). A Time Profiler pass found cell drawing
  (text layout, icons resampled from 1024 px), full row rebuilds per listing batch, a
  lock shared by the Kind sort and the Kind column, and icon lookups on the main
  actor. Fixed in that order of cost; the smoke test also found, through its new
  stall report, a 20–50 ms loop added by the icon cache itself (fixed). `StepTiming`
  times the tab's main-actor steps, and a gate over the limit prints what ran during its
  worst gap. Cached size and date formatters were measured and dropped (under 0.1 ms
  a screenful). Dev Mac, worst gaps over several runs: listing 20–41 ms (was 31–52),
  scrolling 12–16 ms (was 23–37), the folder moved away 18–36 ms (was 29–67).
- **As built (M4 review fixes):** `FolderListing.rowChanges` emits rank-moving updates
  as remove + insert so selection follows moved rows, and `merging` deduplicates
  overlapping batches; overlapping live `read(_:)` calls sequence per name,
  `relistLister` cancels on stop/`deinit`, `listed()` waiters resume on stop, and
  `SecurityScope` stays retained across background I/O. `BookmarkStore` resolves with
  `.withoutMounting` and canonical paths; `FolderGrants` checks active scopes and
  volume bounds; `FolderWatcher` uses `F_GETPATH`, `O_CLOEXEC`, and scoped unmount
  handling. `IconCache` removes observers on `deinit`, guards in-flight IDs, and probes
  `com.apple.FinderInfo` custom icons lazily off the main thread. `DirectoryReader`
  resolves symlink targets, skips caching dynamic type names, bypasses cached resource
  values in `entryIfPresent`, and uses `getpwuid_r`. Path bar, history notices/loops,
  `GapMeter`/`StallLimit` CPU-clock guards, `AccessRequest` volume/keyboard handling,
  parent-row/locale/geometry table updates, and `RecentFiles` menu snapshots were also
  hardened.
- **As built (M5, docs/plans/M5.md):** D48 and D49. The sidebar is a source list with
  SF Symbol icons, so drawing it reads nothing from disk; folders (not packages) are
  dropped onto Favorites, favorites reorder by dragging and leave by the context menu,
  and every window's sidebar shows an edit. One `VolumeWatcher` feeds all sidebars and
  drops a read a newer one replaced; ejecting runs off the main actor. Completion is
  the field editor's `insertTab:`, handled by the field's delegate, so the command
  registry still leaves Tab alone there; AppKit's list replaces its own last word,
  which also stops at spaces, so each offered match is cut to that range. Matching
  100k names took 67 ms on the main thread until it moved off it (5–10 ms now). The
  browser tab saves its folder, selection, history, sort and hidden files as paths; a
  folder that's gone opens its nearest ancestor that's still there, and one the
  sandbox only needs access for counts as there.
- **As built (M5 review fixes):** `PathCompletion` folds case consistently across matching
  and iterative prefix computation; `CompletionNames` lists directly with cheap resource
  keys on a bounded `OperationQueue` and coalesces concurrent reads per folder. The
  completion popup caps offered items at 500, cancels stale async tasks across re-entry
  and dismissal, and keeps the caret safe around slashes and spaces. Favorites and sidebar
  highlights compare canonical paths via `BookmarkStore.pathsEqual`; `VolumeWatcher` runs
  coalesced reads on a serial queue and removes observers in `deinit`; `MountedVolumes`
  never marks the boot volume ejectable; and `IconCache.forget` slices paths in UTF-16
  code units across NFC/NFD and combining marks.

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
  written by a newer build rather than misreading it.
- Merging windows and moving tabs between windows (M11) only change which window
  encodes an item; nothing else is stored separately.
- AppKit restoration follows the system's "Close windows when quitting an app"
  setting and is skipped after the user chooses not to reopen windows. That's
  accepted: a fresh launch opens one window with a Browser tab per panel.
- **As built (M5, docs/plans/M5.md):** D45–D47. `MainFrameLayout` takes a
  `PanelFiller` from the app (WorkspaceKit doesn't know browsers) and keeps both
  panels filled; each item gets its own host, which passes status messages on only
  while the item is in front. `MainWindow` reports first-responder changes and the
  frame activates the panel that holds the new one. Tabs drag on a private pasteboard
  type and select on mouse-up, since selecting rebuilds the tab bar. A window saves
  `WindowState` through its controller's `window(_:willEncodeRestorableState:)` and is
  rebuilt by `MainWindowRestoration`; the app's `ItemRestorer` rebuilds browsers and
  editors (by bookmark, through the session registry, the view put back after the tab
  loads its view). Recovery scans in `applicationWillFinishLaunching` and
  `LaunchRecovery` keeps the sessions alive, since the registry holds them weakly.
  The sidebar is hosted at the leading edge; its toggle is `toggleSidebarShown:`,
  because the panels' split views answer AppKit's `toggleSidebar:` first.
- **As built (M5 review fixes):** Focusing nested controls (Find bar, path field) in the
  inactive panel activates the panel without stealing first responder; collapsing the
  sidebar wraps AppKit's `NSSplitViewController` subclass (`SidebarSplitViewController`) so
  drag-resizes and `toggleSidebar:` keep width/restoration state in sync alongside the
  bordered `.toggleSidebar` toolbar item; `HexEditorItem` stores width-independent
  `topOffset` and defers scroll restoration to `viewDidLayout`; and `MainWindowRestoration`
  deduplicates restored sessions while deferring window presentation until AppKit applies
  the saved frame.
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
  ⌘G / ⇧⌘G next/previous (also F3 / ⇧F3 in the editor), ⌘E uses the selection,
  ⌥⌘F replace, "Replace All". Esc in the bar stops a running search, else closes the
  bar (scope `item.editor.findBar`). Built for hex in M2.
- Hex mode: hex-byte or text patterns (§4.5), searching the whole file via
  `Searcher` with progress. Replace arrives with M9a, after insert/delete (M8), so
  replacement can be any length from the start. The first usable hex version (M3b)
  has find only.
- Text & Markdown modes: text, case-sensitive / whole word / regex, with match count
  and highlight-all. Regex is limited to files under the text-mode threshold;
  large-text viewer uses `Searcher` (plain text, no regex).
- Replace All is one undo step, and respects the piece-count bound (§4.2).

### 4.11 Commands & key bindings (D21)

The registry is a **catalog**: every user action is a command with a stable ID
(`editor.find.next`, `browser.copyToOtherPanel`, `workspace.zoom`…), a title, a
default binding, and the AppKit action selector it sends. Bindings, the F-key bar and
the item switcher refer to command IDs.

**Routing stays AppKit's.**
- Menu items send their selector through the **responder chain**, so the focused
  item (or its slot, window, app delegate) handles it. Enablement uses AppKit menu
  validation (`NSMenuItemValidation` / `NSUserInterfaceValidations`); the F-key bar
  validates the same way.
- Standard actions keep their standard selectors: `copy:`, `paste:`, `selectAll:`,
  `performFindPanelAction:`, `undo:` / `redo:`. **Edit → Undo/Redo** reach the
  focused editor's session history: the editor item answers `undoManager` with an
  `NSUndoManager` facade over the session's `UndoStack` (shared by all views of that
  session), so menu titles ("Undo Typing") and validation come for free.
- Key resolution for context-dependent keys goes focused item → its slot → main
  frame → app, so the same key (F3, Ctrl+O) can mean different things in a browser
  and in an editor.

**Getting keys before `NSMenu` does.** A menu item has one static key equivalent,
and menu key equivalents fire before the responder chain, so context-dependent keys
can't be plain menu shortcuts.
- The main window intercepts key-down events (`performKeyEquivalent` /
  `sendEvent`) and asks the registry to resolve them against the focus chain
  *before* the main menu sees them.
- Menu items show the binding that applies to the current focus; their key
  equivalents are refreshed on focus change and in `menuNeedsUpdate(_:)`.
- Keys the registry doesn't bind fall through to normal AppKit handling (text
  editing, system shortcuts).
- **Coexists with keyboard navigation.** Tab switches panels only when a file list
  has focus; in text fields and editors Tab keeps its normal meaning, and Full
  Keyboard Access (Tab/⇧Tab through controls, key-view loop) keeps working. While a
  sheet is up, the registry intercepts nothing.
- **Prototype this in M0**, since it shapes the registry's API. Check focus in four
  places: a browser (placeholder list), a search field, an editor (placeholder text
  view) and a sheet.

Built in M0 with hard-coded default bindings; user-editable bindings arrive in M10.
**As built:** `MainWindow` refreshes menus on focus change (`makeFirstResponder` /
`becomeKey`) in addition to `menuNeedsUpdate(_:)`, deduplicates events between
`performKeyEquivalent` and `sendEvent`, and `CommandRegistry` preserves registration order
so primary shortcuts (e.g. `⌘G` ahead of `F3` on Find Next) appear in menus.
Dual panels came in M5 as `panel.switch` (Tab and ⇧Tab, bound in the file list's
scope only) and `panel.moveTab` (Window › Move Tab to Other Panel, no default key).
Dropping a file on a window opens a hex tab in that window; dropping a folder opens a
browser tab there and saves its grant.

### 4.12 App icon (D24)

**The icon.** Twin Panes, Navy + coral: two file panes on a navy tile, the active pane
outlined in coral with a coral highlighted row, and an F-key bar of six separate
slots (the first lit). Source: `TwinPanes/AppIcon.icon`, an Icon Composer document
with four layers (panes, rows, cursor, keys) as SVGs in three groups, so macOS can
light, blur and tint each part.

**Styles.** macOS 26+ renders the icon in the style the user picks under Appearance:
default, dark, clear (light and dark) and tinted (light and dark). The `.icon` sets a
darker navy fill for dark; clear and tinted are derived from the layers.
`docs/assets/app-icon-appearances.png` shows all six, rendered with Icon Composer's
`ictool`. In clear and tinted the coral turns monochrome; the highlighted row and
the first F-key still stand out because they sit in their own layer group.

**Older macOS.** On macOS 15 (D2) Xcode's asset compiler emits a flat `AppIcon.icns`
from the same `.icon`, so there's one source for every supported release.

**Reference designs.** Byte Panes (rows drawn as runs of byte cells) and the Midnight
mint palette stay on the icon canvas (Twin Panes icon concepts, artboards 6–7) for
reference: marketing, a future variant, or a document icon. There's no in-app icon
picker: macOS has no alternate-icon API for apps (`setAlternateIconName` is iOS
only), rewriting the bundle icon breaks the code signature, and
`NSApp.applicationIconImage` only lasts while the app runs.

**Still to do:** tune the clear and tinted styles in Icon Composer by eye (per-layer
opacity and glass), and check the icon at 16 and 32 px in Finder list view.

## 5. Sandbox & distribution

- **Sandbox on in every build from the start**, entitlement
  `com.apple.security.files.user-selected.read-write`. Developing sandboxed avoids
  building features that later can't ship on the App Store.
- **Recent files:** stored as security-scoped bookmarks (**favorites** stay plain paths in
  `UserDefaults` and get access from saved folder grants per D48).
- **Bookmarks:** app-scoped security-scoped bookmarks need the
  `com.apple.security.files.bookmarks.app-scope` entitlement; add it in M0.
  - On resolve, a bookmark that reports itself **stale but still resolves** is
    recreated immediately (while access is active) and stored again.
  - When resolution or `startAccessing…` fails, the user is asked to grant access
    again (open panel preset to the old location), never silently dropped.
- **Security-scope lifetime.** `startAccessingSecurityScopedResource` /
  `stopAccessing…` are wrapped in a reference-counted `SecurityScope` token
  (TwinPanesCore). Whoever needs access holds a token **until its work finishes**, not
  until its UI goes away: an `EditorSession` for its file, a browser tab for its
  location, a quick view or preview while it reads, a queued file operation until it
  completes or is cancelled. Closing the tab that started a copy doesn't revoke the
  copy's access. Bookmarks for recents and state restoration are created while access
  is active. A file opened inside an already granted folder uses that folder's scope
  instead of its own.
- **Volumes disappearing.** An unmounted or unplugged volume mid-read, mid-save or
  mid-copy must surface as an error on that session/operation (with the journal left
  for recovery), never a crash or hang. Behaviour per volume type is part of the
  spike.
- **File manager:** sandboxed, it can only browse folders the user granted. Plan for a
  one-time grant flow (e.g. home folder, external volumes) persisted as bookmarks.
- **Sandbox spike (M0, signed build, ~3–4 days)** — a by-hand test, not a feature:
  it checks what the sandbox lets a browser do (list, preview, copy, trash) *and* the
  editor's write path, because its result decides which save and recovery guarantees
  Twin Panes can make before the editor is built around them.
  - **Browsing:** grant the home folder and an external volume, then list, preview,
    copy into and trash in Desktop/Documents/Downloads, ~/Library and iCloud Drive;
    record which prompts appear and what fails. USB volumes come with the M3c spike,
    SMB shares with M13+.
  - **Write path:** for a *file-only* grant (open panel on one file) and a *folder*
    grant: create a clone (`clonefile`), create a staging file next to the original
    and in `itemReplacementDirectory`, `replaceItemAt`, in-place write, move to
    Trash. Check metadata after replace (xattrs, tags, ACLs, creation date) and
    hard-link behaviour.
  - **Bookmarks:** app-scoped bookmark entitlement; resolve after relaunch; stale
    bookmark refresh; behaviour after the file is moved or renamed.
  - **Volumes:** boot APFS in M0. External APFS, HFS+ and exFAT, and unplug/unmount
    mid-operation, are deferred to the M3c spike; SMB and other network protocols
    (AFP, NFS, WebDAV, SFTP mounts) to M13+, with remote connections.
  - **Output: a capability matrix** by volume type × grant type (clone? staging?
    replace? in place? Trash? bookmark survives relaunch?). It drives the save
    strategy table (§4.3), the recovery guarantee per volume (§4.1) and the App Store
    decision (D3).
- **Direct-only features:** some ForkLift-style features likely can't ship sandboxed
  (privileged/admin file ops, some system locations, certain mounting approaches,
  the terminal). They go behind a build flag in a Direct (Developer ID, notarized)
  flavor; the App Store flavor omits them.
- **Signing before distribution:** sandboxed builds (and UI tests) need a signature.
  Until distribution matters, local builds are development-signed and CI uses ad-hoc
  "Sign to Run Locally" (no certificates or secrets needed).
- Two build configurations, `Direct` and `AppStore`, must exist by M12 (first
  Direct-only feature) at the latest.
- Direct distribution later needs notarization in CI and an update mechanism
  (e.g. Sparkle).

## 6. Milestones

Order (D10): read-only hex viewer → basic browser → hex editor to first usable
version → file-manager core → hex polish → the rest.

From M3a on, each milestone's detailed plan (decisions, commit sequence,
verification) is in `docs/plans/<milestone>.md`, written and reviewed before work
starts; this table stays the summary.

| # | Milestone | Scope | Done when |
|---|---|---|---|
| M0 | Skeleton + main frame | Git repo, Swift package with library targets in the §4 dependency graph + thin Xcode app target, bundle ID `io.github.edudar.twinpanes`, sandbox entitlements, swift-format, GitHub Actions (arm64 macOS) running `swift test`, ad-hoc signing on CI, app-scoped bookmark entitlement, CI on macOS 15, 26 and 27 (§7). Main window with `MainFrameLayout`, one panel tab slot, placeholder item, zoom toggle, the single close workflow (tab/window/quit). **Command registry** (§4.11) as a catalog over responder-chain actions, including the key-interception prototype. Two-window smoke test. **Sandbox spike** (§5, by hand): what a sandboxed browser may do, signed clone-stage-replace and in-place write feasibility, bookmarks, volumes | CI green on macOS 15, 26 and 27; items open, close and zoom inside the single window; a context-dependent key resolves differently in two items, and focus behaves in browser, search field, editor and sheet; capability matrix for the boot volume written up and its save/recovery policy decided from it (other volumes: M3c and M13+) |
| M1 | Read-only hex viewer | Virtual scroller first, then thread-safe ByteSource + cache with async prefetch and placeholders, HexView, selection, copy as hex/text (capped), Go to offset, view options (offset base, grouping, ASCII/Latin-1 text column), non-regular files refused, `SecurityScope` tokens, open via File › Open / drag-drop / Finder "Open With" (document types per §4, no NSDocument) — each opens a **tab in the main frame**, Open Recent via bookmarks | 4 GB file opens in < 100 ms, scrolls at 120 Hz (also from a USB volume, with placeholders instead of stalls; USB in M3c, SMB in M13+), memory < 100 MB; all measured on real hardware, also while a search runs |
| M1b | Basic browser | `BrowserKit`: one panel listing a real folder (name, size, date, kind; folders first; hidden files off), Enter/double-click/⌘↓ into folders, ⌘↑/Backspace to the parent, F3/F4/Enter on a file opens it in the hex editor, path field for Go to Folder (⇧⌘G), type-to-select. Folder access: starts at the real home folder, asks once for access when the sandbox refuses a folder, keeps that as an app-scoped bookmark, and the browser tab holds the folder's `SecurityScope`. Replaces the M0 placeholder browser | Navigate from home to any granted folder and open a file in the hex editor without File › Open; access survives a relaunch |
| M2 | Inspect & search | Inspector panel, `Searcher` over a byte-reading protocol with the uncached `F_NOCACHE` read path, find next/previous/all (hex + text, capped results), status bar (offset, selection length, file size) | Full search of a 4 GB file with progress + cancel, without evicting the view's pages |
| M3a | Overwrite editing | Persistent PieceTable (snapshots), undo as a stack of roots with coalescing, overwrite in hex and text columns (encoding rules per §4.4), dirty-byte highlight, Searcher over snapshots | Fuzz tests pass; edits don't stall concurrent search |
| M3b | Sessions & saving → **first usable hex version** | `EditorSession` + `SessionRegistry`, dirty state, read-only mode, save strategy A (clone-stage-replace) per the M0 capability matrix with a range-patch save plan, save race handling, Save / Save As / Revert, unsaved-changes sheets with Save, Undo/Redo menu wired to the session. Hard-linked files offer Save As until M3c | Edit + save on 4 GB is near-instant; undo after save restores original bytes; typing during a save keeps the new edits; a failed save leaves the old file intact; read-only files refuse edits but Save As works |
| M3c | Protecting unsaved edits & crash recovery | Session folder + clone at the first edit (backing generation), strategy B (in place + journal + commit record) for hard-linked files, recovery guarantee per volume (narrowed mode where no clone), external-change policy with own-write suppression, iCloud dataless files, operation journal + crash restore, the fault-injection suite | Killing the app mid-edit or mid-save loses nothing, and power loss loses at most the last ~1 s of edits; typing during a save keeps the new edits and their journal; saving never triggers the external-change sheet; external modification never corrupts unsaved edits; **the fault-injection suite (§7) passes** |
| M4 | Browser foundation | Builds on M1b: async listing that never blocks the UI, back/forward history, sorting by column, hidden-files toggle, live updates (FSEvents), per-volume access flow informed by the M0 spike | Browse a 100k-file folder without UI stalls |
| M5 | Dual panels + tabs | Second panel, active-panel focus, per-panel tab bar, tab restore on relaunch via AppKit restoration (D23), collapsible sidebar (Favorites, Locations), shell-style path completion in the path field (§4.7), a relaunch smoke test that also checks crash recovery (from M3c, §9) | Daily navigation possible without Finder |
| M6 | NC keys + file operations | Function-key bar, F2–F8 actions with ⌘ equivalents, operations queue (copy/move/trash/new folder/rename) with progress and conflict handling, cross-volume move with per-item failure reporting, iCloud dataless files in operations and at the editor's first edit (from M3c, §9) | Copy/move large trees reliably with cancel and conflicts |
| M7 | Preview pane + hex integration | Collapsible right pane with Quick Look + metadata, viewer factory injected by the TwinPanes app target, QuickView item (F3 quick view in opposite panel, read-only `ByteSource`, unsaved-edits marker), F4 editor tab (hex), hex view in preview for unsupported types | Hex editor reachable entirely from the file manager; moving the cursor through 1,000 files in quick view creates no sessions |
| M8 | Insert/delete | PieceTable insert/delete exposed, insert-mode toggle in hex, paste/delete ranges, strategy A with a streamed rewrite (inode re-keying, new backing generation, metadata preservation), free-space check, refusal or copy-based path on strategy-B-only volumes | Random edit sequences round-trip byte-exact through save; xattrs/tags survive |
| M9a | Text mode + find/replace | Mode switcher, encoding detection, lossless invalid-byte mapping, TextKit sync layer, TextKit 2 text mode (after the spike in §4.10 passes; 16 MB threshold profiled separately), unencodable-input handling + Convert to UTF-8, line endings, inline find/replace in hex (any length) and text modes | Switch modes mid-edit with no data loss; replace-all on a 15 MB text file is one undo step; text-mode memory stays within its budget at the threshold |
| M9b | Large-text viewer | Virtualized read-only text view over snapshots, sparse background line index scanning in code units (UTF-8/Latin-1/UTF-16), `Searcher`-based find | Open and scroll a 4 GB log file (and a UTF-16 file) smoothly; line index stays within tens of MB |
| M9c | Markdown mode | Source highlighting, preview (renderer per §4.10), split/toggle, find/replace | Edit a few-MB README with live preview, no stalls |
| M10 | Polish | Preferences (font, bytes/row, colors, text-size threshold), **user-editable key bindings** (incl. the deferred conflicts in §9), more text-column encodings (UTF-8, UTF-16, EBCDIC), bookmarks within a file, light/dark, selection checksums | Daily-driver quality for editor + browser |
| M11 | Multiple windows | ⌘N, drag tabs between windows, Move Tab to New Window, Merge All Windows, multi-window restoration, several text-mode views of one session (shared `NSTextContentStorage`, §4.9) | Merge of 3 windows keeps every tab on its original side |
| M12 | Terminal (Direct only) | `Direct`/`AppStore` build configurations, SwiftTerm in bottom drawer and as panel tab, follows active directory, Ctrl+O full-frame toggle, item switcher | Daily shell use without leaving Twin Panes |
| M13+ | More file-manager features | Remote connections (with the sandbox spike on SMB and other network volumes), compare/sync, batch rename, archives, NC-style marking + drive switching, notarized Direct releases + updates… | Planned as requirements arrive |

Later hex candidates: structure templates (Mach-O/ELF/PNG…), two-file diff, entropy /
byte histogram.

## 7. Testing
- **Frameworks (D22):** swift-testing for logic tests; XCTest for `measure`-based
  performance tests and XCUITest UI tests.
- `TwinPanesCore` unit tests: PieceTable fuzzing (including snapshots and undo across
  saves), Saver round-trips for both strategies (commit-record rollback, metadata preservation, inode
  re-keying), crash-recovery journal replay (kill at random points, replay, compare
  with the reference), clone-generation lifetimes (no clone deleted while history
  references it), Searcher across chunk boundaries, Inspector decoding against known
  vectors, lossless decode/encode of invalid bytes, sparse line index (UTF-8 and
  UTF-16, checkpoints across chunk boundaries).
- **Fault injection (M3c gate):** a test harness that wraps Saver/journal file
  calls and can fail or kill the process at every write, `F_FULLFSYNC`, rename and
  `replaceItemAt` point; simulated power loss (discard unsynced writes in a fake
  file layer). Cases: crash at each step of strategies A and B; external rewrite of
  the original during edit and during save; typing during a save (revision A saved,
  B kept); volume disappearing mid-save; relaunch replay after each. Every case ends
  with either the old or the new file contents intact and recoverable edits matching
  the reference model.
- Concurrency: ByteSource hammered from several threads under Thread Sanitizer.
- Large files: sparse 4 GB files via `truncate -s 4G` for open/scroll/memory tests;
  **real-data** patterned files for search and save throughput (sparse files read
  zero pages too fast to be representative). Tagged slow, run nightly; mind runner
  disk space.
- Performance tests: open time, scroll frame time (including a throttled/slow-volume
  read source), search throughput, save time.
- CI matrix:
  - **GitHub-hosted arm64 runners only, one job per supported macOS (D2):**
    `macos-15`, `macos-26`, and `xcode-27` (GitHub's macOS 27 image, which comes with
    Xcode 27; there is no `macos-27` label). Each job uses its image's default Xcode
    and the macOS 15 deployment target. Build, `swift test`, and the signed app's
    smoke tests run on all three: launch, sandboxed file access, AppKit/TextKit
    behaviour. The relaunch checks (window restoration, bookmarks resolving after a
    relaunch, crash recovery) run on macOS 26 and 27 only (§9, "From M5").
    Lint runs only on the newest image, so its rules match the current swift-format.
  - Background: GitHub retired hosted macOS 14 runners on 2026-11-02
    (actions/runner-images#13518), which is why the minimum moved to macOS 15. Watch
    for the macOS 15 image's retirement notice; when it comes, raise the minimum
    again rather than adding a self-hosted machine.
  - Sandboxed UI tests run with ad-hoc signing (§5).
- Instruments pass (Time Profiler, Allocations) before closing each milestone.

## 8. Reference
- Hex Fiend (open source, BSD) handles huge files with a B-tree byte array; worth
  reading for design. Alternative: embed HexFiend.framework (faster to ship, less
  control; BSD licence is App Store–compatible).

## 9. Open & deferred questions

**Open**
1. **App Store:** keep as a goal for the whole app, editor-only, or drop — revisit
   after the M0 sandbox spike.
2. ~~**Packages in the browser**~~: decided in M4 (D43). They list as files, as in
   Finder, and Show Package Contents (⌥⌘↓) enters one. (The editor never opens them,
   D14.)
3. **Recovery on volumes without clones (§4.1):** make a private copy below a size
   limit (proposed 1 GB) and narrow the guarantee above it, or always narrow?
   **Decide from the M0 capability matrix**, once it shows which volumes actually
   lack clones.
   For now (decided 2026-11-22, M3b review): narrowed mode on every volume where the
   clone fails, the private copy deferred until the external-volume spike has run
   (docs/plans/M3c.md).

**Deferred** (decided to revisit later)
- **Shortcut conflicts:** settle by M10 at the latest; the command registry (§4.11)
  keeps them cheap to change.
  - editor mode switcher vs. Finder's ⌘1–4 view modes in the browser;
  - ⌃O (terminal toggle) vs. the Cocoa "open line" text binding;
  - F3 in an editor: view or find next;
  - ⌘L (Go to offset) vs. Finder's "Make Alias";
  - ⌘F: find files in the browser vs. find in the editor; likewise ⌥⌘F;
  - Tab: switch panels in the browser vs. insert a tab in the editor (resolved by
    focus, but confirm it feels right).
- **NC-style marking and drive switching** — not needed day one; candidates for M13+.
- ~~**Path bar as a path control**~~ (2026-11-22): built in M4 (D43).
- **Accessibility and localization** — out of scope for now (D19), including the
  proposed baseline VoiceOver support for the hex viewport in M1.
- **Block devices, privileged save** — not planned (D14).
- **From the M0–M2 review (2026-11-22):**
  - ~~*Bookmarks resolving after a relaunch*~~: automated in M5 for editor files (the
    restore relaunch reopens one by its bookmark). A folder grant after a relaunch is
    still checked by hand: the smoke test has no user-granted folder.
  - ~~*Asking for access again* when a saved bookmark no longer resolves~~: done in M4
    (D42). Lost grants are asked for again where they were; moved recent files stay
    in Open Recent and offer to find them.
  - *`SF_DATALESS` at open* (§4.1): not testable in CI (needs an iCloud-evicted file);
    planned with the M3c recovery clone, which must wait for the download anyway, and
    moved to M6 when M3c closed (see "From M3c").
- **From the M3a review (2026-11-22):**
  - ~~*Lazy `AddBuffer` creation*~~: open the backing file on first edit instead of at tab
    open; landed in M3c when `AddBuffer` moved into the session folder (created on the
    first edit, docs/plans/M3c.md).
  - ~~*`UndoStack`, multi-view observation, and `EditBuffer` actor isolation*~~: done in
    M3b. The undo stack lives on `EditorSession`, which notifies observers and is
    main-actor isolated with its `EditBuffer`.
  - *Chunked `readSequential` for fragmented piece trees*: coalesce dense `.original`
    spans into chunked reads instead of one `F_NOCACHE` `pread` per piece in M8.
- **From M3b (2026-11-22):**
  - *Two tabs on one session*: the registry brings an open file's tab forward, so the
    app never shows a session twice yet. When it does (M7 quick view, M11), find,
    typing and the inspector must work per view: forcing two tabs onto one session
    broke 31 smoke checks.
  - *Smoke coverage*: typing during a save needs a held save, so it is a unit test
    only; the Save As panel is stood in for by `saveAs(to:)`.
  - *`AddBuffer` writes through `FileSystem`*: only `Saver` uses the seam in M3b; the
    journal joined it in M3c, the add buffer joins it with the fault suite.
- **From M3c (2026-11-22):**
  - *Narrowed recovery* (D37): hashing sampled pages, conditional replay and
    rebasing the journal at saves wait for the external-volume spike.
  - *Flushing on app deactivation*: the 1 s debounce and the flush at save and close
    cover it; an explicit flush when the app goes to the background isn't wired.
  - *Strategy B writes aren't coordinated* with `NSFileCoordinator` yet.
  - *iCloud dataless files* (M3c step 13, left when M3c closed on 2026-11-23): the
    first edit of an evicted file must download it before the clone, behind an
    injected flag since CI has no iCloud. Lands in M6, whose copy and move must
    handle dataless files too.
  - ~~*A crash smoke test*~~: done in M5 (step 14). A child app is killed with SIGKILL
    mid-edit and the next launch shows the edit in its restored tab.
- **From M4 (2026-11-23):**
  - *Many files deleted from outside a shown 100k folder* (100k unlinks, not a move
    to the Trash) still stalls the tab: each burst of FSEvents is read and merged
    while the table shrinks, up to seconds in the Debug build, and while it lasted
    the smoke test's editor undo checks once failed with the tab watching that
    folder. The smoke test moves the folder away instead (as Finder's Delete does).
    Revisit with M6's operations, which delete large trees themselves.
  - *The stall gate on slower machines*: after the performance pass (D44), CI still
    crossed 50 ms in three steps (listing 102–362 ms, scrolling 57–120 ms, switching
    to dark 73–114 ms). The limit is now scaled to the machine rather than set per
    environment: 50 ms times how much slower this Mac runs two fixed reference
    workloads than the dev Mac, the slower of the two, capped at 4×. One draws and
    sorts names (48 ms on the dev Mac). The other builds a screenful of table rows
    (7.5 ms), because on macOS 26 and 15 the failing gaps were a folder's first rows,
    and AppKit's per-row setup (a layout pass and the key-view loop for each new row)
    couldn't be made cheaper: lighter cells, reused cells and skipping the early
    layout were measured and saved nothing overall. With that, macOS 15 passed, but
    macOS 27 and 26 still failed 2–4 steps at 78–149 ms, and their step reports
    showed the main thread waiting rather than working (a cell's setup 11.5 ms on the
    clock, 0.1 ms on the CPU; a 149 ms gap holding 2 ms of timed CPU work). The
    runners' speed also changed between runs (the drawing workload 109 ms in one run,
    74 in the next). So the gate now counts the main thread's CPU time in each gap
    between heartbeats, not the gap itself: work the app does on the main thread, not
    time the machine didn't give it. A gap far over the limit with little CPU time is
    printed but doesn't fail; the cost is that a stall where the main thread blocks
    (on a lock or the disk) isn't caught by this gate. The heaviest step left everywhere was
    leaving a 100k folder that moved away, and 23–26 ms of it (dev Mac) was the
    smoke test's own `FileManager.moveItem` on the main thread; it now moves the
    folder off it, as another app would. CI then passed on two runners at a time, but
    a runner's speed changed within a run (macOS 15's drawing workload: 79 ms in one
    run, 115–128 ms in the two before), so a limit measured once at the start didn't
    hold for later checks. The workloads now run again before each check, timed in
    CPU time like the check itself, and the run loop settles before the check starts
    so their leftovers don't count. Switching appearance remains the least steady
    check (22–55 ms on the dev Mac): nearly all of it is AppKit redrawing the window,
    not timed steps.
  - ~~*Volumes in the sidebar*~~: done in M5 (D48). The global hidden-files default
    stays with Preferences in M10.
  - *External volumes by hand*: granting a whole drive and a renamed volume asking
    again aren't automated (they need real drives), like the M3c volume spike.
- **From M5 (2026-11-24):**
  - *The stall gate relaxed to 75 ms*: with two panels, CI failed stall checks on
    every push, each a little over its limit (1.01–1.22× it, across the outside
    changes, dark-appearance and folder-moved-away checks), and the dev Mac under load
    failed 16 of 600 readings, most at 51–60 ms. Profiling the light-appearance check
    found part of each slow gap was the smoke test's own icon probe sharing a run-loop
    turn with the redraw; moving the probe out of that turn didn't make the runs
    steadier in A/B runs, so it stayed. The base limit is 75 ms on the dev Mac, still
    scaled per machine. Tighten it back to 50 ms in M6, once CI's history shows the
    readings under it, or sooner if the noisiest checks are made steadier.
  - *Relaunch checks on macOS 15*: the smoke test's restore and crash relaunches start
    the app's own executable as a sandboxed child, which macOS 15 kills at launch with
    SIGTRAP (macOS 26 and later allow it). They run on 26 and later only, so restoring
    windows and recovering after a crash aren't proven on 15. If that coverage is
    needed, run the two launches as steps of the CI workflow instead (D-f's fallback):
    the workflow's shell starts each child and kills the crash one. Revisit with M6's
    CI work or the first restore bug reported on 15.
  - *By hand only*: dragging tabs and favorites (a synthesized drag session isn't
    reliable; the drop logic is unit-tested and the smoke test calls the real drop
    methods), and ejecting a real USB drive (a disk image was ejected in testing).
  - *Live updates on the main thread* (fixed): the "folder changed" step cost up to
    ~30 ms of main-thread CPU per event on a 100k folder, and bursts stacked in one gap
    (79 ms on a macOS 26 runner). All of it was `IconCache.forget` walking the up to
    1024 cached custom-icon probes with `NSString` path methods, ~3 µs a path in the
    Debug build. It now looks the changed names up when they're fewer than the probes
    and matches with `hasPrefix` otherwise: on the dev Mac the longest step went from
    12–14 ms to under 0.4 ms. The ~10 ms left when the shown folder vanishes is the
    navigation to its parent, not the update.
  - *A smoke check that sometimes types late*: "Keep Mine keeps the edits" once found
    its typed byte at offset 1 instead of 0. Not reproduced on demand; watch CI.
  - *Second internal APFS volumes in Locations*: `MountedVolumes` hides non-boot internal
    volumes per M5 D-d, whereas Finder shows user-created internal volumes alongside the
    boot volume. Revisit if Finder sidebar parity is desired.
  - *M5 review deferred items*: `SmokeTest+Sidebar` temp-folder watcher teardown and
    sidebar-click-on-editor checks (deferred around concurrent sidebar work), plus
    pre-existing backlog items (`CommandDispatcher` when `firstResponder === window`, and
    avoiding `HexGlyphTable` rebuilds when font is unchanged in `HexView.relayout`).
