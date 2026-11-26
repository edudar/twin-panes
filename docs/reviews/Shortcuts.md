# Keyboard Shortcuts Review

Audit of the default bindings in [Commands.swift](../../TwinPanes/Commands.swift) and the
standard Edit menu ([MainMenu.swift](../../TwinPanes/MainMenu.swift)) against the
shortcuts macOS and Finder already define, after M6 (`a5c4712`, plus the uncommitted
function-key bar restyle that drops F10 Quit).

**Rule (agreed 2026-11-26):** each command's primary binding is the one macOS or Finder
already uses for it. Where they have none, a new binding follows the pattern of its
neighbours. Norton Commander F-keys are a second layer, never the only way to a command
and never a replacement for a system shortcut. Before binding, check the keys macOS
reserves: ⌃F1–⌃F8 (keyboard navigation), F11 (Show Desktop), ⌘F5 (VoiceOver), and ⌥ or
⌘ with the brightness, volume and Mission Control keys.

**Status:** In progress: commit 1 (the ⌃⌘ keys and ⌘Y) done; the Go menu next.

---

## 1. What already follows the rule

| Command | Binding | Matches |
|---|---|---|
| Quit | ⌘Q | All apps (F10 removed) |
| New Window, New Tab | ⌘N, ⌘T | Finder |
| Close Tab, Close Window | ⌘W, ⇧⌘W | Finder, Safari |
| Next / Previous Tab | ⌃⇥, ⌃⇧⇥ | Finder, Safari |
| Show Sidebar | ⌃⌘S | Finder |
| Open, Enclosing Folder | ⌘↓, ⌘↑ | Finder |
| Back, Forward | ⌘[, ⌘] | Finder |
| Go to Folder | ⇧⌘G | Finder |
| Show Hidden Files | ⇧⌘. | Finder |
| New Folder | ⇧⌘N (F7) | Finder |
| Move to Trash | ⌘⌫ (F8) | Finder |
| Delete Immediately | ⌥⌘⌫ (⇧F8) | Finder |
| Undo, Redo, Select All | ⌘Z, ⇧⌘Z, ⌘A | All apps |
| Show Package Contents | ⌥⌘↓ | Finder has no key; follows ⌘↓ |
| Find, Find Next / Previous, Use Selection for Find | ⌘F, ⌘G / ⇧⌘G, ⌘E (editor) | Text editors |
| Go to Offset | ⌘L (editor) | Xcode's Go to Line |
| Switch Panel | ⇥, ⇧⇥ (file list) | No Mac equivalent; dual-pane convention |

## 2. Findings

### Medium (P2)

1. **View (F3) has no Finder key.** Finder uses Space and ⌘Y for Quick Look; the browser's
   View is reachable only by F3 and the menu.
   - **Fix:** bind Space and ⌘Y to `browser.view` in the file list's scope. Space is
     also the start of a type-select; check the table's type-select still works with a
     name containing a space.

2. **Finder's Go shortcuts are missing.** ⇧⌘H Home, ⇧⌘D Desktop, ⇧⌘O Documents, ⌥⌘L
   Downloads, ⇧⌘A Applications, ⇧⌘U Utilities have no counterpart, though the sidebar
   offers the same places.
   - **Fix:** a Go menu with those items, each opening the folder in the active browser
     (the grant rules of §5 apply as for a sidebar click).

3. **Copy and Move to Other Panel use ⇧⌘C and ⇧⌘M.** ⇧⌘C is Finder's Go › Computer,
   which finding 2 would want. ⌥⌘C, the obvious next choice, is Finder's Copy as
   Pathname.
   - **Decision needed:** keep F5 and F6 as the dual-pane keys and pick a free ⌘ pair
     that Copy and Move share (for example ⌃⌘C / ⌃⌘M, after checking neither is taken).
   - **Also:** Finder's own way to copy and move files, ⌘C then ⌘V, and ⌘C then ⌥⌘V,
     isn't supported in the file list. It is worth adding as the primary Mac route, with
     the same queue and conflict sheet.

4. **Edit (F4) has no ⌘ shortcut,** against §4.7's rule that every F-key action has one.
   The path field already uses ⌘↩ for Open in Hex Editor.
   - **Fix:** bind ⌘↩ to Open in Hex Editor in the file list too, so the one shortcut
     means the same in both places, and make F4 its F-key.

### Low (P3)

5. **Rename is ⌘R, which is Finder's Show Original.** Finder renames with Return, but
   Return opens here (M5, D-b), which a file manager needs.
   - **Decision needed:** keep ⌘R (Twin Panes has no aliases' Show Original today) or
     choose another; either way F2 stays.

6. **New Editor Tab is ⌥⌘T, Finder's Hide/Show Toolbar.** Twin Panes' toolbar has no
   such command yet, so nothing breaks today.
   - **Fix:** leave it, but don't add Hide Toolbar on ⌥⌘T later without moving this.

7. **⌫ alone goes up a folder in the file list.** That is Windows Explorer's convention;
   in Finder ⌫ alone does nothing, and ⌘↑ goes up. It sits next to ⌘⌫ (Move to Trash), so
   a missed ⌘ moves the panel instead of trashing, which is harmless but surprising.
   - **Decision needed:** keep it as a dual-pane convenience or drop it in favour of ⌘↑.

8. **Finder commands with no counterpart yet:** Get Info (⌘I), Duplicate (⌘D), Make
   Alias (⌘L, already deferred to M10 in §9), Empty Trash (⇧⌘⌫). Not bugs; when they come,
   they take Finder's keys.

## 3. Decisions (2026-11-26)

- **The file commands share one pattern, ⌃⌘ + their letter:** ⌃⌘C Copy to Other Panel,
  ⌃⌘M Move to Other Panel, ⌃⌘V View, ⌃⌘E Edit, ⌃⌘R Rename. Neither macOS nor Finder uses
  ⌃⌘ with these letters; Finder's own ⌃⌘S (Show Sidebar) is already bound here. ⇧⌘ stays
  Finder's "go to a place" pattern (finding 2), so ⇧⌘C and ⇧⌘M go, and ⌘R goes.
  The F-keys stay as the second layer (F2, F3, F4, F5, F6).
- **View** also keeps ⌘Y, Finder's Quick Look. Space isn't bound.
- **Edit** opens the hex editor (⌃⌘E, F4); ⌘↩ in the path field is unchanged.
- **Go menu** is added (finding 2).
- **Return goes down a level and ⌫ up a level** in the file list; both stay.
- **⌥⌘T** stays for New Editor Tab (finding 6). Finding 8 stands as written.
- **Clipboard copy and move** (⌘C, then ⌘V or ⌥⌘V) stays a candidate, not scheduled.

## 4. Commit sequence

One commit each, with a smoke check of the keys in the real window:

1. Rebind the file commands to ⌃⌘ + letter and add ⌘Y for View; menus show the ⌃⌘
   keys.
2. The Go menu with Finder's ⇧⌘ places.
3. PLAN.md §4.7 and §4.11 take the final table.
