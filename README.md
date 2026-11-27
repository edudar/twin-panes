# Twin Panes

**A fast, keyboard-first, two-panel file manager for macOS, with a hex editor
built in.**

![The Twin Panes app icon in its default, dark, clear and tinted styles](docs/assets/app-icon-appearances.png)

Twin Panes is for people who live in Norton Commander, Total Commander or
ForkLift and want that on a modern Mac. It has two panels side by side, tabs in
each, and F-keys for everything. Viewing and editing files happens in a tab of
the same window, so you never juggle a pile of separate windows.

<!-- Screenshots: docs/assets/screenshot-*.png go here. -->

## What it does today

Twin Panes is early and changing quickly. Right now it offers:

- **Two-panel, tabbed workspace:** Side-by-side browser panels with a draggable
  split, keyboard focus switching, and Safari-style tabs in each panel that you
  can reorder or move between sides.
- **Sidebar, restore and path completion:** A Finder-style sidebar of favorites
  and mounted volumes (with eject), windows that come back after a relaunch with
  their panels and tabs, and Tab completion in the path field, like a shell's.
- **File operations, Norton Commander style:** Copy and move to the other panel
  (F5, F6), rename (F2), new folder (F7), trash (F8) and delete (⇧F8) with an optional
  function-key bar, progress you can pause or cancel, conflict handling (replace,
  skip, keep both, merge) and undo, also across volumes and for iCloud files.
- **Preview pane and Quick View:** A collapsible right preview pane (`⇧⌘P`) with Quick
  Look, read-only hex for binary files, O(1) file metadata (permissions, flags, extended
  attributes) and pinning, plus F3 Quick View in the opposite panel (and `⇧F3` in the
  same panel) that follows the cursor without creating editor sessions and reflects
  unsaved edits live.
- **Responsive folder browsing:** Handles folders with 100,000+ files without
  stalling the UI, streaming rows as they load, tracking external changes live,
  and supporting sorting, history, type-to-select, and package inspection.
- **Multi-gigabyte hex viewer:** Opens 4 GB+ files near-instantly with smooth
  scrolling and low memory use, reading only the visible slice of the file.
- **Search and data inspection:** Searches hex or text (UTF-8, UTF-16 LE/BE)
  across huge files with progress and cancel, highlights all matches, and
  decodes bytes under the cursor in a live data inspector.
- **Fast, safe hex editing:** Overwrites bytes in hex or text with unlimited
  undo/redo, patches only changed ranges on save, protects against concurrent
  external edits, and recovers unsaved changes after a crash.
- **Native and sandboxed:** Built in AppKit with light/dark appearance support,
  custom file icons, and macOS App Sandbox protection with remembered folder
  grants.

## Where it's going

In rough order:

1. **Daily-driver file manager:** Dragging files between panels and Finder.
2. **Full-featured editor:** Insert and delete bytes in hex, plus plain-text
   and Markdown editing modes with find and replace.
3. **Power-user workspace:** Multiple windows, a built-in terminal, remote
   connections, folder compare, and customizable key bindings.

The full plan, with every decision behind it, is in
[docs/PLAN.md](docs/PLAN.md).

## Requirements

- macOS 15 Sequoia or later
- A Mac with Apple silicon (there is no Intel build)

There are no downloadable releases yet. To try it, build it from source; see
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Contributing

Issues and ideas are welcome. To work on the code, start with
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md), which covers building, testing and
how the source is organized.

## License

Apache-2.0. See [LICENSE](LICENSE).
