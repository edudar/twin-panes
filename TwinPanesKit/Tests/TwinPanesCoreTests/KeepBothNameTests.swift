import Testing

@testable import TwinPanesCore

/// Finder's Keep Both names (docs/plans/M6.md, D-d, step 7).
@Suite struct KeepBothNameTests {
    @Test func keepBothNamesCountUp() {
        let taken: Set = ["a.txt", "a 2.txt", "docs", "v 3"]
        #expect(KeepBothName.next(for: "a.txt") { taken.contains($0) } == "a 3.txt")
        #expect(KeepBothName.next(for: "docs") { taken.contains($0) } == "docs 2")
        #expect(KeepBothName.next(for: "v 3") { taken.contains($0) } == "v 4")
        #expect(KeepBothName.next(for: ".profile") { _ in false } == ".profile 2")
    }
}
