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
   - **Debug › Probe a Test File…** — pick a *disposable* file on that volume, outside
     every folder the browser has been granted (the "covering folder grant" row says
     if it isn't; then the sibling and replace rows show folder access). The probe
     rewrites one byte (same value), adds an xattr and a Finder tag, and replaces the
     file through clone/copy → stage → `replaceItemAt` (it gets a new inode).
3. Quit Twin Panes, relaunch, then **Debug › Resolve Saved Bookmarks** (relaunch check).
4. Also try, per external volume (M3b): unplug/unmount during a folder probe (expect an error row, no
   crash or hang).
5. **Debug › Export Spike Report…** and commit the Markdown under `docs/` (or paste it
   into the matrix below).

Each run also appears in the **Spike Report** tab.

## Volumes

| Volume | File grant | Folder grant | Relaunch | Unplug |
|---|---|---|---|---|
| Boot volume (APFS), home folder | covered by a folder grant; rerun outside it | ✅ A via itemReplacementDirectory; ❌ A on hard-linked files | ✅ | n/a |
| Boot volume: Desktop / Documents / Downloads (TCC) | ✅ A via itemReplacementDirectory; no sibling | ✅ A; ❌ A on hard-linked files | ✅ | n/a |
| Boot volume: iCloud Drive | ✅ A, evicted file too; no sibling | ✅ as Documents (synced) | ✅ | n/a |
| External APFS (USB/Thunderbolt) | later (M3b) | later (M3b) | later (M3b) | later (M3b) |
| External HFS+ | later (M3b) | later (M3b) | later (M3b) | later (M3b) |
| External exFAT | later (M3b) | later (M3b) | later (M3b) | later (M3b) |
| SMB and other network volumes | later (M13+) | later (M13+) | later (M13+) | later (M13+) |

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
| dataless (evicted) | Was the file evicted to iCloud before the probe read (and so downloaded) it? |
| covering folder grant | Does a browser grant over the file change what the file probe sees? |
| hard link after replace | Confirms hard links break under strategy A. |
| clone-stage-replace (hard-linked) | Does strategy A work on a file with more than one link? |
| trash | Does `trashItem` work for this grant? |

## Results so far

First runs: 2026-11-21, macOS 27.2.1, boot volume (APFS, encrypted, cloning), Debug
build. Runs: a file in Documents, a file under `~/Code` (twice), a folder under
`~/Code` (twice: before and after the hard-link reorder), Documents as a folder, a
photo in Documents, and an evicted iCloud file in Documents with no folder grant.

What held everywhere: security scope, read, app-scoped bookmark creation,
`F_FULLFSYNC`, in-place write, xattr, Finder tag, clone into the container and into
`itemReplacementDirectory`, and trash (folder grant).

- **File grant, strategy A works.** Clone into `itemReplacementDirectory`, patch, then a
  coordinated `replaceItemAt`: new inode, content, mode, xattr, Finder tag and creation
  date all kept. A file grant needs no access to the file's folder for this.
- **File grant, no siblings.** `clonefile` next to the file fails with `EPERM` (the
  Documents run). The `~/Code` file run cloned a sibling only because the browser held a
  folder grant for `~/Code`; the probe now flags that ("covering folder grant").
- **Folder grant, strategy A works** for a file with one link: same results as the
  file grant.
- **Hard-linked files can't be replaced in the sandbox.** `replaceItemAt` on a file
  with `nlink` 2 fails with `NSCocoaErrorDomain 513` (no permission to save in the
  folder), even with a folder grant; the file and its link are left untouched.
  Unsandboxed, the same replace succeeds. (The first folder run failed for this reason:
  it linked the file before replacing it.)
- **Documents behaves like any other folder** once granted: same results as `~/Code`,
  sibling clones included. On the test Mac, Documents syncs to iCloud Drive (Desktop &
  Documents): trash went to `~/Library/Mobile Documents/.Trash`, not `~/.Trash`. So
  strategy A works in an iCloud-synced folder.
- **Evicted iCloud files work with a file grant alone.** A PDF evicted to the cloud
  ("dataless") read fine: the first read downloaded it, and every later row passed,
  strategy A included. The sibling clone failed with `EPERM` again, confirming that a
  file grant can't create files beside the file. Not measured: how long the download
  takes for a large file, and whether `clonefile` on a still-dataless file works (the
  read ran first).
- **Bookmarks survive a relaunch.** All 7 (4 files, 3 folders) resolved with access
  after quitting and relaunching. Every file bookmark came back *stale*: each of those
  files had been replaced by strategy A, so its inode changed and the bookmark found it
  by path. Folder bookmarks weren't stale. So after a strategy-A save, bookmarks to the
  file (recents, restoration, sessions) must be recreated; `RecentFiles` and
  `FolderGrants` already recreate stale bookmarks when they resolve them.
- **Clone at open into the container works** on the boot volume, so the private copy
  behind the crash-recovery guarantee (§4.1) is cheap there.

Policy, boot volume: strategy A, staged in `itemReplacementDirectory`, for file and
folder grants; **strategy B whenever `st_nlink` > 1**, which the sandbox requires and D17
wants anyway to keep inode identity; recovery clone in the container at open.

Still to run in M0: a file grant alone outside Documents (expected to match it).

Deferred: external APFS, HFS+ and exFAT, and unplugging mid-probe, to the M3b spike;
SMB and other network protocols to M13+ (remote connections). Until each is run, those
volumes have no measured policy.

## Browsing part (manual)

Grant the home folder and an external volume; then list, Quick Look, copy into and trash
in Desktop/Documents/Downloads, ~/Library and iCloud Drive (a USB volume with M3b, an SMB
share with M13+).
Record which prompts appear and what fails. (The browser itself is M4; for M0 this is a
Finder-like check with the open panel and the probes above.)
