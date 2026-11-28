import CoverageReport
import Testing

/// A segment where a region ends and no enclosing region resumes.
private func regionEnd(line: Int, column: Int) -> CoverageSegment {
    CoverageSegment(line: line, column: column, count: 0, hasCount: false, isRegionEntry: false)
}

@Test func linesWithoutSegmentsAreNotCode() {
    let lines = LineCoverage.lines(from: [], lineCount: 2)

    #expect(
        lines == [
            LineCoverage(state: .notCode, count: nil), LineCoverage(state: .notCode, count: nil),
        ])
}

@Test func aRegionCoversEveryLineItRunsThrough() {
    let segments = [CoverageSegment(line: 1, column: 1, count: 5), regionEnd(line: 3, column: 10)]

    let lines = LineCoverage.lines(from: segments, lineCount: 4)

    #expect(lines.map(\.state) == [.covered, .covered, .covered, .notCode])
    #expect(lines.map(\.count) == [5, 5, 5, nil])
}

@Test func aRegionThatNeverRanMarksItsLinesMissed() {
    let segments = [CoverageSegment(line: 1, column: 1, count: 0), regionEnd(line: 2, column: 2)]

    let lines = LineCoverage.lines(from: segments, lineCount: 2)

    #expect(
        lines == [LineCoverage(state: .missed, count: 0), LineCoverage(state: .missed, count: 0)])
}

@Test func aLineWithARegionThatNeverRanIsPartlyCovered() {
    // if ready { start() } else { wait() }
    let segments = [
        CoverageSegment(line: 1, column: 1, count: 3),
        CoverageSegment(line: 1, column: 22, count: 0),
        CoverageSegment(line: 1, column: 38, count: 3, isRegionEntry: false),
        regionEnd(line: 1, column: 39),
    ]

    let lines = LineCoverage.lines(from: segments, lineCount: 1)

    #expect(
        lines == [
            LineCoverage(
                state: .partlyCovered, count: 3,
                missedSpans: [ColumnSpan(start: 22, end: 38)])
        ])
}

@Test func aMissedRegionCarriedFromThePreviousLineIsAMissedSpan() {
    let segments = [
        CoverageSegment(line: 1, column: 1, count: 0),
        CoverageSegment(line: 2, column: 5, count: 2),
        CoverageSegment(line: 2, column: 9, count: 0, isRegionEntry: false),
        regionEnd(line: 3, column: 1),
    ]

    let lines = LineCoverage.lines(from: segments, lineCount: 2)

    #expect(
        lines[1]
            == LineCoverage(
                state: .partlyCovered, count: 2,
                missedSpans: [ColumnSpan(start: 1, end: 5), ColumnSpan(start: 9, end: nil)]))
}

@Test func aLineStartingSkippedCodeIsNotCode() {
    let segments = [
        CoverageSegment(line: 1, column: 1, count: 4),
        CoverageSegment(line: 2, column: 1, count: 0, hasCount: false),
        regionEnd(line: 2, column: 20),
    ]

    let lines = LineCoverage.lines(from: segments, lineCount: 2)

    #expect(lines[1] == LineCoverage(state: .notCode, count: nil))
}

@Test func aGapRegionNeverCountsAsMissed() {
    let segments = [
        CoverageSegment(line: 1, column: 1, count: 3),
        CoverageSegment(line: 1, column: 8, count: 0, isGapRegion: true),
        regionEnd(line: 2, column: 1),
    ]

    let lines = LineCoverage.lines(from: segments, lineCount: 1)

    #expect(lines == [LineCoverage(state: .covered, count: 3)])
}

@Test func segmentsPastTheLastLineAreIgnored() {
    let segments = [
        CoverageSegment(line: 1, column: 1, count: 1),
        CoverageSegment(line: 5, column: 1, count: 0),
    ]

    let lines = LineCoverage.lines(from: segments, lineCount: 2)

    #expect(lines.count == 2)
    #expect(lines.map(\.state) == [.covered, .covered])
}

@Test func theSummaryCountsCodeLinesAndTheOnesThatRan() {
    let lines = [
        LineCoverage(state: .covered, count: 1),
        LineCoverage(
            state: .partlyCovered, count: 1, missedSpans: [ColumnSpan(start: 3, end: nil)]),
        LineCoverage(state: .missed, count: 0),
        LineCoverage(state: .notCode, count: nil),
    ]

    #expect(LineSummary(lines: lines) == LineSummary(count: 3, covered: 2))
}
