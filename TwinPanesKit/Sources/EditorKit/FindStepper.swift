import HexViewKit
import TwinPanesCore

/// Where find next/previous goes, as pure functions of the selection and the last match
/// (PLAN.md §4.10), so the rules are testable without a window.
enum FindStepper {
    /// The offset a search starts from. Forward starts at the selection, or just after it
    /// when it is the match find selected last (so "next" moves on); backward finds
    /// matches starting before the selection.
    static func searchStart(
        _ direction: Searcher.Direction, selected: Range<UInt64>, lastMatch: Range<UInt64>?
    ) -> UInt64 {
        direction == .forward && selected == lastMatch
            ? selected.lowerBound + 1 : selected.lowerBound
    }

    /// The index in `ranges` (sorted, from Find All) to select next, wrapping around at
    /// either end; nil when there are none.
    static func index(
        in ranges: [Range<UInt64>], _ direction: Searcher.Direction,
        selected: Range<UInt64>, lastMatch: Range<UInt64>?
    ) -> Int? {
        guard !ranges.isEmpty else { return nil }
        let start = searchStart(direction, selected: selected, lastMatch: lastMatch)
        let firstAtOrAfter = ranges.partitioningIndex { $0.lowerBound >= start }
        switch direction {
        case .forward:
            return firstAtOrAfter < ranges.count ? firstAtOrAfter : 0
        case .backward:
            return firstAtOrAfter > 0 ? firstAtOrAfter - 1 : ranges.count - 1
        }
    }
}
