import Testing

@testable import CoverageReport

/// The markup of line `number`, from its `<tr>` to its `</tr>`.
private func row(_ number: Int, of page: SourcePage) throws -> Substring {
    let html = page.html
    let start = try #require(html.range(of: "<tr id=\"L\(number)\""))
    let end = try #require(html.range(of: "</tr>", range: start.upperBound..<html.endIndex))
    return html[start.lowerBound..<end.upperBound]
}

private func page(
    _ source: String, _ coverage: [LineCoverage], path: String = "Kit/File.swift"
)
    -> SourcePage
{
    SourcePage(relativePath: path, source: source, coverage: coverage)
}

@Test func thePageGoesUnderCoverageWithAnHTMLSuffix() {
    #expect(page("", []).sitePath == "coverage/Kit/File.swift.html")
}

@Test func aFinalLineBreakDoesNotStartAnotherLine() {
    #expect(SourcePage.lineCount(of: "a\nb\n") == 2)
    #expect(SourcePage.lineCount(of: "a\nb") == 2)
    #expect(SourcePage.lineCount(of: "\n") == 1)
    #expect(SourcePage.lineCount(of: "") == 0)
}

@Test func eachLineCarriesItsStateAndCount() throws {
    let page = page(
        "a\nb\nc\nd\n",
        [
            LineCoverage(state: .covered, count: 7),
            LineCoverage(
                state: .partlyCovered, count: 2, missedSpans: [ColumnSpan(start: 1, end: nil)]),
            LineCoverage(state: .missed, count: 0),
            LineCoverage(state: .notCode, count: nil),
        ])

    #expect(try row(1, of: page).contains(#"class="covered""#))
    #expect(try row(1, of: page).contains(#"<td class="count">7</td>"#))
    #expect(try row(2, of: page).contains(#"class="partly""#))
    #expect(try row(3, of: page).contains(#"class="missed""#))
    #expect(try row(3, of: page).contains(#"<td class="count">0</td>"#))
    #expect(try row(4, of: page).contains(#"class="plain""#))
    #expect(try row(4, of: page).contains(#"<td class="count"></td>"#))
}

@Test func linesWithoutCoverageShowAsNotCode() throws {
    let page = page("a\nb\n", [LineCoverage(state: .covered, count: 1)])

    #expect(try row(2, of: page).contains(#"class="plain""#))
}

@Test func largeCountsAreShortened() throws {
    let page = page(
        "a\nb\nc\n",
        [
            LineCoverage(state: .covered, count: 9_999),
            LineCoverage(state: .covered, count: 12_345),
            LineCoverage(state: .covered, count: 2_500_000),
        ])

    #expect(try row(1, of: page).contains(">9999<"))
    #expect(try row(2, of: page).contains(">12.3k<"))
    #expect(try row(3, of: page).contains(">2.5M<"))
}

@Test func anOverflowedCountIsNotPrinted() throws {
    let page = page("a\n", [LineCoverage(state: .covered, count: UInt64(Int64.max))])

    let markup = try row(1, of: page)

    #expect(!markup.contains("9223372036854775807"))
    #expect(markup.contains(#"<td class="count" title="The counter overflowed"></td>"#))
}

@Test func neverRunSpansAreCutAtUTF8Columns() throws {
    // "é" takes columns 6 and 7, so "??" starts at column 10.
    let source = "x = \"é\" ?? y\nx = \"é\" ?? y\n"
    let page = page(
        source,
        [
            LineCoverage(
                state: .partlyCovered, count: 1, missedSpans: [ColumnSpan(start: 10, end: 12)]),
            LineCoverage(
                state: .partlyCovered, count: 1, missedSpans: [ColumnSpan(start: 13, end: nil)]),
        ])

    #expect(try row(1, of: page).contains(#"&quot;é&quot; <span class="unrun">??</span> y"#))
    #expect(try row(2, of: page).contains(#"?? <span class="unrun">y</span>"#))
}

@Test func sourceTextIsEscaped() throws {
    let page = page("let a: Array<Int> = b && \"q\"\n", [LineCoverage(state: .covered, count: 1)])

    #expect(try row(1, of: page).contains("Array&lt;Int&gt; = b &amp;&amp; &quot;q&quot;"))
}

@Test func linksAreRelativeToThePagesDepth() {
    let html = page("", [], path: "Kit/Sub/File.swift").html

    #expect(html.contains(#"href="../../../report.css""#))
    #expect(html.contains(#"href="../../../index.html""#))
}

@Test func theHeaderShowsTheFilesLineTotals() {
    let html = page(
        "a\nb\nc\nd\ne\n",
        [
            LineCoverage(state: .covered, count: 1),
            LineCoverage(
                state: .partlyCovered, count: 1, missedSpans: [ColumnSpan(start: 1, end: nil)]),
            LineCoverage(state: .covered, count: 1),
            LineCoverage(state: .missed, count: 0),
            LineCoverage(state: .notCode, count: nil),
        ]
    ).html

    #expect(html.contains(#"<span class="percent medium">75.0%</span>"#))
    #expect(html.contains("3 of 4 lines"))
    #expect(html.contains("1 missed"))
    #expect(html.contains("1 partly covered"))
}

@Test func thePathIsEscapedInTheTitle() {
    let html = page("", [], path: "Kit/A&B.swift").html

    #expect(html.contains("<title>Kit/A&amp;B.swift"))
}

@Test func tiersSplitAtNinetyAndSeventyFivePercent() {
    #expect(CoverageTier(covered: 90, total: 100) == .high)
    #expect(CoverageTier(covered: 89, total: 100) == .medium)
    #expect(CoverageTier(covered: 75, total: 100) == .medium)
    #expect(CoverageTier(covered: 74, total: 100) == .low)
    #expect(CoverageTier(covered: 0, total: 0) == .high)
}

@Test func escapingCoversTheCharactersHTMLGivesMeaningTo() {
    #expect(escapingHTML(#"<a href="x">&"#) == "&lt;a href=&quot;x&quot;&gt;&amp;")
}

@Test func theMinimapMarksEachRunOfMissesWhereItSitsInTheFile() {
    var coverage = Array(repeating: LineCoverage(state: .covered, count: 1), count: 10)
    coverage[2] = LineCoverage(state: .missed, count: 0)
    coverage[5] = LineCoverage(
        state: .partlyCovered, count: 1, missedSpans: [ColumnSpan(start: 1, end: nil)])
    coverage[6] = LineCoverage(state: .missed, count: 0)

    let html = page(String(repeating: "x\n", count: 10), coverage).html

    #expect(
        html.contains(##"<a class="mark missed" href="#L3" style="top: 20.00%; height: 10.00%">"##))
    #expect(
        html.contains(##"<a class="mark missed" href="#L6" style="top: 50.00%; height: 20.00%">"##))
    #expect(html.components(separatedBy: #"class="mark"#).count == 3)
}

@Test func aRunOfOnlyPartlyCoveredLinesIsMarkedPartly() {
    let html = page(
        "x\n",
        [
            LineCoverage(
                state: .partlyCovered, count: 1, missedSpans: [ColumnSpan(start: 1, end: nil)])
        ]
    ).html

    #expect(html.contains(##"<a class="mark partly" href="#L1""##))
}

@Test func aFileWithNothingMissedHasNoMinimap() {
    let html = page("x\n", [LineCoverage(state: .covered, count: 1)]).html

    #expect(!html.contains(#"class="minimap""#))
}
