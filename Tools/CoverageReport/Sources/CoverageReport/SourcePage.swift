import Foundation

/// The coverage page of one source file: its code, line by line, marked with what ran.
public struct SourcePage: Sendable {
    /// The file's path below `TwinPanesKit/Sources`, such as `BrowserKit/PathField.swift`.
    public let relativePath: String
    private let sourceLines: [Substring]
    private let coverage: [LineCoverage]

    /// - Parameters:
    ///   - source: the file's text as it was when the tests ran.
    ///   - coverage: one entry per line of `source`, from `LineCoverage.lines(from:lineCount:)`
    ///     with `SourcePage.lineCount(of: source)`. Lines without an entry show as not code.
    public init(relativePath: String, source: String, coverage: [LineCoverage]) {
        self.relativePath = relativePath
        self.sourceLines = Self.lines(of: source)
        self.coverage = coverage
    }

    /// The number of lines in `source`; a final line break doesn't start another line.
    public static func lineCount(of source: String) -> Int {
        lines(of: source).count
    }

    private static func lines(of source: String) -> [Substring] {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    /// Where the page goes, relative to the site's root: `coverage/<relativePath>.html`.
    public var sitePath: String {
        "coverage/\(relativePath).html"
    }

    /// The whole page. Links to the stylesheet and the index are relative, so the site
    /// works from any folder or host.
    public var html: String {
        let root = String(repeating: "../", count: sitePath.split(separator: "/").count - 1)
        let path = escapingHTML(relativePath)
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(path) · Twin Panes coverage</title>
            <link rel="stylesheet" href="\(root)report.css">
            </head>
            <body class="source-page">
            <header class="page-header">
            <nav class="crumbs"><a href="\(root)index.html">Coverage</a> / \(path)</nav>
            \(totalsMarkup)
            </header>
            <main>
            <table class="source">
            <tbody>
            \(rowsMarkup)
            </tbody>
            </table>
            </main>
            </body>
            </html>

            """
    }

    private var totalsMarkup: String {
        let summary = LineSummary(lines: coverage)
        let tier = CoverageTier(covered: summary.covered, total: summary.count)
        let percent =
            summary.count == 0 ? 100 : Double(summary.covered) * 100 / Double(summary.count)
        let missed = coverage.count { $0.state == .missed }
        let partly = coverage.count { $0.state == .partlyCovered }
        return """
            <p class="totals"><span class="percent \(tier.rawValue)">\
            \(String(format: "%.1f%%", percent))</span> \(summary.covered) of \(summary.count) \
            lines · \(missed) missed · \(partly) partly covered</p>
            """
    }

    private var rowsMarkup: String {
        sourceLines.indices.map { index in
            let line =
                index < coverage.count ? coverage[index] : LineCoverage(state: .notCode, count: nil)
            let number = index + 1
            return """
                <tr id="L\(number)" class="\(Self.rowClass(of: line.state))">\
                <td class="number"><a href="#L\(number)">\(number)</a></td>\
                \(Self.countCell(line.count))\
                <td class="code"><code>\(Self.codeMarkup(sourceLines[index], missedSpans: line.missedSpans))</code></td></tr>
                """
        }.joined(separator: "\n")
    }

    private static func rowClass(of state: LineState) -> String {
        switch state {
        case .notCode: "plain"
        case .covered: "covered"
        case .partlyCovered: "partly"
        case .missed: "missed"
        }
    }

    /// llvm-cov clamps a counter that wrapped around to `Int64.max` (see the plan's
    /// D-b); printing it would only mislead.
    private static func countCell(_ count: UInt64?) -> String {
        guard let count else { return #"<td class="count"></td>"# }
        guard count < UInt64(Int64.max) else {
            return #"<td class="count" title="The counter overflowed"></td>"#
        }
        return #"<td class="count">\#(shortened(count))</td>"#
    }

    private static func shortened(_ count: UInt64) -> String {
        guard count >= 10_000 else { return String(count) }
        for (scale, unit) in [(1e9, "G"), (1e6, "M"), (1e3, "k")] where Double(count) >= scale {
            let value = Double(count) / scale
            return String(format: value < 100 ? "%.1f%@" : "%.0f%@", value, unit)
        }
        return String(count)
    }

    /// llvm-cov's columns count UTF-8 bytes, so spans are cut in bytes, not characters.
    private static func codeMarkup(_ line: Substring, missedSpans: [ColumnSpan]) -> String {
        let bytes = Array(line.utf8)
        func text(_ range: Range<Int>) -> String {
            escapingHTML(String(decoding: bytes[range], as: UTF8.self))
        }
        var markup = ""
        var cursor = 0
        for span in missedSpans {
            let start = min(max(span.start - 1, cursor), bytes.count)
            let end = min(max((span.end ?? bytes.count + 1) - 1, start), bytes.count)
            markup +=
                text(cursor..<start) + #"<span class="unrun">"# + text(start..<end) + "</span>"
            cursor = end
        }
        return markup + text(cursor..<bytes.count)
    }
}
