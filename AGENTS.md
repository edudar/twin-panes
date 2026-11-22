# Working on Twin Panes

Instructions for every coding agent (Claude Code, Codex, Cursor, Copilot, Gemini CLI and
others) and every contributor in this repository, collected from the maintainer's
feedback. Follow them without being asked again.

Background: [README.md](README.md) (what the app is), [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
(build, test, layout), [docs/PLAN.md](docs/PLAN.md) (decisions, architecture,
milestones). Read the relevant parts of PLAN.md before changing behaviour.

## How to write code

1. **Interface first, then tests, then implementation.** Define the types, protocols and
   signatures (doc comments, stub bodies). Write tests against them and watch them fail.
   Then implement until they pass. This is the order of work, not of commits.
2. **Bugs: one at a time.** For each bug: failing test → fix → verify → commit, and only
   then start the next. Order fixes so each commit is safe on its own (a fix that surfaces
   new errors lands after the fix that handles them).
3. **Plan before big work.** For multi-part work (a milestone, a review's fix list),
   write a plan with severity or priority, get it reviewed, then implement. Every
   milestone starts with its plan saved as `docs/plans/<milestone>.md` (for example
   `docs/plans/M3a.md`): context, decisions, behaviour, the commit sequence and how
   it's verified. Keep that file true while the milestone is in progress (status line,
   changed steps); once it's done, PLAN.md's "As built" notes are the record.
4. **Prove it in the real app.** A feature isn't done because unit tests pass: the smoke
   test (`--smoke-test`) must exercise it in the running, sandboxed app with its real
   layout (never by forcing view frames). Milestones must deliver something usable end to
   end, on real files.

## Verifying

After every fix or change — and before every commit — build and run all of these without
waiting to be asked:

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
  This is an approval gate — it does not relax the 250-line limit or logical grouping.
  Never pile multiple fixes or steps into one dirty working tree: implement and verify
  one logical change (at most 250 changed lines), then pause for approval to commit
  before starting the next.
- Each commit is **at most 250 changed lines**, one logical change, and builds and passes
  tests on its own. Split large work into a sequence of such commits.
- Never commit failing or disabled tests.
- Commit messages: a short subject, then a body saying what changed and why.

## Documentation

- **Read before changing behaviour:** check the relevant sections of [docs/PLAN.md](docs/PLAN.md)
  (decisions, architecture, milestones) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
  (build, test, module layout) before designing or editing code.
- **When to create docs:** create a milestone plan at `docs/plans/<milestone>.md` before
  starting milestone work, and keep it current while the milestone is in progress. Do not
  create side documents for reviews or decisions; fold them into `docs/PLAN.md`.
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
