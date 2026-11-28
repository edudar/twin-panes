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

    @Test func aChangedDiskWritesTheWholeFile() {
        let current = typed(opened, at: 50, add: 0)
        let changed = SavePlan(saved: opened, current: current, diskMatchesSaved: false)
        #expect(changed.writesWholeFile && changed.ranges == [0..<100])
        let empty = SavePlan(saved: opened, current: PieceTree(), diskMatchesSaved: false)
        #expect(empty.writesWholeFile && empty.ranges.isEmpty && !empty.changesNothing)
    }

    /// The bytes after an insert sit at new offsets, so everything from it on is written.
    @Test func anInsertWritesFromItToTheEnd() {
        let longer = opened.inserting(Piece(.add, offset: 0, length: 3), at: 10)
        let plan = SavePlan(saved: opened, current: longer, diskMatchesSaved: true)
        #expect(!plan.writesWholeFile && plan.ranges == [10..<103] && plan.length == 103)
        let atStart = opened.inserting(Piece(.add, offset: 0, length: 1), at: 0)
        #expect(
            SavePlan(saved: opened, current: atStart, diskMatchesSaved: true).ranges == [0..<101])
    }

    /// An append writes only the new bytes; an edit before it is its own range.
    @Test func anAppendWritesOnlyTheNewBytes() {
        let appended = opened.inserting(Piece(.add, offset: 0, length: 4), at: 100)
        let plan = SavePlan(saved: opened, current: appended, diskMatchesSaved: true)
        #expect(plan.ranges == [100..<104] && plan.byteCount == 4)
        let both = typed(appended, at: 20, add: 4)
        #expect(
            SavePlan(saved: opened, current: both, diskMatchesSaved: true).ranges == [
                20..<21, 100..<104,
            ])
        // An edit on the last shared byte joins the tail.
        let touching = typed(appended, at: 99, add: 5)
        #expect(
            SavePlan(saved: opened, current: touching, diskMatchesSaved: true).ranges == [99..<104])
    }

    /// A delete in the middle shifts the rest back; one at the end only truncates, which
    /// is still something to save.
    @Test func aDeleteWritesTheShiftedRestOrOnlyTruncates() {
        let middle = SavePlan(
            saved: opened, current: opened.removing(40..<50), diskMatchesSaved: true)
        #expect(middle.ranges == [40..<90] && middle.length == 90 && !middle.changesNothing)
        let end = SavePlan(
            saved: opened, current: opened.removing(90..<100), diskMatchesSaved: true)
        #expect(end.ranges.isEmpty && end.length == 90 && !end.writesWholeFile)
        #expect(!end.changesNothing)
        let emptied = SavePlan(saved: opened, current: PieceTree(), diskMatchesSaved: true)
        #expect(emptied.ranges.isEmpty && emptied.length == 0 && !emptied.changesNothing)
        #expect(SavePlan(saved: opened, current: opened, diskMatchesSaved: true).changesNothing)
    }

    /// Random overwrites, inserts and deletes, jumps through the history (undo and redo),
    /// saves and outside changes to the file, against a byte model of the file on disk.
    /// After every save the disk holds the current bytes, and a ranged plan writes
    /// exactly where the two versions take their bytes from different places over the
    /// length they share, and all of the current version past it.
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
                let size = Int(current.length)
                switch Int.random(in: 0..<12, using: &rng) {
                case 0..<3 where size > 0:
                    let offset = Int.random(in: 0..<size, using: &rng)
                    let count = Int.random(in: 1...min(6, size - offset), using: &rng)
                    let piece = Piece(.add, offset: UInt64(add.count), length: UInt64(count))
                    add += (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
                    current = current.overwriting(at: UInt64(offset), with: piece)
                    history.append(current)
                case 3, 4:
                    let offset = Int.random(in: 0...size, using: &rng)
                    let count = Int.random(in: 1...6, using: &rng)
                    let piece = Piece(.add, offset: UInt64(add.count), length: UInt64(count))
                    add += (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
                    current = current.inserting(piece, at: UInt64(offset))
                    history.append(current)
                case 5 where size > 0:
                    let offset = Int.random(in: 0..<size, using: &rng)
                    let count = Int.random(in: 1...min(6, size - offset), using: &rng)
                    current = current.removing(UInt64(offset)..<UInt64(offset + count))
                    history.append(current)
                case 6, 7:
                    current = history[Int.random(in: 0..<history.count, using: &rng)]
                case 8 where !disk.isEmpty:
                    disk[Int.random(in: 0..<disk.count, using: &rng)] &+= 1
                    diskMatches = false
                default:
                    let plan = SavePlan(
                        saved: saved, current: current, diskMatchesSaved: diskMatches)
                    let wanted = bytes(current)
                    #expect(plan.writesWholeFile == !diskMatches, context)
                    #expect(
                        plan.changesNothing
                            == (disk == wanted && plan.ranges.isEmpty && diskMatches), context)
                    if disk.count < wanted.count {
                        disk += [UInt8](repeating: 0, count: wanted.count - disk.count)
                    }
                    var previous: UInt64?
                    for range in plan.ranges {
                        #expect(!range.isEmpty && range.upperBound <= plan.length, context)
                        if let previous { #expect(range.lowerBound > previous, context) }
                        previous = range.upperBound
                        disk.replaceSubrange(
                            Int(range.lowerBound)..<Int(range.upperBound),
                            with: wanted[Int(range.lowerBound)..<Int(range.upperBound)])
                    }
                    disk.removeSubrange(wanted.count...)
                    if !plan.writesWholeFile {
                        let shared = min(saved.length, current.length)
                        for at in 0..<current.length {
                            let written = plan.ranges.contains { $0.contains(at) }
                            let same = at < shared && place(saved, at) == place(current, at)
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
