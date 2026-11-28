import Testing

@testable import CoverageReport

@Test func theHeadlineShowsTotalsTestsAndCommit() {
    let html = IndexPage(
        files: sampleFiles, tests: TestCounts(total: 905, failed: 2, skipped: 1), commit: "abc1234"
    ).html

    #expect(html.contains(#"<span class="percent medium">76.4%</span> 107 of 140 lines"#))
    #expect(html.contains("905 tests: 902 passed, 2 failed, 1 skipped"))
    #expect(html.contains(#"<a href="tests.html">Test results</a>"#))
    #expect(html.contains("commit abc1234"))
}

@Test func withoutTestCountsTheHeadlineLeavesTestsOut() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    #expect(!html.contains("tests.html"))
    #expect(!html.contains("commit"))
}

@Test func eachModuleRowShowsItsBarPercentageAndCounts() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    #expect(
        html.contains(
            #"<summary class="row"><span class="name">App</span>"#
                + #"<span class="bar"><span class="fill low" style="width: 70.0%"></span></span>"#
                + #"<span class="percent low">70.0%</span><span class="missed">30</span>"#
                + #"<span class="lines">100</span></summary>"#))
}

@Test func eachFileRowLinksToItsSourcePage() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    #expect(
        html.contains(
            #"<a class="row file" href="coverage/App/UI/View.swift.html""#
                + #" data-name="UI/View.swift" data-percent="70.00" data-missed="30" data-lines="100">"#
                + #"<span class="name">UI/View.swift</span>"#))
}

@Test func theIndexLinksTheSharedStylesheetFromTheRoot() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    #expect(html.contains(#"<link rel="stylesheet" href="report.css">"#))
}

@Test func namesAreEscaped() {
    let html = IndexPage(
        files: [
            FileTotals(relativePath: "A&B/C<D>.swift", lines: LineSummary(count: 1, covered: 1))
        ],
        tests: nil, commit: "<sha>"
    ).html

    #expect(html.contains(#"<span class="name">A&amp;B</span>"#))
    #expect(html.contains(#"<span class="name">C&lt;D&gt;.swift</span>"#))
    #expect(html.contains("commit &lt;sha&gt;"))
}

@Test func theJobSummaryListsTestsTotalsAndModules() {
    let markdown = JobSummary(
        files: sampleFiles, tests: TestCounts(total: 905, failed: 2, skipped: 1), commit: "abc1234"
    ).markdown

    #expect(
        markdown == """
            ### Coverage at abc1234

            **905 tests**: 902 passed, 2 failed, 1 skipped.
            Line coverage of `TwinPanesKit/Sources`: **76.4%** (107 of 140 lines).

            | Module | Line coverage | Missed | Lines |
            | --- | ---: | ---: | ---: |
            | App | 70.0% | 30 | 100 |
            | Core | 92.5% | 3 | 40 |

            """)
}

@Test func theJobSummaryLeavesOutWhatItWasNotGiven() {
    let markdown = JobSummary(files: sampleFiles, tests: nil, commit: nil).markdown

    #expect(markdown.hasPrefix("### Coverage\n\nLine coverage of"))
}

@Test func columnHeadersSortWorstFirstForNumbers() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    #expect(html.contains(#"<button type="button" data-sort="name" data-first="ascending">"#))
    #expect(html.contains(#"<button type="button" data-sort="percent" data-first="ascending">"#))
    #expect(html.contains(#"<button type="button" data-sort="missed" data-first="descending">"#))
    #expect(html.contains(#"<button type="button" data-sort="lines" data-first="descending">"#))
}

@Test func controlsThatNeedTheScriptStartHidden() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    #expect(html.contains(#"<div class="toolbar" data-needs-script hidden>"#))
    #expect(html.contains(#"<div class="row columns" data-needs-script hidden>"#))
    #expect(html.contains(#"<input id="filter" type="search""#))
}

@Test func theLegendStatesTheThresholds() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    #expect(html.contains("90% and up"))
    #expect(html.contains("75% and up"))
    #expect(html.contains("below 75%"))
}

@Test func modulesSitInOneListTheScriptCanReorder() {
    let html = IndexPage(files: sampleFiles, tests: nil, commit: nil).html

    let list = html.range(of: #"<div class="modules">"#)
    let firstModule = html.range(of: #"<details class="module""#)
    #expect(list != nil)
    #expect((list?.upperBound ?? html.endIndex) <= (firstModule?.lowerBound ?? html.startIndex))
}
