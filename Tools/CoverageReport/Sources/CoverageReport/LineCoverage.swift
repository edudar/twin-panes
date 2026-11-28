/// What one source line's coverage looks like on a page.
public enum LineState: Sendable, Equatable {
    /// No region with a count starts on or runs through the line: blank lines,
    /// comments, declarations, skipped code.
    case notCode
    case covered
    /// Ran, but part of it never did, such as an `else` on the same line.
    case partlyCovered
    case missed
}

/// A run of columns on one line, 1-based like llvm-cov's.
public struct ColumnSpan: Sendable, Equatable {
    public let start: Int
    /// Exclusive; nil when the span runs to the end of the line.
    public let end: Int?

    public init(start: Int, end: Int?) {
        self.start = start
        self.end = end
    }
}

/// One source line's coverage, worked out from the segments the way llvm-cov's own
/// `LineCoverageStats` does, so totals match its reports.
public struct LineCoverage: Sendable, Equatable {
    public let state: LineState
    /// The highest execution count of the regions on the line; nil when not code.
    public let count: UInt64?
    /// The parts of a partly covered line that never ran; empty for other states.
    public let missedSpans: [ColumnSpan]

    public init(state: LineState, count: UInt64?, missedSpans: [ColumnSpan] = []) {
        self.state = state
        self.count = count
        self.missedSpans = missedSpans
    }

    /// The coverage of lines `1...lineCount`, in order.
    ///
    /// Expects `segments` sorted by line, then column, as llvm-cov exports them.
    /// Segments past `lineCount` are ignored.
    public static func lines(from segments: [CoverageSegment], lineCount: Int) -> [LineCoverage] {
        var lines: [LineCoverage] = []
        lines.reserveCapacity(max(lineCount, 0))
        var next = segments.startIndex
        // The last segment of the nearest earlier line that has any: its region is
        // still open at the start of this line.
        var wrapped: CoverageSegment?
        for line in stride(from: 1, through: lineCount, by: 1) {
            let first = next
            while next < segments.endIndex, segments[next].line == line {
                next += 1
            }
            let onLine = segments[first..<next]
            lines.append(LineCoverage(segments: onLine, wrapped: wrapped))
            wrapped = onLine.last ?? wrapped
        }
        return lines
    }

    /// Mirrors `LineCoverageStats` in LLVM's CoverageMapping.cpp, including the rule
    /// that any counted region entry on the line makes it code.
    private init(segments onLine: ArraySlice<CoverageSegment>, wrapped: CoverageSegment?) {
        let regionStarts = onLine.filter { !$0.isGapRegion && $0.hasCount && $0.isRegionEntry }
        let startsSkippedCode = onLine.first.map { !$0.hasCount && $0.isRegionEntry } ?? false
        let isCode =
            (!startsSkippedCode && (wrapped?.hasCount == true || !regionStarts.isEmpty))
            || onLine.contains { $0.isRegionEntry && $0.hasCount }
        guard isCode else {
            self.init(state: .notCode, count: nil)
            return
        }
        let count = max(wrapped?.count ?? 0, regionStarts.map(\.count).max() ?? 0)
        guard count > 0 else {
            self.init(state: .missed, count: 0)
            return
        }
        let missedSpans = Self.missedSpans(segments: onLine, wrapped: wrapped)
        self.init(
            state: missedSpans.isEmpty ? .covered : .partlyCovered, count: count,
            missedSpans: missedSpans)
    }

    /// The column runs where the active region has a count of zero. Gap regions are
    /// whitespace between regions, so they never make a span.
    private static func missedSpans(
        segments onLine: ArraySlice<CoverageSegment>, wrapped: CoverageSegment?
    ) -> [ColumnSpan] {
        var spans: [ColumnSpan] = []
        var active = wrapped
        var activeStart = 1
        func close(at end: Int?) {
            guard let region = active, region.hasCount, region.count == 0, !region.isGapRegion,
                activeStart != end
            else { return }
            if let last = spans.last, last.end == activeStart {
                spans[spans.count - 1] = ColumnSpan(start: last.start, end: end)
            } else {
                spans.append(ColumnSpan(start: activeStart, end: end))
            }
        }
        for segment in onLine {
            close(at: segment.column)
            active = segment
            activeStart = segment.column
        }
        close(at: nil)
        return spans
    }
}

/// How many lines hold code and how many of those ran, each line counted once.
public struct LineSummary: Sendable, Equatable {
    public let count: Int
    public let covered: Int

    public init(count: Int, covered: Int) {
        self.count = count
        self.covered = covered
    }

    public init(lines: [LineCoverage]) {
        self.init(
            count: lines.count { $0.state != .notCode },
            covered: lines.count { $0.state == .covered || $0.state == .partlyCovered })
    }
}
