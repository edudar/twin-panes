import Testing

@testable import TwinPanesCore

struct SavePlanTests {
    let opened = PieceTree(originalLength: 100)

    func typed(
        _ tree: PieceTree, at offset: UInt64, add: UInt64, length: UInt64 = 1
    )
        -> PieceTree
    {
        tree.overwriting(at: offset, with: Piece(.add, offset: add, length: length))
    }

    @Test func nothingToWriteWhenNothingChanged() {
        let plan = SavePlan(saved: opened, current: opened, diskMatchesSaved: true)
        #expect(plan.ranges.isEmpty && !plan.writesWholeFile && plan.length == 100)
        #expect(plan.byteCount == 0)
    }

    /// Saved edits that are still there aren't written again; new ones are.
    @Test func writesOnlyWhatChangedSinceTheSave() {
        let saved = typed(opened, at: 5, add: 0, length: 3)
        let current = typed(typed(saved, at: 20, add: 3), at: 21, add: 4)
        let plan = SavePlan(saved: saved, current: current, diskMatchesSaved: true)
        #expect(plan.ranges == [20..<22])
        #expect(plan.byteCount == 2)
    }

    /// Undo past a save: the original bytes come back, so they are what gets written.
    @Test func undoAfterASaveWritesTheOriginalBack() {
        let saved = typed(opened, at: 10, add: 0, length: 4)
        let undone = opened
        #expect(SavePlan(saved: saved, current: undone, diskMatchesSaved: true).ranges == [10..<14])
        // Overwriting part of a saved edit again rewrites only that part.
        let partly = typed(saved, at: 12, add: 7)
        #expect(SavePlan(saved: saved, current: partly, diskMatchesSaved: true).ranges == [12..<13])
    }

    @Test func aChangedDiskOrLengthWritesTheWholeFile() {
        let current = typed(opened, at: 50, add: 0)
        let changed = SavePlan(saved: opened, current: current, diskMatchesSaved: false)
        #expect(changed.writesWholeFile && changed.ranges == [0..<100])
        let longer = opened.inserting(Piece(.add, offset: 0, length: 3), at: 10)
        let grown = SavePlan(saved: opened, current: longer, diskMatchesSaved: true)
        #expect(grown.writesWholeFile && grown.ranges == [0..<103] && grown.length == 103)
        let empty = SavePlan(saved: opened, current: PieceTree(), diskMatchesSaved: true)
        #expect(empty.writesWholeFile && empty.ranges.isEmpty && empty.length == 0)
    }

    /// Random edits, jumps through the history (undo and redo), saves and outside changes
    /// to the file, against a byte model of the file on disk. After every save the disk
    /// holds the current bytes, and a ranged plan writes exactly where the two versions
    /// take their bytes from different places.
    @Test func randomSavesKeepTheDiskInStep() {
        let seed: UInt64 = 0x5A7E_5EED_0000_0003
        var rng = SplitMix64(seed: seed)
        for round in 0..<200 {
            let length = Int.random(in: 0...120, using: &rng)
            let original = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            var add: [UInt8] = []
            func place(_ tree: PieceTree, _ at: UInt64) -> Piece? {
                tree.pieces(in: at..<(at + 1)).first
            }
            func bytes(_ tree: PieceTree) -> [UInt8] {
                tree.pieces(in: 0..<tree.length).flatMap { piece in
                    (piece.source == .original ? original : add)[
                        Int(piece.offset)..<Int(piece.offset + piece.length)]
                }
            }
            var current = PieceTree(originalLength: UInt64(length))
            var history = [current]
            var saved = current
            var disk = original
            var diskMatches = true
            for step in 0..<80 {
                let context: Comment = "seed \(seed), round \(round), step \(step)"
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<5 where length > 0:
                    let offset = Int.random(in: 0..<length, using: &rng)
                    let count = Int.random(in: 1...min(6, length - offset), using: &rng)
                    let piece = Piece(.add, offset: UInt64(add.count), length: UInt64(count))
                    add += (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
                    current = current.overwriting(at: UInt64(offset), with: piece)
                    history.append(current)
                case 5, 6:
                    current = history[Int.random(in: 0..<history.count, using: &rng)]
                case 7 where length > 0:
                    disk[Int.random(in: 0..<length, using: &rng)] &+= 1
                    diskMatches = false
                default:
                    let plan = SavePlan(
                        saved: saved, current: current, diskMatchesSaved: diskMatches)
                    let wanted = bytes(current)
                    #expect(plan.writesWholeFile == !diskMatches, context)
                    var previous: UInt64?
                    for range in plan.ranges {
                        #expect(!range.isEmpty && range.upperBound <= plan.length, context)
                        if let previous { #expect(range.lowerBound > previous, context) }
                        previous = range.upperBound
                        disk.replaceSubrange(
                            Int(range.lowerBound)..<Int(range.upperBound),
                            with: wanted[Int(range.lowerBound)..<Int(range.upperBound)])
                    }
                    if !plan.writesWholeFile {
                        for at in 0..<UInt64(length) {
                            let written = plan.ranges.contains { $0.contains(at) }
                            let same = place(saved, at) == place(current, at)
                            #expect(written == !same, "\(context), offset \(at)")
                        }
                    }
                    #expect(disk == wanted, context)
                    saved = current
                    diskMatches = true
                }
            }
        }
    }
}
