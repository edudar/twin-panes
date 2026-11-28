/// The stylesheet every page of the site links, written once next to `index.html`.
///
/// Every colour is a token with a light and a dark value; the page follows the
/// viewer's system setting. Covered code stays plain to read: only the 3 px stripe
/// beside the count says it ran, and only missed lines get a background
/// (docs/plans/coverage-report.md, D-d).
public enum SiteStylesheet {
    public static let fileName = "report.css"

    public static let contents = """
        :root {
          --bg: #fbfbfc; --surface: #ffffff; --fg: #1c1f23; --muted: #6a737d; --line: #e3e6ea;
          --accent: #2f5fb3; --target: #e8effb;
          --hit: #2e8540; --partial: #b7791f; --miss: #c2362f;
          --miss-soft: #fdecea; --unrun-soft: #f7d4d0;
          --sans: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          --mono: ui-monospace, "SF Mono", Menlo, monospace;
          color-scheme: light;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #15171a; --surface: #1b1e22; --fg: #e4e7eb; --muted: #8f98a3; --line: #2a2f35;
            --accent: #7aa2ec; --target: #1f2a3d;
            --hit: #5cbf72; --partial: #e0a84a; --miss: #ef6b63;
            --miss-soft: #3a1f1e; --unrun-soft: #5c2623;
            color-scheme: dark;
          }
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.5 var(--sans); }
        a { color: var(--accent); }

        .page-header {
          position: sticky; top: 0; z-index: 2;
          display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 20px;
          padding: 10px 26px 10px 16px;
          background: var(--surface); border-bottom: 1px solid var(--line);
        }
        .crumbs { font: 13px var(--mono); overflow-wrap: anywhere; }
        .crumbs a { text-decoration: none; }
        .totals { margin: 0; color: var(--muted); font-variant-numeric: tabular-nums; }
        .percent { font-weight: 600; }
        .percent.high { color: var(--hit); }
        .percent.medium { color: var(--partial); }
        .percent.low { color: var(--miss); }

        /* Wide lines scroll inside main, never the page; the right padding keeps code
           clear of the minimap. */
        .source-page main { overflow-x: auto; padding-right: 12px; }
        .source { border-collapse: collapse; font: 12.5px/1.6 var(--mono); min-width: 100%; }
        .source td { padding: 0; vertical-align: top; }
        .source td.number, .source td.count {
          width: 1%; text-align: right; white-space: nowrap; user-select: none;
          color: var(--muted); font-variant-numeric: tabular-nums;
        }
        .source td.number { padding-left: 16px; padding-right: 10px; }
        .source td.number a { color: inherit; text-decoration: none; }
        .source td.count { padding-right: 8px; border-right: 3px solid transparent; }
        .source td.code { padding-left: 12px; white-space: pre; }
        /* --header-height is set by the page script; the header wraps on narrow screens. */
        .source tr { scroll-margin-top: calc(var(--header-height, 3rem) + 24px); }
        .source tr.covered td.count { border-right-color: var(--hit); }
        .source tr.partly td.count { border-right-color: var(--partial); }
        .source tr.missed td.count { border-right-color: var(--miss); }
        .source tr.missed td.code { background: var(--miss-soft); }
        .source tr:target td { background: var(--target); }
        .unrun {
          background: var(--unrun-soft);
          text-decoration: underline wavy var(--miss) 1px; text-underline-offset: 3px;
        }

        /* Above the sticky header, so every mark stays reachable. */
        .minimap {
          position: fixed; top: 0; bottom: 0; right: 0; z-index: 3; width: 10px;
          background: var(--surface); border-left: 1px solid var(--line);
        }
        .minimap .mark { position: absolute; left: 1px; right: 1px; min-height: 3px; }
        .minimap .mark.missed { background: var(--miss); }
        .minimap .mark.partly { background: var(--partial); }
        """
}
