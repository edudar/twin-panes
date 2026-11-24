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
     severity, and the commit sequence that fixes them.
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

The smoke test passes only if it prints `SMOKE OK`. When `Config/` or the Xcode
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
- Commit messages: a short subject, then a body saying what changed and why.

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
