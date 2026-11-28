# Coverage report plan: our own pages from llvm-cov's export

_Status: approved 2026-11-27 (Swift package under `Tools/`; hit counts on every line;
step 5 decided later; totals count distinct lines). Steps 1 to 3, 4a and 4b
done; step 4c next._

## Context

CI publishes an HTML test and coverage report to GitHub Pages
(https://edudar.github.io/twin-panes/, commit 3935d2e). The coverage half is
`llvm-cov show -format=html`, which works but reads poorly:

- one flat table of ~130 files, no grouping by module, no bars;
- a Branch Coverage column that is `- (0/0)` on every row, because Swift code gets no
  branch data;
- links and page titles carry the runner's absolute checkout path;
- a dark mode that only swaps the page background and a few text colours.

A survey of other tools' reports (coverage.py, Istanbul, JaCoCo, lcov, ReportGenerator,
go tool cover, Codecov) settled the look we want; the maintainer chose to build our own
pages from `llvm-cov export` (path B) rather than restyle llvm-cov's fixed markup.

## Decisions

### D-a: a Swift command-line tool in its own package, `Tools/CoverageReport`

- A SwiftPM package with an executable target and a library target holding the logic,
  so Swift Testing covers it like the rest of the project. No dependencies.
- **Not a target in TwinPanesKit:** the app package would carry CI tooling, and the
  x86_64 build CodeQL runs would build it too.
- **Not Python:** a second language with no tests or lint in this repo.
- CI builds it on the macOS 27 job only; its build time is measured in step 4. The lint command gains
  `Tools/CoverageReport`; its tests join the verification list in AGENTS.md.

### D-b: input is `llvm-cov export` JSON, line states computed from segments

- `llvm-cov export -format=text` (format version 3) gives, per file, a `summary`
  (lines, functions, regions) and `segments`: `[line, column, count, hasCount,
  isRegionEntry, isGapRegion]`. Our run: 133 files, 13,106 segments, 440 KB.
- Per line, as llvm-cov's `LineCoverageStats` does: the segments starting on the line
  plus the one still open from the line before decide whether the line is
  **not code**, **covered** (count > 0), **missed** (count 0), or **partly covered**
  (covered, but a region starting on the line has count 0). The count is the highest
  region count on the line.
- Region ranges with count 0 are kept per line, so the page can mark the part of a
  line that never ran.
- **Check against llvm-cov itself:** every line's count must equal the one
  `llvm-cov show -format=text` prints. A unit test runs this on five real files
  (`Fixtures/export.json` and `show-counts.txt`); a one-off run over all 133 files
  (20,469 lines) matched too.
- **Changed in step 1:** the plan first compared totals with the export's
  `summary.lines`. Those can't match: llvm-cov adds up lines per function, so a line
  holding a closure counts once per function on it (16,788 code lines, 92.58%, against
  14,133 distinct lines, 92.87%). The per-line check above replaces it; which total
  the pages show is open question 4.
- **Overflowed counters:** a few regions (11 lines in our run) carry a wrapped-around
  count, which the JSON clamps to `Int64.max` and llvm-cov's text output shows as
  `18.4E`. They count as covered; the source page should not print the number.

### D-c: output is a static site with relative paths

- `index.html`, plus `coverage/<Module>/<File>.html` per source file. Paths are made
  relative to `TwinPanesKit/Sources/`, so no checkout path appears anywhere.
- One shared `report.css`, a little inline JavaScript for sorting, filtering and
  jumping between misses; every page reads fine with scripts off.
- Source text is read from the checkout (`--source-root`), escaped, not highlighted.

### D-d: the design, from the survey

- **Index:** a summary line (tests passed, line coverage, commit). A table of the six
  modules: a thin bar, line percentage, missed lines, total lines. (Function
  percentage dropped in step 3: it would need the export's per-function data, which
  the tool doesn't read.) Each module
  folds out its files with the same columns. Sortable columns and a file-name filter.
  Only the bar and the number take the threshold colour, never the row.
- **Source view:** a 3 px gutter stripe per code line (green covered, amber partly
  covered, red missed); a pale background on missed lines only; hit counts in a muted
  column; never-run regions inside a partly covered line underlined. A header with
  counts as chips, a minimap of misses down the right edge, `n` / `p` for the next and
  previous miss.
- **Thresholds:** green at 90% and up, amber at 75% and up, red below; stated once in a
  legend.
- **Theme:** light and dark from `prefers-color-scheme`, every colour a token; system
  font for text, monospace for code and numbers; usable at phone width.
- **Dropped:** the branch column (no data for Swift) and history charts (CI keeps no
  earlier runs).

### D-e: the test results page moves into the same tool (last step, optional)

- `tests.html` is rendered today by `scripts/test-report.xsl`. Moving it into the tool
  (Foundation's `XMLParser` reads the JUnit files) gives both pages one stylesheet and
  retires the XSL. It can land after the coverage pages or not at all.

## Behaviour

- `scripts/test-report.sh` keeps its interface (`<junit xml folder> <output folder>`).
  Its coverage part becomes: `llvm-cov export` into a temp file, then
  `swift run --package-path Tools/CoverageReport coverage-report` with the export,
  the source root and the output folder.
- The job summary keeps its counts and per-module table; the tool writes `summary.md`
  so the awk over `llvm-cov report` goes away.
- The tool exits non-zero, naming the file, if a source file is missing or shorter
  than its segments reach: the export and the checkout must be the same build, or
  the marks land on the wrong lines. (Seen in step 3a with a stale local export: two
  files edited since had lost or gained lines.)

## Commit sequence

Each step builds, passes all checks, and stays under 250 changed lines.

1. **Tools: decode llvm-cov's export and compute line states.** Package skeleton,
   the `Codable` export model, the per-line state and missed-region calculation, and
   Swift Testing tests: hand-built segment cases (gap regions, a region running over
   several lines, a partly covered line) and the summary cross-check on a small
   fixture export.
2. **Tools: render the source pages**, in two commits to stay under the size limit:
   - **2a, the markup:** HTML for one file from its line states and source text:
     state class and anchor per line, counts (large ones shortened, overflowed ones
     left out), never-run spans cut at llvm-cov's UTF-8 columns, escaping, the
     header with totals and relative links. Tests check these markup facts, not
     snapshots.
   - **2b, the look:** the shared stylesheet with both themes, the minimap of
     misses, and the `n` / `p` script.
3. **Tools: render the index and summary**, in two commits like step 2:
   - **3a, the markup:** module grouping and totals, the index page (headline with
     tests and commit, a fold-out row per module, a row per file) and `summary.md`.
     Tests for grouping, thresholds, totals and the Markdown.
   - **3b, the look:** index styles in the shared stylesheet, the sort and filter
     script.
4. **CI: use the tool for the coverage report**, in three commits:
   - **4a, Tools: build the site from an export.** Every page, the stylesheet and
     the job summary as values, with paths made relative to the sources folder; the
     check that each source file is as long as its segments reach.
   - **4b, Tools: the `coverage-report` command.** Argument parsing (no
     ArgumentParser dependency) and writing the files.
   - **4c, CI: switch the report to the tool.** `test-report.sh` switches from
     `llvm-cov show` to the tool; lint and test commands gain the package;
     AGENTS.md, DEVELOPMENT.md and PLAN.md §7 updated.
5. **(Optional, D-e) Tools: render the test results page.** Then delete the XSL.

## Verification

- Unit tests per step, run with the project's usual `swift test` commands against the
  new package.
- On real data after step 3: build the site from a full local run, check every file's
  counts against llvm-cov's report, open the index and three source pages (one fully
  covered, one partly, one at 0%) in light and dark and at phone width.
- After step 4: the CI run's report step passes, and the Pages site shows the new
  pages with no `/Users/` in any link.

## Open questions for review

1. A Swift package under `Tools/` (recommended) or a Python script?
2. Show hit counts on every line (lcov, Istanbul) or only on hover?
3. Include step 5 (the test results page) in this piece of work?
4. ~~Headline totals~~: decided 2026-11-27, distinct lines, matching what the pages
   mark. They will differ slightly from `llvm-cov report`.
