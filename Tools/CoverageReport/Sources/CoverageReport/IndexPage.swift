import Foundation

/// The site's front page: the run's headline and every module, each folding out its files.
public struct IndexPage: Sendable {
    public static let sitePath = "index.html"
    /// The JUnit page `scripts/test-report.sh` writes beside this one.
    static let testResultsPath = "tests.html"

    private let modules: [ModuleTotals]
    private let tests: TestCounts?
    private let commit: String?

    /// - Parameters:
    ///   - tests: the run's test counts; nil leaves tests out of the headline.
    ///   - commit: the commit the report was built from, shown as given.
    public init(files: [FileTotals], tests: TestCounts?, commit: String?) {
        self.modules = ModuleTotals.grouping(files)
        self.tests = tests
        self.commit = commit
    }

    public var html: String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Twin Panes coverage</title>
        <link rel="stylesheet" href="\(SiteStylesheet.fileName)">
        </head>
        <body class="index-page">
        <header class="page-header">
        <h1>Twin Panes coverage</h1>
        \(headlineMarkup)
        </header>
        <main>
        <p class="legend"><span class="key high"></span>90% and up \
        <span class="key medium"></span>75% and up <span class="key low"></span>below 75%</p>
        <div class="toolbar" data-needs-script hidden>
        <input id="filter" type="search" placeholder="Filter files" aria-label="Filter files">
        </div>
        <div class="row columns" data-needs-script hidden>\
        <button type="button" data-sort="name" data-first="ascending">File</button><span class="bar"></span>\
        <button type="button" data-sort="percent" data-first="ascending">Lines</button>\
        <button type="button" data-sort="missed" data-first="descending">Missed</button>\
        <button type="button" data-sort="lines" data-first="descending">Total</button></div>
        <div class="modules">
        \(modules.map(Self.moduleMarkup).joined(separator: "\n"))
        </div>
        </main>
        <script>\(Self.sortAndFilterScript)</script>
        </body>
        </html>

        """
    }

    private var headlineMarkup: String {
        let total = LineSummary(adding: modules.map(\.lines))
        var parts = [
            #"<span class="percent \#(total.tier.rawValue)">\#(total.percentText)</span> "#
                + "\(groupingDigits(total.covered)) of \(groupingDigits(total.count)) lines"
        ]
        if let tests {
            parts.append(
                "\(groupingDigits(tests.total)) tests: \(groupingDigits(tests.passed)) passed, "
                    + "\(groupingDigits(tests.failed)) failed, \(groupingDigits(tests.skipped)) skipped"
            )
            parts.append(#"<a href="\#(Self.testResultsPath)">Test results</a>"#)
        }
        if let commit {
            parts.append("commit \(escapingHTML(commit))")
        }
        return #"<p class="totals">"# + parts.joined(separator: " · ") + "</p>"
    }

    /// Shows the controls, sorts modules and the files inside each by the clicked column
    /// (a second click reverses it), and filters files by path, opening the modules
    /// that still have matches. Without scripts the modules still fold out by hand.
    private static let sortAndFilterScript = """
        (() => {
          const list = document.querySelector(".modules");
          const modules = [...list.querySelectorAll("details.module")];
          const buttons = [...document.querySelectorAll("button[data-sort]")];
          const filter = document.getElementById("filter");
          document.querySelectorAll("[data-needs-script]").forEach(element => element.hidden = false);
          let key = "name";
          let ascending = true;
          const value = row => key === "name" ? row.dataset.name.toLowerCase() : parseFloat(row.dataset[key]);
          const order = (a, b) => {
            const [x, y] = [value(a), value(b)];
            return (x < y ? -1 : x > y ? 1 : 0) * (ascending ? 1 : -1);
          };
          const sort = () => {
            for (const module of modules.sort(order)) {
              module.append(...[...module.querySelectorAll("a.file")].sort(order));
              list.append(module);
            }
            for (const button of buttons) {
              button.dataset.direction = button.dataset.sort === key ? (ascending ? "ascending" : "descending") : "";
            }
          };
          for (const button of buttons) {
            button.addEventListener("click", () => {
              ascending = button.dataset.sort === key ? !ascending : button.dataset.first === "ascending";
              key = button.dataset.sort;
              sort();
            });
          }
          filter.addEventListener("input", () => {
            const query = filter.value.trim().toLowerCase();
            for (const module of modules) {
              let hasMatch = false;
              for (const file of module.querySelectorAll("a.file")) {
                const path = (module.dataset.name + "/" + file.dataset.name).toLowerCase();
                file.hidden = query !== "" && !path.includes(query);
                hasMatch = hasMatch || !file.hidden;
              }
              module.hidden = !hasMatch;
              module.open = query !== "" && hasMatch;
            }
          });
          sort();
        })();
        """

    /// A `<details>` per module, so its files fold out without any script.
    private static func moduleMarkup(_ module: ModuleTotals) -> String {
        let files = module.files.map { file in
            let name = String(file.relativePath.dropFirst(module.name.count + 1))
            return
                #"<a class="row file" href="\#(escapingHTML(SourcePage.sitePath(for: file.relativePath)))""#
                + "\(sortKeys(name: name, lines: file.lines))>\(cells(name: name, lines: file.lines))</a>"
        }
        return """
            <details class="module"\(sortKeys(name: module.name, lines: module.lines))>
            <summary class="row">\(cells(name: module.name, lines: module.lines))</summary>
            \(files.joined(separator: "\n"))
            </details>
            """
    }

    /// The values the index's sort script orders rows by, unformatted
    /// (docs/plans/coverage-report.md, step 3b).
    private static func sortKeys(name: String, lines: LineSummary) -> String {
        #" data-name="\#(escapingHTML(name))""#
            + #" data-percent="\#(String(format: "%.2f", lines.percent))""#
            + #" data-missed="\#(lines.count - lines.covered)" data-lines="\#(lines.count)""#
    }

    private static func cells(name: String, lines: LineSummary) -> String {
        let tier = lines.tier.rawValue
        return #"<span class="name">\#(escapingHTML(name))</span>"#
            + #"<span class="bar"><span class="fill \#(tier)" style="width: \#(lines.percentText)"></span></span>"#
            + #"<span class="percent \#(tier)">\#(lines.percentText)</span>"#
            + #"<span class="missed">\#(groupingDigits(lines.count - lines.covered))</span>"#
            + #"<span class="lines">\#(groupingDigits(lines.count))</span>"#
    }
}
