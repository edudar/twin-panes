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
swift test --package-path TwinPanesKit
```

The smoke test drives the built app. It opens two windows, browses a real
folder, and opens a 4 GiB sparse file to check open time, frame time and memory.
It also creates a 100,000-file folder and fails if listing, sorting, filtering,
scrolling or live-updating it ever keeps the main thread busy for longer than its
limit between two 5 ms heartbeats. It counts the main thread's CPU time in each gap,
not the gap itself: on a shared CI machine the thread can wait for a core for longer
than any stall the app causes. Each step prints its longest gap and its busiest one,
and what ran during a busiest gap over the limit. The limit is 50 ms on the dev Mac, scaled to the
machine: the smoke test first times two fixed workloads, drawing and sorting names, and
building a screenful of table rows. A Mac that runs either slower gets a
proportionally longer limit, set by the slower of the two, up to 4 times (200 ms). It
prints the times and the limit. The run takes one to two and a half minutes:

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
| `TwinPanes/` | App sources: entry point, menus, command bindings, recent files, the smoke test, and `AppIcon.icon`, the Icon Composer app icon. |
| `Config/` | Build settings (`.xcconfig`), `Info.plist` additions and entitlements. |
| `TwinPanesKit/` | One Swift package with every library module and its tests. |
| `docs/` | The plan, runbooks and images. `docs/plans/` holds one plan per milestone, written and reviewed before the work starts. |

Modules in `TwinPanesKit/Sources/` are sibling folders, and their dependencies
point one way only, enforced by `Package.swift`:

| Module | Purpose | Depends on |
|---|---|---|
| `TwinPanesCore` | Byte source and page cache, search, the edit model (piece tree, add buffer, undo), editor sessions and saving, directory listing, folder grants, security scopes. Foundation only. | none |
| `WorkspaceKit` | The main window, slots, tabs, command registry and close workflow. | TwinPanesCore |
| `HexViewKit` | The virtualized hex view, layout, selection and copy. | WorkspaceKit, TwinPanesCore |
| `TextEditKit` | Text and Markdown modes (later milestones). | WorkspaceKit, TwinPanesCore |
| `BrowserKit` | The folder browser tab and file list. | WorkspaceKit, TwinPanesCore |
| `EditorKit` | The editor tab that hosts the hex and text modes. | HexViewKit, TextEditKit, WorkspaceKit, TwinPanesCore |
| `SandboxProbe` | The sandbox capability spike (M0). | none |

Architecture, decisions and milestones are in [PLAN.md](PLAN.md).

## Continuous integration

`.github/workflows/ci.yml` runs on macOS 15, 26 and 27. Each job runs the
package tests, builds the app, checks the signed entitlements and runs the smoke
test. Lint and a second package run under Thread Sanitizer run on macOS 27. A
failed smoke check shows as an annotation on the run page.

## Commits

Keep each commit at most about 250 changed lines and about one thing, so it can
be read on its own. Every commit should build and pass `swift test`.

The full working rules (test-first order, fixing bugs one at a time, what to verify
before a commit, documentation and UI conventions) are in [AGENTS.md](../AGENTS.md),
which coding agents read automatically.
