import Testing

@testable import EditorKit

@Suite struct FindStepperTests {
    let matches: [Range<UInt64>] = [10..<13, 50..<53, 90..<93]

    @Test func searchStartsAtTheSelectionUnlessItIsTheLastMatch() {
        #expect(FindStepper.searchStart(.forward, selected: 10..<11, lastMatch: nil) == 10)
        #expect(FindStepper.searchStart(.forward, selected: 10..<13, lastMatch: 10..<13) == 11)
        #expect(FindStepper.searchStart(.forward, selected: 10..<13, lastMatch: 50..<53) == 10)
        #expect(FindStepper.searchStart(.backward, selected: 10..<13, lastMatch: 10..<13) == 10)
    }

    @Test func forwardFindsTheMatchAtTheCursorThenMovesOn() {
        #expect(FindStepper.index(in: matches, .forward, selected: 10..<11, lastMatch: nil) == 0)
        #expect(
            FindStepper.index(in: matches, .forward, selected: 10..<13, lastMatch: 10..<13) == 1)
        #expect(FindStepper.index(in: matches, .forward, selected: 60..<61, lastMatch: nil) == 2)
    }

    @Test func wrapsAtBothEnds() {
        #expect(
            FindStepper.index(in: matches, .forward, selected: 90..<93, lastMatch: 90..<93) == 0)
        #expect(FindStepper.index(in: matches, .forward, selected: 95..<96, lastMatch: nil) == 0)
        #expect(FindStepper.index(in: matches, .backward, selected: 10..<13, lastMatch: nil) == 2)
        #expect(FindStepper.index(in: matches, .backward, selected: 5..<6, lastMatch: nil) == 2)
    }

    @Test func backwardFindsTheMatchBeforeTheSelection() {
        #expect(FindStepper.index(in: matches, .backward, selected: 50..<53, lastMatch: nil) == 0)
        #expect(FindStepper.index(in: matches, .backward, selected: 70..<71, lastMatch: nil) == 1)
    }

    @Test func noMatchesMeansNoIndex() {
        #expect(FindStepper.index(in: [], .forward, selected: 0..<1, lastMatch: nil) == nil)
    }
}
