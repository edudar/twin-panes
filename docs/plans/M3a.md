# M3a plan: overwrite editing

_Status: approved 2026-11-22; built 2026-11-22. How it was actually done is in PLAN.md (D26–D29, the M3a "As built" notes in §4.2 and §4.4)._

## Context

M2 is done and pushed (find, inspector, the review fixes). The next milestone in
PLAN.md §6 is **M3a: overwrite editing**:
- a persistent PieceTable with snapshots
- undo as a stack of roots, with coalescing
- overwrite in the hex and text columns
- a highlight on changed bytes
- Searcher running over snapshots

**Done when:** the fuzz tests pass, and edits don't stall a search that is running.

Saving, sessions, the journal and read-only mode are M3b, so in M3a edits live only
in the open tab. §4.2 says to "decide and prototype before M3a". That decision is the
first section below.

## Decisions

### D-a: the tree is a persistent AVL tree with join and split

- **Nodes** are immutable `final class` values, so they are `Sendable`. Each holds:
  - a `Piece`: the source (`.original` or `.add`), the offset in that source, and the length
  - `left` and `right`
  - `height`
  - `totalLength` of the subtree
- **Every edit is split and join:** split at `a`, split at `b`, then
  `join(left, piece, right)`. Overwrite, insert and delete are each a few lines on top
  of that. M8 then only has to expose insert and delete.
- **Path copying:** each edit copies O(log n) nodes, so taking a snapshot is O(1)
  (keep the root).
- **Coalescing:** a new piece that directly follows its left neighbour in the same
  source merges into that neighbour, during the join. Typing a run of bytes therefore
  stays one piece.
- **Why not the alternatives:**
  - A treap has a random shape, which makes failures harder to reproduce.
  - A B-tree like Hex Fiend's is faster in cache but much more code.
  - AVL with join/split is well documented and deterministic.

### D-b: the add buffer is a file from M3a on

- `AddBuffer` in TwinPanesCore is append-only. It writes with `pwrite` to a file in a
  temp directory, and the file is deleted when the buffer goes away.
- Appended bytes also go into a small LRU of its pages, so drawing what you just typed
  never blocks.
- Written ranges never change, so snapshots on other threads can read them without a
  lock. The only shared state is the length, which a `Mutex` holds.
- This follows §4.2 ("no in-memory phase"). M3b only moves the file into the session's
  folder.

### D-c: the edit model lives in TwinPanesCore, undo wiring in EditorKit

- `EditBuffer` (Core) holds the `ByteSource`, the `AddBuffer` and the current root.
  The `UndoStack` (also Core) is held by the editor item next to it, because each entry
  also stores the selection, which only the editor knows. _Changed while building:
  the plan first put the stack inside `EditBuffer`._
- A `snapshot()` is a `Sendable` struct that conforms to `ByteReading`, so `Searcher`
  and save code can use it directly.
- In M3b, `EditorSession` will wrap `EditBuffer` rather than replace it.
- ⌘Z and ⇧⌘Z reach the editor's view controller through the responder chain, as the
  existing `undo:` and `redo:` actions, validated by the controller. No
  `NSUndoManager` is involved.

### D-d: closing a modified tab, before saving exists

- `HexEditorItem.isDirty` reports unsaved edits, and the existing close workflow
  (`CloseCoordinator.confirmClose`) already prompts for dirty items.
- New `WorkspaceItem.canSave` (default `true`; the hex editor returns `false` until
  M3b). When it is false, the sheet offers only **Discard** and **Cancel**.

## Behaviour

- **Hex column:**
  - The first hex digit replaces the high nibble of the byte at the cursor and the
    cursor stays put, with a nibble marker.
  - The second digit replaces the low nibble and moves the cursor on.
  - Moving the cursor or typing in the other column resets the nibble state.
  - A key that isn't a hex digit beeps.
- **Text column:** today the column's encodings are ASCII and Latin-1, so one
  character overwrites one byte.
  - A character the encoding can't represent beeps and shows a status message.
  - Encoding rules for UTF-8 and UTF-16 come with those encodings in M10, following
    §4.4.
- **Selections and the file's end:**
  - Typing with a selection starts at the start of the selection.
  - The file's length never changes. At the last byte, the byte is overwritten and the
    cursor stays there.
  - Backspace and Delete beep until M8.
- **Undo:**
  - Each undo entry holds a root plus the selection to restore.
  - Typing into consecutive bytes of one column coalesces into one entry. Moving the
    cursor, switching column or pausing for 2 s starts a new entry.
  - Undoing to the root the tab opened with makes it clean again. Redo is cleared by
    any new edit.
- **Changed bytes:** `HexViewDataSource` gains `modifiedRanges(in:)`, which defaults to
  none. The view fills those bytes with a system accent tint, below the selection and
  the find highlights.
- **Status line:** "Modified · saving comes in M3b" replaces "Read-only" once there are
  edits.
- **Find and the inspector:**
  - Both read the current snapshot.
  - Any edit clears the Find All highlights and `lastMatch`, since offsets stay valid
    but the matches may not.
  - A search that is running keeps its own snapshot, so the result is what the file
    looked like when the search started.

## Commits

Each commit is ≤250 lines, builds and passes on its own. Each one goes interface →
failing tests → implementation.

0. **Save this plan and the rule.**
   - Copy this plan to `docs/plans/M3a.md`, as the first of the per-milestone plans.
   - AGENTS.md, under "Plan before big work", says that every milestone starts with a
     plan saved as `docs/plans/<milestone>.md` and reviewed before work begins.
     Each plan is kept up to date while the milestone is in progress, and PLAN.md's
     "As built" notes stay the record once it is done.
   - DEVELOPMENT.md's layout table gains `docs/plans/`.
1. **Core: `PieceTree`.** Pieces, nodes, join, split, `length` and `pieces(in:)`. Tests:
   - the AVL and length invariants hold after random joins and splits
   - concatenating the pieces gives back the same ranges
2. **Core: edits on `PieceTree`.** Overwrite, insert and delete, with coalescing. A
   model-based fuzz test against a `[UInt8]` with a seeded RNG that prints its seed on
   failure. It checks that:
   - old roots stay valid (snapshots)
   - the piece count stays bounded for sequential typing
3. **Core: `AddBuffer`.** Tests:
   - append and read back, including from several threads
   - the file is gone after the buffer is released
   - a cached read of just-appended bytes doesn't block
4. **Core: `EditBuffer` and `Snapshot`.** Snapshots implement `ByteReading`, plus
   `cachedBytes`, `prefetch` and `modifiedRanges` mapped through the pieces. Tests:
   - the fuzz test reads through the snapshot
   - truncating the original still reports `.truncated`
   - `modifiedRanges` matches the model's changed bytes
5. **Core: `UndoStack`.** Undo, redo, coalescing (entry replaced, not pushed), redo
   cleared on a new edit, clean state at the opening root. The fuzz test is extended
   with undo and redo, against the model's history.
6. **HexViewKit: editing input.** A `HexViewEditing` delegate method that asks to
   overwrite at an offset and reports whether it happened. Also nibble entry,
   text-column typing, beeps and the modified-bytes fill. Tests in
   `HexViewBehaviourTests` with the fake source:
   - two digits give one byte and advance
   - a non-hex key is refused
   - the last byte doesn't advance
   - drawing modified ranges doesn't trap on short data
7. **EditorKit: wire the editor.**
   - `HexEditorItem` reads the `EditBuffer` snapshot.
   - Edits come in through the delegate.
   - `undo:` and `redo:` are validated.
   - Also: the status text, `isDirty`, clearing find on an edit, and find and the
     inspector over the snapshot.

   Tests, including the done-when criterion: a gated search over a snapshot doesn't
   block an edit on the main actor, and the result comes from the old snapshot.
8. **WorkspaceKit and the app: `canSave`.** A Discard/Cancel-only sheet, and the Edit
   menu's Undo and Redo reaching the editor. Tests: `confirmClose` with a dirty item
   that can't save.
9. **Smoke test** in the real app with its real layout:
   - type hex digits and text into a temp file's tab with real key events
   - check the bytes through the snapshot
   - undo and redo
   - check that the modified fill is drawn
   - check that Find finds the typed bytes
   - edit near the end of the 4 GiB file
   - edit while a Find All runs over 4 GiB, printing the frame times and checking
     that the edit completes before the search does
   - the close prompt offers Discard
10. **Docs.**
    - PLAN.md: D-a to D-d go into the decisions table. Add "As built" notes in §4.2
      and §4.4, plus the TwinPanesCore component table (`PieceTree`, `AddBuffer`,
      `EditBuffer`, `UndoStack`).
    - README: "What it does today" gains overwrite editing and undo, and "Where it's
      going" is adjusted.

## Out of scope (stays in M3b or later)

- saving
- sessions and the registry
- the journal and crash recovery
- read-only mode
- the external-change policy
- insert and delete in the UI (M8)
- UTF-8 and UTF-16 text columns (M10)

## Verification

After every commit:
- `swift format lint --strict --recursive TwinPanesKit TwinPanes`
- `swift test --package-path TwinPanesKit`, plus `--sanitize=thread` for the Core and
  EditorKit commits
- `swift build --triple x86_64-apple-macosx15.0`
- the `xcodebuild` build and `--smoke-test` must print `SMOKE OK`

By hand:
- Open a file, type in both columns, undo and redo.
- Close the tab and confirm the Discard sheet.
- Search for the typed bytes.

Push only when you say so, then check CI on macOS 15, 26 and 27.
