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

    @Test func emptyFile() {
        var selection = HexSelection(length: 0)
        selection.move(by: 5)
        #expect(selection.cursor == 0)
        #expect(selection.range.isEmpty)
    }

    @Test func copyFormats() {
        let bytes = Data([0x4F, 0x2A, 0x00, 0x41])
        #expect(HexCopy.string(bytes, as: .hex) == "4F 2A 00 41")
        #expect(HexCopy.string(bytes, as: .text(.ascii)) == "O*.A")
    }
}
