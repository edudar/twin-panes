# M7b plan: structured QuickView (coloring, prettifying, and format overrides)

_Status: complete 2026-11-28; frozen (as-built record is in `docs/PLAN.md`)._

## Context

M7 shipped `QuickViewItem` (`F3` / `⇧F3`) with a two-way `Quick Look | Hex` toggle
(D58, D60). Today `PreviewClassifier` routes `.text` and `.propertyList` to `QLPreviewView`,
which renders JSON, XML, YAML, TOML, CSV, TSV, `.properties`, and binary `.plist` files as
uncolored raw text (or minified single-line text, or unreadable binary plists), while
unknown extensions still show an empty Quick Look segment alongside Hex.

This milestone upgrades **QuickView only** (leaving the compact right Preview Pane
unchanged) with a fast, sandbox-safe, zero-dependency formatted text viewer for structured
data and plain text, contextual mode segments, and per-file / per-extension format
overrides.

Out of scope for M7b (recorded in `docs/PLAN.md` §9 as future ideas):
- general programming-language source code highlighting (candidate to share with M9a /
  `TextEditKit`);
- collapsible JSON/XML tree views (`NSOutlineView`);
- structured formatting inside the compact right Preview Pane (`PreviewPaneViewController`).

**Done when:** QuickView (`F3` / `⇧F3`) renders JSON, XML, XML/binary `.plist`, CSV, TSV,
YAML, TOML, `.properties`, and plain text natively with Light/Dark semantic syntax coloring,
prettifying where supported, contextual mode segments (`Pretty | Text | Hex`, `Text | Hex`,
`Preview | Hex`, or Hex-only for unknowns), manual format overrides with per-extension
persistence, bounded O(1)-checked reads for multi-GB files, zero `EditorSession`s created,
and no stall-gate regression on the 1,000-file cursor sweep. Proven in the smoke test on
real files.

## Decisions

### D-a: `PreviewClassification`, `PreviewMode`, and `StructuredFormat` (`TwinPanesCore`)

Replace the binary `PreviewMode` (`.quickLook` / `.hex`) with four explicit modes and a
structured classification result:

- `PreviewMode`: `.pretty`, `.text`, `.preview` (macOS Quick Look), `.hex`.
- `StructuredFormat`: `.json`, `.xml`, `.plist`, `.yaml`, `.toml`, `.csv`, `.tsv`,
  `.properties`. Every `StructuredFormat` supports `Pretty | Text | Hex`, where `Pretty`
  shows syntax-colored (and reformatted where applicable) output and `Text` shows raw,
  unformatted plain text.
- `PreviewClassification` (`Sendable`, `Equatable`):
  - `availableModes: [PreviewMode]`
  - `defaultMode: PreviewMode`
  - `structuredFormat: StructuredFormat?`

Default classification rules (pure, O(1), no disk reads — takes `UTType`, filename
extension, file flags, dirty-session flag, and optional user override):

| Category | Examples | `availableModes` | `defaultMode` |
|---|---|---|---|
| Structured data | `.json`, `.xml`, `.plist` (XML & binary), `.yaml`/`.yml`, `.toml`, `.csv`, `.tsv`, `.properties` | `[.pretty, .text, .hex]` | `.pretty` |
| Plain text (non-rich) | `.txt`, `.md`, `.log`, `.sh`, source files (`UTType.text` excluding rich QL types) | `[.text, .hex]` | `.text` |
| Known Quick Look previewable | `.pdf`, images, audio/video, `.rtf`/`.rtfd`, `.html`, `.webArchive`, fonts, 3D, `.ics`, `.vcf`, `.eml`, iWork/Office/OpenDocument | `[.preview, .hex]` | `.preview` |
| Unknown / binary | `.data`, dynamic types without a recognized extension or override, executables, archives | `[.hex]` | `.hex` |

Key edge cases:
- **Rich text vs. plain text:** `.rtf`, `.rtfd`, and `.html` conform to `UTType.text` on
  macOS; check Quick Look-rendered rich/document types before generic `UTType.text` so they
  keep `Preview | Hex`.
- **Extension fallback:** `.toml`, `.yaml`/`.yml`, `.tsv`, and `.properties` often resolve
  to dynamic or generic `UTType`s; match lowercase file extensions alongside `UTType`
  conformance.
- **Dirty `EditorSession` (D58):** `defaultMode` remains `.hex` so unsaved edits appear
  immediately with the unsaved-edits banner, while `availableModes` preserves the file's
  normal modes.
- **Folders, packages, broken symlinks, dataless iCloud files:** keep existing QuickView
  placeholders (no byte reads).

### D-b: Manual format classification overrides (`PreviewFormatOverrides`, `TwinPanesCore`)

When default detection misses a file (e.g., `.geojson`, `.xcconfig`, `.env`, `.csproj`,
`.conf`, extensionless config files, or a custom Quick Look-previewable format):

- `PreviewFormatOverride` (`String`, `Codable`, `Sendable`):
  - `.structured(StructuredFormat)` (`.json`, `.xml`, `.plist`, `.yaml`, `.toml`, `.csv`,
    `.tsv`, `.properties`)
  - `.plainText`
  - `.preview` (Quick Look)
  - `.hex`
- `PreviewFormatOverrides` stores persistent overrides in `UserDefaults` keyed by
  lowercased file extension (without leading dot), using an injected `UserDefaults`
  instance so unit tests and smoke runs never touch `~/Library/Preferences`.
- `QuickViewItem` supports:
  - a **transient per-file override** (for extensionless files or one-off inspection,
    cleared when navigating to another file);
  - **"Always use for `.ext`"** / **"Reset `.ext` to Auto"**, persisted via
    `PreviewFormatOverrides` and applied immediately.
- Exposed in `QuickViewViewController` as a compact format menu button in the header
  (showing the active format label or icon, e.g., `JSON`, `XML`, `Format`), keeping the
  header clean while making reclassification one click away.

### D-c: Pure-Swift formatters and tokenizers (`TwinPanesCore`)

Zero external SwiftPM dependencies. All formatters and lexers live in `TwinPanesCore`
(Foundation-only, `Sendable`), returning a `StructuredDocument`:

```swift
public struct SyntaxToken: Equatable, Sendable {
    public let range: NSRange // UTF-16 code units for direct NSAttributedString application
    public let kind: SyntaxTokenKind
}

public enum SyntaxTokenKind: Equatable, Sendable {
    case key, string, number, keyword, comment, tag, attribute, punctuation, header, columnAlt
}

public struct StructuredDocument: Equatable, Sendable {
    public let text: String
    public let tokens: [SyntaxToken]
    public let isPrettified: Bool
    public let isTruncated: Bool
    public let notice: String?
}
```

Per-format behavior:
- **JSON:** Custom token-based pretty-printer (2-space indent) rather than
  `JSONSerialization`, preserving original key order and exact numeric literals (no
  `NSNumber` precision loss on 64-bit ints). On malformed JSON, falls back to raw text with
  JSON syntax coloring and `notice: "Invalid JSON — showing raw"`.
- **XML & `.plist`:**
  - For `.plist` (or any file starting with the `bplist00` magic header when viewed as
    `.plist` / `.xml`): decode via `PropertyListSerialization` and serialize to XML data
    before passing through the XML pipeline. In `.text` mode on a binary `.plist`, show the
    unformatted XML if decodable (or a clear notice if corrupt) rather than garbled binary.
  - Pretty-print via Foundation's `XMLDocument` with `.nodePrettyPrint` and **external
    entity loading disabled** (never pass `.nodeLoadExternalEntitiesAlways`, preventing XXE).
  - Custom XML tokenizer covering tags, attribute names/values, strings, comments, CDATA,
    and processing instructions. Malformed XML falls back to raw text + coloring + notice.
- **CSV / TSV:** RFC 4180-aware parser (quoted fields, escaped quotes, CRLF/LF) that
  formats `.pretty` as padded monospaced aligned columns (per-column width capped at 48
  characters so one wide cell does not push remaining columns off-screen), styling the
  header row (`.header`) and alternating columns (`.columnAlt`). `.text` shows raw,
  unaligned plain text.
- **YAML, TOML, `.properties`:** `.pretty` applies lightweight line/token lexers for
  syntax coloring (preserving existing indentation/layout), while `.text` shows raw
  uncolored plain text:
  - YAML: keys, strings, numbers, booleans/null, comments, anchors/aliases, `---`/`...`
    document markers.
  - TOML: `[table]` / `[[array]]` headers, keys, strings (basic/literal/multiline),
    numbers, ISO dates, booleans, comments.
  - `.properties`: `#`/`!` comments, keys, `=`/`:` delimiters, values, escape sequences.
- **Plain text (and `.text` mode for structured text files):** Decoded UTF-8 (with BOM /
  UTF-16 / Latin-1 fallback), no syntax tokens or reformatting.

### D-d: Bounded reads, 4 GB safety, and background loading (§3)

- Check file size in O(1) (`stat` / `FileMetadata`) before reading any bytes.
- **Full pretty + highlight cap (`maxPrettyBytes = 2 MiB`):** files up to 2 MiB are read,
  formatted, and tokenized off `@MainActor` on a serial background queue with monotonic
  generation cancellation and retained `SecurityScope`.
- **Prefix cap (`maxPrefixBytes = 128 KiB`):** files larger than 2 MiB read only the first
  128 KiB (trimmed to a clean UTF-8 and line boundary), skip full-file pretty-printing,
  apply syntax coloring to the raw prefix, and set `isTruncated = true` with
  `notice: "Showing first 128 KB of <formatted size> — open in Hex or Editor for full file"`.
  (Binary `.plist` over 2 MiB shows a size-limit notice suggesting Hex rather than partial
  binary bytes.)
- `QuickViewItem` never creates an `EditorSession` and never blocks `@MainActor` during
  the 1,000-file cursor sweep.

### D-e: `StructuredTextViewController` and QuickView UI (`BrowserKit`)

- **`StructuredTextViewController`** (`@MainActor`, `BrowserKit`):
  - Hosts an optional subtle notice bar (truncation or malformed-syntax warning) above a
    read-only `NSTextView` inside an `NSScrollView` (monospaced 12 pt font, selectable and
    copyable, non-editable, horizontal scrolling enabled in `.pretty` for aligned CSV/TSV
    and wide JSON/XML, optional soft wrap for plain text).
  - Applies `SyntaxToken`s via semantic `NSColor`s (`.labelColor`, `.systemBlue`,
    `.systemGreen`, `.systemOrange`, `.systemPurple`, `.systemTeal`,
    `.secondaryLabelColor`) and reapplies colors in `viewDidChangeEffectiveAppearance()`
    without re-reading or re-parsing.
  - Loads asynchronously on a serial queue with generation cancellation, matching
    `ReadOnlyHexViewController` and `PreviewPaneViewController`.
- **`QuickViewViewController`** (`BrowserKit`):
  - Reconfigures `modeControl` (`NSSegmentedControl`) from `classification.availableModes`:
    - `[.pretty, .text, .hex]` → `Pretty | Text | Hex`
    - `[.text, .hex]` → `Text | Hex`
    - `[.preview, .hex]` → `Preview | Hex`
    - `[.hex]` → `modeControl.isHidden = true`
  - Adds the compact format override pop-up button (`NSPopUpButton`, pulls-down style) in
    the header for regular files so users can reclassify a file or remember an override for
    its extension.
  - Lazy-creates and hides/clears the three body viewers (`StructuredTextViewController`,
    `QuickLookHostView`, `HexPreviewing`) cleanly on mode switches and `tearDown()`.

### D-f: Deferred items for `docs/PLAN.md` §9

Record in `docs/PLAN.md` §9:
- *Source code syntax highlighting in QuickView* (Swift, Python, Rust, JS, etc.) — revisit
  alongside M9a (`TextEditKit`).
- *Collapsible tree / outline view* for JSON and XML in QuickView.
- *Structured formatting in the compact right Preview Pane* (`PreviewPaneViewController`).

## Commit sequence

Each commit is one logical change, builds, and passes all checks on its own (aiming for
≤ 250 changed lines; 350 hard limit):

1. **`Core:` classification model and format overrides** — `StructuredFormat`,
   `PreviewMode` (`.pretty`, `.text`, `.preview`, `.hex`), `PreviewClassification`,
   updated `PreviewClassifier` (handling rich QL types vs. plain text and extension
   fallback), and `PreviewFormatOverrides` (`UserDefaults`-backed with injectable suite) +
   unit tests. Update existing `QuickViewItem` / `PreviewClassifierTests` callers so the
   tree stays green.
2. **`Core:` `StructuredDocument` model, bounded reader, and plain-text / `.properties`
   lexing** — `SyntaxToken`, `StructuredDocument`, bounded O(1)-size-checked file reader
   (2 MiB full / 128 KiB prefix with UTF-8/line boundary trimming), plain-text decoder, and
   `.properties` tokenizer + unit tests.
3. **`Core:` JSON pretty-printer and tokenizer** — custom token-based JSON pretty-printer
   (preserving key order and exact numbers) and tokenizer, malformed-JSON raw fallback +
   unit tests.
4. **`Core:` XML and binary/XML `.plist` pretty-printer and tokenizer** — `PropertyListSerialization`
   binary-plist decoding, XXE-safe `XMLDocument` pretty-printing, XML tokenizer (tags,
   attributes, comments, CDATA, PIs), malformed fallback + unit tests.
5. **`Core:` YAML and TOML tokenizers** — YAML and TOML line/token lexers + unit tests.
6. **`Core:` CSV and TSV parser, column aligner, and tokenizer** — RFC 4180 parser,
   width-capped monospaced alignment, header/alternating-column tokens, raw fallback + unit
   tests.
7. **`BrowserKit:` `StructuredTextViewController` and QuickView integration** — read-only
   `NSTextView` with semantic Light/Dark theme, notice banner, async generation-cancelled
   loader, contextual `QuickViewViewController` segments (`Pretty | Text | Hex`,
   `Text | Hex`, `Preview | Hex`, Hex-only), format override menu, and `BrowserKitTests`.
8. **`Smoke:` + `Docs:` end-to-end verification and plan updates** — extend
   `SmokeTest+Preview.swift` with real JSON (minified + malformed), XML, binary `.plist`,
   CSV, YAML, unknown binary, large (>2 MiB) truncated file, and format-override checks
   plus the existing 1,000-file cursor sweep; update `docs/PLAN.md` (decisions, architecture
   tables, as-built notes, §9 deferred items).

## Verification

Before every commit (per `AGENTS.md`):
- `swift format lint --strict --recursive TwinPanesKit TwinPanes`
- `swift test --parallel --package-path TwinPanesKit`
- `swift test --sanitize=thread --package-path TwinPanesKit`
- `swift build --package-path TwinPanesKit --triple x86_64-apple-macosx15.0`
- `xcodebuild -project TwinPanes.xcodeproj -scheme TwinPanes -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build`
- `build/DerivedData/Build/Products/Debug/Twin\ Panes.app/Contents/MacOS/Twin\ Panes --smoke-test` (`SMOKE OK`)
