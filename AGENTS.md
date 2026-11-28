# Working on Twin Panes

Instructions for every coding agent and every contributor in this repository, collected
from the maintainer's feedback. Follow them without being asked again. This file is the
single source: Claude Code reads it through `CLAUDE.md`, Gemini CLI through
`.gemini/settings.json`, and Codex, Cursor and Copilot read `AGENTS.md` directly. Don't
copy these rules into other files; point to this one.

Background: [README.md](README.md) (what the app is), [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
(build, test, layout), [docs/PLAN.md](docs/PLAN.md) (decisions, architecture,
milestones). Read the relevant parts of PLAN.md before changing behaviour.

When instructions conflict, the maintainer's instruction in the current task wins, then
this file, then [docs/PLAN.md](docs/PLAN.md), then the patterns in existing code.

## Task modes and scope

- **Modes:**
  - *Implement or fix:* follow the full workflow below (design, test-first, verify, stop
    for approval).
  - *Review:* read-only unless asked to edit. Check claims against the code and by
    running tests rather than speculating.
  - *Question or explain:* read-only; make no edits.
  - *Docs-only:* edit documentation only; skip builds and tests.
- **Scope control:** touch only what the task requires. Don't reformat untouched files or
  refactor nearby code; note pre-existing issues in your summary instead. Ask before
  adding external SwiftPM dependencies, changing entitlements, weakening the sandbox, or
  changing behaviour not covered by [docs/PLAN.md](docs/PLAN.md).
- **Ambiguity:** stop and ask when instructions conflict, scope is unclear, or a change
  alters user-visible behaviour not settled in [docs/PLAN.md](docs/PLAN.md). For minor
  implementation choices within the plan, pick the plain option and state the assumption
  in your handoff.

## How to write code

1. **Interface first, then tests, then implementation.** Define the types, protocols and
   signatures (doc comments, stub bodies that call `fatalError("Implementation
   incoming")`). Write tests against them and watch them fail. Then implement until they
   pass. This is the order of work, not of commits: never commit a stub.
2. **Bugs: one commit each.** Each bug gets its own failing test → fix → verify, and its
   own commit. Order fixes so each commit is safe on its own (a fix that surfaces new
   errors lands after the fix that handles them). See "Commits and pushing" for when to
   stop for approval.
3. **Plan before big work.** For multi-part work, write a plan with severity or priority,
   get it reviewed, then implement.
   - A milestone starts with its plan saved as `docs/plans/<milestone>.md` (for example
     `docs/plans/M3a.md`): context, decisions, behaviour, the commit sequence and how
     it's verified.
   - A review's fix list is saved as `docs/reviews/<topic>.md`: the findings, their
     severity (P0–P3, defined in "Code review" below), and the commit sequence that
     fixes them.
   - Keep the file true while the work is in progress (status line, changed steps).
     Once the work is done the file is frozen; PLAN.md's "As built" notes are the
     record. The one later edit allowed is adding a link to a review in `docs/reviews/`
     that fixes something the plan delivered.
4. **Prove it in the real app.** A feature isn't done because unit tests pass: the smoke
   test (`--smoke-test`) must exercise it in the running, sandboxed app with its real
   layout (never by forcing view frames). Milestones must deliver something usable end to
   end, on real files.

## Code design

These rules apply to code you write or change. Existing code may not follow them:
don't copy its violations into new code, and don't refactor code outside your task
to fix them. Note what you saw in the summary instead (or in PLAN.md §9 if it's
worth scheduling). Where the rules conflict, the earlier one wins.

The rules govern the project's own code and logic. Where the language, a framework or
the standard library sets a convention, the convention wins: overrides and protocol
conformances keep the framework's signatures (an `animated: Bool` parameter, a
delegate method), and APIs modelled on the standard library may follow its shape
(`popFirst()` both changes state and returns a value).

1. **Correct and readable before clever.** Code is read far more than it's written.
   Prefer the plain version unless a measurement says otherwise.
2. **Names say what things mean.** Name variables, types and functions after what
   they are in the problem, not their type or role in the code (`unsavedRanges`, not
   `list2`; no `Manager`, `Helper`, `Util`, `Data`, `Info`). A name that needs a
   comment to explain it is the wrong name. Booleans read as facts (`isDirty`,
   `canSave`).
3. **One responsibility per unit.** A type or module has one reason to change. If
   describing it takes "and", or its parts don't use each other's state, split it.
   A function does one thing at one level of abstraction: it either decides or does
   the detail, not both. Extract when a block needs a comment to say what it does,
   not to reach a line count.
4. **Dependencies point inward.** Domain logic doesn't depend on UI, frameworks,
   storage or the OS; those depend on it. Business rules must be testable without
   a window, a disk or a network. Pass dependencies in (initialiser parameters);
   don't reach for globals or singletons from inside the logic. Where a test needs
   to stand in for the outer side, cross the boundary with a small protocol owned
   by the inner side; that test double is the second implementation rule 5 asks for.
5. **No speculative abstraction.** Add a protocol, generic, layer or extension
   point only when there's a second implementation or a test double that needs it
   now. Duplicate twice before extracting a shared helper (rule of three), and
   only merge code that changes for the same reason. This is about sharing code
   between call sites; extracting a block inside one unit to name it (rule 3)
   needs no second use.
6. **No hidden effects.** A function either answers a question or changes state,
   not both, and its name says which. Don't mutate arguments or shared state
   that the signature doesn't make obvious. Prefer values and immutability;
   keep mutable state in one owner.
7. **Errors are explicit.** Handle or propagate every error; never swallow one
   silently or turn it into a default value without saying why. Validate at the
   boundary, then trust the data inside. No force-unwraps or `fatalError` for
   conditions that can happen at runtime.
8. **Small, honest interfaces.** Keep things as private as possible. Few
   parameters (group related ones into a type past about three); no Boolean flag
   that switches a function between two behaviours: write two functions.
9. **Tests are code too.** Each test checks one behaviour, has a name that states
   it, and is fast, independent and repeatable. Test through public behaviour,
   not private details (see also "Verifying" below).
10. **Every comment has a reason to exist.** A comment that restates what the code
    already says is noise: it costs reading time and goes stale when the code
    changes. Delete it, or improve the names until it isn't needed.
    - Keep a comment only when it says something the code can't: why it's done
      this way, a constraint or invariant, a trade-off or rejected alternative, a
      workaround and what it works around, or a reference (a plan section, a bug,
      a spec).
    - Public declarations whose contract isn't obvious from the signature get a
      doc comment stating it: what it promises, what it expects, what it throws,
      which thread or actor it runs on. This is an app, not a published library,
      so `public` marks a module boundary, not an API for outside users.
    - Test: if deleting the comment loses no information a reader couldn't get
      from the code in a few seconds, delete it.
    - No commented-out code, no changelogs or author notes in comments (that's what
      version control is for), no `TODO` without where it's tracked.

Before handing back a change, check its diff against this list and fix what it
breaks, or say why you didn't.

## Concurrency, UI and performance

- **Concurrency (Swift 6 strict, PLAN.md §3):** all AppKit and view state is `@MainActor`.
  Keep blocking I/O (file reads, coordination, saves, directory listing, icon rendering)
  and large-collection work off the main actor on bounded background queues or I/O pools.
  Pass immutable `Sendable` snapshots or values across actor boundaries. Shared caches
  read during `draw(_:)` use synchronous lock-protected APIs (such as `Mutex`), not
  actors, because drawing cannot `await`.
- **UI conventions:** AppKit-native single main frame (D7). Route user actions through
  the command registry and responder chain (D21). Support Light and Dark Mode with
  semantic `NSColor`s and redraw when appearance changes. Never block the main actor in
  drawing or layout. Accessibility (VoiceOver) and localization are out of scope for now
  (D19), but keep view state separable so they can be added later.
- **Performance:** measure before optimizing (code-design rule 1) and record before/after
  numbers in the plan or commit message. Respect the 4 GB and 100k-row constraints
  (PLAN.md §3): O(1) file open, bounded memory, and no work scaling with total file or
  folder size on the main thread.

## Code review

Judge changes against "Code design", [docs/PLAN.md](docs/PLAN.md) constraints,
concurrency and sandbox safety, and test coverage.

- **Severity scale** (also used in `docs/reviews/<topic>.md` and fix plans):
  - **P0 (Critical):** data loss, crash, security or sandbox breach, or data
    race/corruption. Blocks commit/merge.
  - **P1 (High):** broken behaviour, main-thread stall, leak, or missing error handling on
    a real path. Blocks commit/merge.
  - **P2 (Medium):** edge-case bug, missing test for non-trivial logic, or clear
    design-rule violation in new code. Fix before closing the milestone.
  - **P3 (Low):** clarity, naming, minor cleanup, or non-blocking polish.
- **Findings format:** cite `file:line`, severity, what fails (or which rule is broken),
  and a concrete fix. Verify suspected issues in the code or with a test instead of
  guessing. Separate pre-existing issues from issues introduced by the diff.

## Verifying

After every change to code, tests, build settings or the project file — and before
every commit of one — build and run all of these without waiting to be asked. They
match what CI runs. A change that touches only documentation needs none of them.

```bash
swift format lint --strict --recursive TwinPanesKit TwinPanes
```

```bash
swift test --parallel --package-path TwinPanesKit
```

```bash
swift test --sanitize=thread --package-path TwinPanesKit
```

```bash
swift build --package-path TwinPanesKit --triple x86_64-apple-macosx15.0
```

```bash
xcodebuild -project TwinPanes.xcodeproj -scheme TwinPanes -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

```bash
build/DerivedData/Build/Products/Debug/Twin\ Panes.app/Contents/MacOS/Twin\ Panes --smoke-test
```

The smoke test passes only if it prints `SMOKE OK`. A `swift test` run passes only if
every test target printed its `Test run with N tests` line: save its output and run
`scripts/check-test-runs.sh <log>`, as CI does. When `Config/` or the Xcode
project changes, also check the signed entitlements the way CI's "Check entitlements"
step does.

- CI runs on **macOS 15, 26 and 27** (Xcode 16, 26, 27) and must pass on all three. Code
  that only Xcode 27 accepts breaks CI: in tests, don't capture `Atomic` or other
  non-copyable locals in `Task` / task-group closures (share a `Sendable` class instead).
- CI lints with Xcode 27's swift-format. If your local version disagrees with CI, CI is
  right.
- The package must build for x86_64 because GitHub's CodeQL builds it that way; guard
  arm64-only APIs such as `Float16` with `#if arch(arm64)`.
- Tests leave nothing behind: no files in `~/Library/Preferences` (use an absolute-path
  `UserDefaults` suite inside a temp folder), nothing in the Trash, temp folders removed.
- Don't keep tests that can't fail (constants checked against themselves, sandbox checks
  under the unsandboxed `swift test`); move such checks into the smoke test.
- **Test frameworks (D22):** use Swift Testing (`import Testing`, `@Test`, `#expect`) for
  logic tests; use XCTest (`import XCTest`) for `measure` performance tests and UI tests.
- **No flaky timing tests:** avoid wall-clock sleeps and fixed wall-time thresholds in
  tests. Use deterministic synchronization (signals, continuations, injected seams) or
  calibrated/CPU-time gates for stall checks.
- **Honest reporting:** never claim a check passed unless you ran it after your final edit
  and saw it pass. If a check could not run or was skipped (for example, sandbox limits,
  no GUI, or a docs-only change), state which check was skipped and why.

### Verifying in a sandboxed worker

A worker running under Seatbelt (a sandboxed or headless subagent) can't reach some
system services the full set needs, such as security-scoped bookmarks
(ScopedBookmarksAgent) and the pasteboard server, and can't write caches outside its
folder. Unfiltered runs there fail or hang for reasons unrelated to the change. A worker
runs this reduced set instead:

- The lint and x86_64 build commands above, unchanged.
- `swift test` and `swift test --sanitize=thread` filtered to the test targets of the
  modules it changed, with SwiftPM's own sandbox off (it can't nest inside Seatbelt) and
  temp and module caches in the gitignored `build/` folder:

  ```bash
  mkdir -p build/tmp && TMPDIR="$PWD/build/tmp" CLANG_MODULE_CACHE_PATH="$PWD/build/tmp/ModuleCache" swift test --disable-sandbox --filter TwinPanesCoreTests --package-path TwinPanesKit
  ```

- Every build or test command gets a timeout from the worker's tool (`swift test` has no
  timeout flag). When one fires, stop the process and report the tail of its log; don't
  rerun it unchanged.

The unfiltered `swift test --parallel`, `xcodebuild` and `--smoke-test` stay with the
unsandboxed coordinator, which runs the full set above before any commit. The worker's
handoff names each check it skipped or filtered. A test that fails only because a service
is denied is reported, not changed to pass in the worker.

## Commits and pushing

- **Commit only when the maintainer says "commit"; push only when they say "push"**
  ("commit and push" means both). "Push when the check passes" means wait for CI green.
- **By default, stop after each logical change.** Implement and verify one commit's worth
  of work, then wait for approval before committing or starting the next. Never pile
  several fixes or steps into one dirty working tree. New code is reviewed before it's
  committed, so this is always the rule for implementation work.
- **Batches only when told.** The maintainer may say to commit and carry on, usually for
  a list of bug fixes. Then commit each fix on its own once it's verified and move to the
  next without pausing. Stop and ask if a fix turns out bigger or different than planned.
- Each commit is **one logical change**, builds, and passes all checks on its own.
  Aim for **at most 250 changed lines**, counting tests and docs but not generated
  files (such as `project.pbxproj` or asset catalog JSON); going over is fine
  only to keep one logical change together, and **350 is the hard limit**. Split
  larger work into a sequence of commits.
- Never commit failing or disabled tests.
- **Commit messages:** short imperative subject or `<Area>: <subject>` (for example
  `Core:`, `BrowserKit:`, `Smoke:`, `Tests:`, `Docs:`, `Plans:`), plain text without
  emoji, then a body saying what changed and why.
- **Git safety:** work on `main` unless asked to use a branch. Never force-push, rewrite
  or amend pushed history, or run destructive commands (`git reset --hard`,
  `git checkout -- .`, `git clean -fd`) without explicit approval. Stage only the files
  belonging to your change (`git add <paths>`); never use `git add -A` or `git commit -a`
  so unrelated or parallel work in the tree is left untouched.
- **Handoff summary:** when handing back a change or stopping for approval, briefly
  report: (1) what changed and why, (2) verification results (exact checks run or
  skipped and why), (3) assumptions made or deviations from these rules, and
  (4) pre-existing issues noticed outside scope.

## Documentation

- **Read before changing behaviour:** check the relevant sections of [docs/PLAN.md](docs/PLAN.md)
  (decisions, architecture, milestones) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
  (build, test, module layout) before designing or editing code.
- **When to create docs:** a milestone plan in `docs/plans/` and a review's fix list in
  `docs/reviews/`, as described in "Plan before big work". Don't create other side
  documents for decisions; fold them into `docs/PLAN.md`.
- **When to update docs:**
  - [docs/PLAN.md](docs/PLAN.md) — update in the same piece of work whenever code changes
    structure, decisions, or behaviour: keep architecture tables accurate, record how
    features were built in "As built" notes, and log deferred items in §9 with where they
    land.
  - [README.md](README.md) — update for user-facing changes (what works today, roadmap).
  - [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — update when build commands, test workflows,
    CI, or module/source layout change.
- **Public repository hygiene:** never include personal file names or other private details
  in docs or commits (describe test files by folder, not by name).
- **Style:** keep prose concise and plain (no emoji), wrap Markdown lines at ~90–95
  characters, and cite [docs/PLAN.md](docs/PLAN.md) decisions by ID or section (for
  example `D38`, `§4.7`).
