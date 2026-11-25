# Developing Twin Panes

## Requirements

- macOS 15 or later on Apple silicon
- Xcode 16 or later (CI also builds with Xcode 26 and 27)

## Build and run

Open `TwinPanes.xcodeproj` in Xcode and run the **TwinPanes** scheme. Open the
project file itself, not the folder: opening the folder gives you a Files
workspace without the app's targets and schemes.

From the command line:

```bash
xcodebuild -project TwinPanes.xcodeproj -scheme TwinPanes -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

```bash
open "build/DerivedData/Build/Products/Debug/Twin Panes.app"
```

The app is sandboxed. The browser starts in your home folder and asks for access
the first time; each grant is saved as a security-scoped bookmark.

## Test

Logic tests for every library module run with SwiftPM:

```bash
swift test --parallel --package-path TwinPanesKit
```

CI also runs the tests under Thread Sanitizer and builds the package for x86_64,
which GitHub's CodeQL uses:

```bash
swift test --sanitize=thread --package-path TwinPanesKit
```

```bash
swift build --package-path TwinPanesKit --triple x86_64-apple-macosx15.0
```

The smoke test drives the built app. It opens two windows, browses a real
folder, and opens a 4 GiB sparse file to check open time, frame time and memory.
It clicks, tabs and moves tabs between both panels, uses the sidebar and Tab completion in
the path field with real key events, and starts the app again as a sandboxed child
process to check that a window comes back after a relaunch and that edits come back
after a crash (`--smoke-child`; on macOS 26 and later, since macOS 15 can't start a
sandboxed child).

It also creates a 100,000-file folder and fails if listing, sorting, filtering,
scrolling, live-updating or completing a name in it ever keeps the main thread busy
for longer than its limit between two 5 ms heartbeats. It counts the main thread's
CPU time in each gap, not the gap itself: on a shared CI machine the thread can wait
for a core for longer than any stall the app causes. Each step prints its longest
gap and its busiest one, and what ran during a busiest gap over the limit. The limit
is 75 ms on the dev Mac (50 ms until M5; see PLAN.md §9, "From M5"), scaled to the
machine: before each check the smoke test times two fixed workloads in main-thread
CPU time, drawing and sorting names, and building a screenful of table rows. A Mac
that runs either slower gets a proportionally longer limit, set by the slower of the
two, up to 4 times (300 ms). It prints the times and the limit for each check. The
run takes one to two and a half minutes:

```bash
build/DerivedData/Build/Products/Debug/Twin\ Panes.app/Contents/MacOS/Twin\ Panes --smoke-test
```

Formatting is checked with swift-format:

```bash
swift format lint --strict --recursive TwinPanesKit TwinPanes
```

Manual checks, such as the sandbox spike, are in
[SANDBOX-SPIKE.md](SANDBOX-SPIKE.md). The Debug menu runs the spike.

## Source layout

| Path | What's there |
|---|---|
| `TwinPanes.xcodeproj` | The thin app target: Info.plist, entitlements, document types, assets and signing. |
| `TwinPanes/` | App sources: entry point, menus, command bindings, window restoration, recent files, the smoke test and its child launches, and `AppIcon.icon`, the Icon Composer app icon. |
| `Config/` | Build settings (`.xcconfig`), `Info.plist` additions and entitlements. |
| `TwinPanesKit/` | One Swift package with every library module (`Sources/`) and its test target (`Tests/`). |
| `docs/` | The plan, runbooks and images. `docs/plans/` holds one plan per milestone, written and reviewed before the work starts; `docs/reviews/` holds one fix plan per code review. |

Modules in `TwinPanesKit/Sources/` are sibling folders, and their dependencies
point one way only, enforced by `Package.swift`:

| Module | Purpose | Depends on |
|---|---|---|
| `TwinPanesCore` | Byte source and page cache, search, the edit model (piece tree, add buffer, undo), editor sessions and saving, crash recovery at launch, directory listing, folder grants, security scopes, favorites and mounted volumes, path completion, stall/gap timing. Foundation only. | none |
| `WorkspaceKit` | The main window, both panels, tabs and tab dragging, window state for restoration, the hosted sidebar, command registry and close workflow. | TwinPanesCore |
| `HexViewKit` | The virtualized hex view, layout, selection and copy. | WorkspaceKit, TwinPanesCore |
| `TextEditKit` | Text and Markdown modes (later milestones). | WorkspaceKit, TwinPanesCore |
| `BrowserKit` | The folder browser tab and file list, path completion, and the sidebar. | WorkspaceKit, TwinPanesCore |
| `EditorKit` | The editor tab that hosts the hex and text modes. | HexViewKit, TextEditKit, WorkspaceKit, TwinPanesCore |
| `SandboxProbe` | The sandbox capability spike (M0). | none |

Architecture, decisions and milestones are in [PLAN.md](PLAN.md).

## Continuous integration

`.github/workflows/ci.yml` runs on macOS 15, 26 and 27. Each job runs the
package tests, builds the app, checks the signed entitlements and runs the smoke
test. Lint and a second package run under Thread Sanitizer run on macOS 27. A
failed smoke check shows as an annotation on the run page.

## Commits

Commit size, approval and verification rules are in [AGENTS.md](../AGENTS.md), along
with the rest of the working rules (test-first order, bug fixes, code design,
documentation). Coding agents read it automatically.
