import Foundation
import Testing

@testable import HexViewKit

@Suite struct HexScrollPositionTests {
    @Test func scrollsAndClamps() {
        var position = HexScrollPosition(rowCount: 100, rowHeight: 16, viewHeight: 160)
        #expect(position.maxOffset == 1440)
        position.scroll(by: 40)
        #expect(position.topRow == 2)
        #expect(position.topRowInset == 8)
        #expect(position.visibleRows == 2..<13)
        position.scroll(by: 1e9)
        #expect(position.offset == 1440)
        #expect(position.visibleRows.upperBound == 100)
        position.scroll(by: -1e9)
        #expect(position.offset == 0)
    }

    @Test func fourGigabytesAtSixteenBytesPerRowIsExact() {
        let rows: UInt64 = (4 << 30) / 16
        var position = HexScrollPosition(rowCount: rows, rowHeight: 16, viewHeight: 800)
        position.setKnobValue(1)
        #expect(position.visibleRows.upperBound == rows)
        position.scrollToTop(row: rows - 1000)
        #expect(position.topRow == rows - 1000)
        position.scroll(by: 1)
        #expect(position.topRowInset == 1)
    }

    @Test func revealScrollsMinimally() {
        var position = HexScrollPosition(rowCount: 100, rowHeight: 10, viewHeight: 100)
        position.reveal(row: 5)
        #expect(position.offset == 0)
        position.reveal(row: 20)
        #expect(position.offset == 110)
        position.reveal(row: 3)
        #expect(position.offset == 30)
    }

    @Test func viewTallerThanContent() {
        var position = HexScrollPosition(rowCount: 3, rowHeight: 16, viewHeight: 500)
        position.scroll(by: 100)
        #expect(position.offset == 0)
        #expect(position.knobProportion == 1)
        #expect(position.visibleRows == 0..<3)
    }
}

@Suite struct HexSelectionTests {
    @Test func movesAndExtends() {
        var selection = HexSelection(length: 100)
        selection.move(to: 10)
        selection.move(by: 5, extending: true)
        #expect(selection.range == 10..<16)
        selection.move(by: -20, extending: true)
        #expect(selection.range == 0..<11)
        selection.move(by: 1000)
        #expect(selection.range == 99..<100)
        selection.selectAll()
        #expect(selection.range == 0..<100)
    }

    @Test func selectsARange() {
        var selection = HexSelection(length: 100)
        selection.select(10..<14)
        #expect(selection.range == 10..<14)
        #expect(selection.cursor == 13)
        selection.select(98..<120)
        #expect(selection.range == 98..<100)
        selection.select(5..<5)
        #expect(selection.range == 5..<6)
    }

    @Test func emptyFile() {
        var selection = HexSelection(length: 0)
        selection.move(by: 5)
        #expect(selection.cursor == 0)
        #expect(selection.range.isEmpty)
    }

    @Test func reachesThePositionAfterTheLastByteInInsertMode() {
        var selection = HexSelection(length: 100, includesEndPosition: true)
        selection.move(to: .max)
        #expect(selection.cursor == 100 && selection.range == 100..<100)
        selection.move(to: 99)
        selection.move(by: 1)
        #expect(selection.cursor == 100)
        selection.move(to: 95, extending: true)
        #expect(selection.range == 95..<100)  // the end position holds no byte
        selection.select(100..<100)
        #expect(selection.range == 100..<100)
        selection.selectAll()
        #expect(selection.range == 0..<100)
    }

    @Test func turningInsertModeOffMovesTheCursorBackOntoTheLastByte() {
        var selection = HexSelection(length: 100, includesEndPosition: true)
        selection.move(to: .max)
        selection.move(to: 100, extending: true)
        selection.includesEndPosition = false
        #expect(selection.cursor == 99 && selection.anchor == 99 && selection.range == 99..<100)
    }

    /// An empty file has one place to type in insert mode, and no byte to select.
    @Test func anEmptyFileHasOnePositionInInsertMode() {
        var selection = HexSelection(length: 0, includesEndPosition: true)
        selection.move(by: 5)
        #expect(selection.cursor == 0 && selection.range == 0..<0)
    }

    @Test func copyFormats() {
        let bytes = Data([0x4F, 0x2A, 0x00, 0x41])
        #expect(HexCopy.string(bytes, as: .hex) == "4F 2A 00 41")
        #expect(HexCopy.string(bytes, as: .text(.ascii)) == "O*.A")
    }

    @Test func findsTheFirstHighlightReachingARow() {
        let ranges: [Range<UInt64>] = [0..<2, 10..<20, 40..<41]
        #expect(ranges.partitioningIndex { $0.upperBound > 0 } == 0)
        #expect(ranges.partitioningIndex { $0.upperBound > 2 } == 1)
        #expect(ranges.partitioningIndex { $0.upperBound > 19 } == 1)
        #expect(ranges.partitioningIndex { $0.upperBound > 20 } == 2)
        #expect(ranges.partitioningIndex { $0.upperBound > 41 } == 3)
        #expect([Range<UInt64>]().partitioningIndex { _ in true } == 0)
    }
}
