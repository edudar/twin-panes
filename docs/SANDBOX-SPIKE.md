# M0 sandbox spike — runbook

Goal (PLAN.md §5): a capability matrix by **volume type × grant type** that decides the
save strategy per volume (§4.3), the recovery guarantee per volume (§4.1, open question
§9.3) and the App Store question (D3, §9.1).

The probes live in `TwinPanesKit/Sources/SandboxProbe` and run from the app's **Debug**
menu, in the signed, sandboxed build. `swift test --package-path TwinPanesKit` runs them
unsandboxed on a temp folder only, to prove the probe code itself works.

## How to run

1. Build and launch the app (Debug configuration is sandboxed and ad-hoc signed):

   ```bash
   xcodebuild -project TwinPanes.xcodeproj -scheme TwinPanes -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
   ```

   ```bash
   open build/DerivedData/Build/Products/Debug/Twin\ Panes.app
   ```

2. For each volume below:
   - **Debug › Probe a Folder…** — pick a folder on that volume. The probe works in its
     own `TwinPanesProbe-…` subfolder and deletes it afterwards.
   - **Debug › Probe a Test File…** — pick a *disposable* file on that volume. The probe
     rewrites one byte (same value), adds an xattr and a Finder tag, and replaces the
     file through clone/copy → stage → `replaceItemAt` (it gets a new inode).
3. Quit Twin Panes, relaunch, then **Debug › Resolve Saved Bookmarks** (relaunch check).
4. Also try, per volume: unplug/unmount during a folder probe (expect an error row, no
   crash or hang).
5. **Debug › Export Spike Report…** and commit the Markdown under `docs/` (or paste it
   into the matrix below).

Each run also appears in the **Spike Report** tab.

## Volumes

| Volume | File grant | Folder grant | Relaunch | Unplug |
|---|---|---|---|---|
| Boot volume (APFS), home folder | | | | n/a |
| Boot volume: Desktop / Documents / Downloads (TCC) | | | | n/a |
| Boot volume: iCloud Drive | | | | n/a |
| External APFS (USB/Thunderbolt) | | | | |
| External HFS+ | | | | |
| External exFAT | | | | |
| SMB share | | | | |

## What each probe row answers

| Probe | Question |
|---|---|
| app-scoped bookmark | Can we persist access for recents/restoration? |
| fullfsync | Does `F_FULLFSYNC` work (journal durability, §4.2)? |
| in-place write | Strategy B possible? |
| clone → sibling | Can we stage next to the original (strategy A, folder grant)? |
| clone → container | Can clones/journals live in Application Support (boot volume only)? |
| clone/copy → itemReplacementDirectory | Can we stage with a file-only grant? |
| clone-stage-replace | Does strategy A work end to end, and what survives (inode, mode, xattr, tag, creation date)? |
| hard link after replace | Confirms hard links break under strategy A. |
| trash | Does `trashItem` work for this grant? |

## Browsing part (manual)

Grant the home folder and an external volume; then list, Quick Look, copy into and trash
in Desktop/Documents/Downloads, ~/Library, iCloud Drive, a USB volume and an SMB share.
Record which prompts appear and what fails. (The browser itself is M4; for M0 this is a
Finder-like check with the open panel and the probes above.)
