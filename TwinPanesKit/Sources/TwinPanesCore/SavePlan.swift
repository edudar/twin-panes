/// What a save has to write (docs/plans/M3b.md, D-c): the ranges of the current version
/// that differ from the version on disk, or the whole file when the disk can't be trusted
/// to hold the saved version any more.
public struct SavePlan: Equatable, Sendable {
    /// Ranges of the current version to write over the file, ascending, non-empty and
    /// not touching each other. For a whole-file save, `0..<length` (none when empty).
    public let ranges: [Range<UInt64>]
    /// The file is rewritten from scratch (and truncated to `length`).
    public let writesWholeFile: Bool
    /// The length of the current version, which the file has after the save.
    public let length: UInt64

    /// The plan for saving `current` over a file that holds `saved`. A stretch is written
    /// where the two versions take their bytes from different places (another piece
    /// source or offset); stretches both take from the same place hold the same bytes.
    /// That covers new edits and edits undone since the last save, and skips edits that
    /// were saved already.
    ///
    /// With `diskMatchesSaved` false (the file changed since it was last opened or saved)
    /// or a different length, the plan is the whole file.
    public init(saved: PieceTree, current: PieceTree, diskMatchesSaved: Bool) {
        length = current.length
        guard diskMatchesSaved, saved.length == length else {
            writesWholeFile = true
            ranges = length > 0 ? [0..<length] : []
            return
        }
        writesWholeFile = false
        ranges = Self.differences(saved.pieces(in: 0..<length), current.pieces(in: 0..<length))
    }

    /// Where two versions of the same length take bytes from different places (what the
    /// journal records for a change).
    static func changedRanges(from old: PieceTree, to new: PieceTree) -> [Range<UInt64>] {
        differences(old.pieces(in: 0..<old.length), new.pieces(in: 0..<new.length))
    }

    /// Walks two piece lists of the same total length side by side and returns where they
    /// take bytes from different places, merged.
    private static func differences(_ a: [Piece], _ b: [Piece]) -> [Range<UInt64>] {
        var result: [Range<UInt64>] = []
        var i = 0, j = 0
        var intoA: UInt64 = 0, intoB: UInt64 = 0, position: UInt64 = 0
        while i < a.count, j < b.count {
            let pa = a[i], pb = b[j]
            let step = min(pa.length - intoA, pb.length - intoB)
            if pa.source != pb.source || pa.offset + intoA != pb.offset + intoB {
                if let last = result.last, last.upperBound == position {
                    result[result.count - 1] = last.lowerBound..<(position + step)
                } else {
                    result.append(position..<(position + step))
                }
            }
            position += step
            intoA += step
            intoB += step
            if intoA == pa.length { (i, intoA) = (i + 1, 0) }
            if intoB == pb.length { (j, intoB) = (j + 1, 0) }
        }
        return result
    }

    /// Bytes the save writes.
    public var byteCount: UInt64 { ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
}
