# Working on Twin Panes

Instructions for every coding agent (Claude Code, Codex, Cursor, Copilot, Gemini CLI and
others) and every contributor in this repository, collected from the maintainer's
feedback. Follow them without being asked again.

Background: [README.md](README.md) (what the app is), [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
(build, test, layout), [docs/PLAN.md](docs/PLAN.md) (decisions D1–D25, architecture,
milestones). Read the relevant parts of PLAN.md before changing behaviour.

## How to write code

1. **Interface first, then tests, then implementation.** Define the types, protocols and
   signatures (doc comments, stub bodies). Write tests against them and watch them fail.
   Then implement until they pass. This is the order of work, not of commits.
2. **Bugs: one at a time.** For each bug: failing test → fix → verify → commit, and only
   then start the next. Order fixes so each commit is safe on its own (a fix that surfaces
   new errors lands after the fix that handles them).
3. **Plan before big work.** For multi-part work (a milestone, a review's fix list),
   write a plan with severity or priority, get it reviewed, then implement.
4. **Prove it in the real app.** A feature isn't done because unit tests pass: the smoke
   test (`--smoke-test`) must exercise it in the running, sandboxed app with its real
   layout (never by forcing view frames). Milestones must deliver something usable end to
   end, on real files.

## Verifying

Before every commit, all of these pass:

```bash
swift format lint --strict --recursive TwinPanesKit TwinPanes
```

```bash
swift test --package-path TwinPanesKit
```

```bash
xcodebuild -project TwinPanes.xcodeproj -scheme TwinPanes -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

```bash
build/DerivedData/Build/Products/Debug/Twin\ Panes.app/Contents/MacOS/Twin\ Panes --smoke-test
```

- CI runs on **macOS 15, 26 and 27** (Xcode 16, 26, 27) and must pass on all three. Code
  that only Xcode 27 accepts breaks CI: in tests, don't capture `Atomic` or other
  non-copyable locals in `Task` / task-group closures (share a `Sendable` class instead).
- The package must also build for x86_64 (`swift build --triple x86_64-apple-macosx15.0`),
  because GitHub's CodeQL builds it that way; guard arm64-only APIs such as `Float16`
  with `#if arch(arm64)`.
- Tests leave nothing behind: no files in `~/Library/Preferences` (use an absolute-path
  `UserDefaults` suite inside a temp folder), nothing in the Trash, temp folders removed.
- Don't keep tests that can't fail (constants checked against themselves, sandbox checks
  under the unsandboxed `swift test`); move such checks into the smoke test.

## Commits and pushing

- **Commit only when the maintainer says "commit"; push only when they say "push"**
  ("commit and push" means both). "Push when the check passes" means wait for CI green.
- Each commit is **at most 250 changed lines**, one logical change, and builds and passes
  tests on its own. Split large work into a sequence of such commits.
- Never commit failing or disabled tests.
- Commit messages: a short subject, then a body saying what changed and why.

## UI

- Native macOS look and behaviour: Safari-style tabs, system colours, standard controls.
- Panels appear on demand: the find bar (⌘F) and the inspector (⌥⌘I) start hidden.
- Everything opens inside the single main window (D7); dialogs stay dialogs.

## Documentation

- **Keep docs/PLAN.md true to the code.** When code changes structure or behaviour, update
  the plan in the same piece of work: architecture tables must match the real modules
  and dependencies, and an "As built" note records how a feature was actually done.
- Fold reviews and decisions into PLAN.md itself (decisions table, §9 open/deferred);
  don't leave them in side documents. Record deferred items with where they land.
- README.md is for people discovering the project (what it is, what works, where it's
  going); build and source details go in docs/DEVELOPMENT.md.
- Public repository: never put personal file names or other private details in docs or
  commits (describe test files by folder, not by name).

## Project facts

- Name **Twin Panes**; bundle ID `io.github.edudar.twinpanes`; repo `edudar/twin-panes`;
  macOS 15+, Apple silicon only; Swift 6 strict concurrency; sandboxed.
- Open `TwinPanes.xcodeproj` (not the folder). Libraries live in the `TwinPanesKit`
  package; the app target is thin.
- External drives, SMB and other network volumes are deferred (M3b and M13+); the M0
  sandbox spike covers the boot volume only.
