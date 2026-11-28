import Foundation
import Testing

@testable import HexViewKit

@Suite struct HexLayoutTests {
    @Test func defaultLayoutColumns() {
        let layout = HexLayout(options: HexViewOptions(), length: 1000)
        #expect(layout.bytesPerRow == 16)
        #expect(layout.offsetCells == 8)
        #expect(layout.hexStart == 10)
        // Byte 0 at 10, byte 1 at 13 (one space), byte 8 has an extra space.
        #expect(layout.hexCell(0) == 10)
        #expect(layout.hexCell(1) == 13)
        #expect(layout.hexCell(8) == 10 + 16 + 8 + 1)
        #expect(layout.textStart == layout.hexCell(15) + 2 + 2)
        #expect(layout.rowCount == 63)
    }

    /// The position after the last byte starts a row of its own when the file fills its
    /// last row, and its offset can need one more digit.
    @Test func theEndPositionCanNeedARowOfItsOwn() {
        func rows(_ length: UInt64, _ end: Bool) -> UInt64 {
            HexLayout(options: HexViewOptions(), length: length, includesEndPosition: end)
                .rowCount
        }
        #expect(rows(32, false) == 2 && rows(32, true) == 3)
        #expect(rows(31, false) == 2 && rows(31, true) == 2)
        #expect(rows(0, false) == 1 && rows(0, true) == 1)
        let full = HexLayout(options: HexViewOptions(), length: 1 << 32)
        let end = HexLayout(options: HexViewOptions(), length: 1 << 32, includesEndPosition: true)
        #expect(full.offsetCells == 8 && end.offsetCells == 9)
    }

    @Test func groupingRemovesInnerSpaces() {
        let g2 = HexLayout(options: HexViewOptions(grouping: 2), length: 64)
        #expect(g2.hexCell(1) - g2.hexCell(0) == 2)
        #expect(g2.hexCell(2) - g2.hexCell(1) == 3)
        let g4 = HexLayout(options: HexViewOptions(grouping: 4), length: 64)
        #expect(g4.hexCell(1) - g4.hexCell(0) == 2)
        #expect(g4.hexCell(4) - g4.hexCell(3) == 3)
        #expect(g4.hexCell(8) - g4.hexCell(7) == 4)
        // Grouping of 8 has a single space between 8-byte groups, not a double gap.
        let g8 = HexLayout(options: HexViewOptions(grouping: 8), length: 64)
        #expect(g8.hexCell(7) - g8.hexCell(6) == 2)
        #expect(g8.hexCell(8) - g8.hexCell(7) == 3)
    }

    @Test func offsetWidthGrowsWithFile() {
        let small = HexLayout(options: HexViewOptions(), length: 16)
        let huge = HexLayout(options: HexViewOptions(), length: 1 << 40)
        #expect(small.offsetLabel(255) == "000000FF")
        #expect(huge.offsetCells == 10)
        let decimal = HexLayout(options: HexViewOptions(offsetBase: .decimal), length: 300)
        #expect(decimal.offsetCells == 10)
        #expect(decimal.offsetLabel(255) == "0000000255")
        let both = HexLayout(options: HexViewOptions(offsetBase: .both), length: 300)
        #expect(both.offsetLabel(255) == "000000FF 0000000255")
    }

    @Test func autoFitUsesMultiplesOfEight() {
        let options = HexViewOptions(bytesPerRow: .autoFit)
        #expect(HexLayout(options: options, length: 10, availableCells: 40).bytesPerRow == 8)
        // 16 bytes need 10 + 48 + 2 + 16 = 76 cells; 32 bytes need 142.
        #expect(HexLayout(options: options, length: 10, availableCells: 80).bytesPerRow == 16)
        #expect(HexLayout(options: options, length: 10, availableCells: 141).bytesPerRow == 24)
        #expect(HexLayout(options: options, length: 10, availableCells: 150).bytesPerRow == 32)
        let fitted = HexLayout(options: options, length: 10, availableCells: 150)
        #expect(fitted.totalCells <= 150)
    }

    @Test func hitTesting() {
        let layout = HexLayout(options: HexViewOptions(), length: 1000)
        #expect(layout.hit(cell: 2) == nil)
        #expect(layout.hit(cell: Double(layout.hexStart - 1) - 0.1) == nil)
        #expect(layout.hit(cell: Double(layout.hexStart - 1))! == (0, .hex))
        #expect(layout.hit(cell: Double(layout.hexCell(5)) + 1)! == (5, .hex))
        #expect(layout.hit(cell: Double(layout.hexCell(5)) + 2.5)! == (5, .hex))
        #expect(layout.hit(cell: Double(layout.textStart - 1))! == (0, .text))
        #expect(layout.hit(cell: Double(layout.textCell(7)) + 0.5)! == (7, .text))
        #expect(layout.hit(cell: 500)! == (15, .text))
        #expect(HexLayout(options: .init(bytesPerRow: .fixed(8)), length: 32).bytesPerRow == 8)
        #expect(HexLayout(options: .init(bytesPerRow: .fixed(32)), length: 32).bytesPerRow == 32)
    }

    @Test func emptyFileHasOneRow() {
        #expect(HexLayout(options: HexViewOptions(), length: 0).rowCount == 1)
    }

    @Test func textEncodings() {
        #expect(HexViewOptions.TextEncoding.ascii.character(for: 0x41) == "A")
        #expect(HexViewOptions.TextEncoding.ascii.character(for: 0xE9) == nil)
        #expect(HexViewOptions.TextEncoding.latin1.character(for: 0xE9) == "é")
        #expect(HexViewOptions.TextEncoding.latin1.character(for: 0x85) == nil)
    }

    /// Review minor issue: setting an option directly skipped the init's validation; a
    /// grouping of 0 would divide by zero in the layout.
    @Test func optionsStayValidWhenSetDirectly() {
        var options = HexViewOptions()
        options.grouping = 0
        #expect(options.grouping == 1)
        options.grouping = 4
        #expect(options.grouping == 4)
        options.bytesPerRow = .fixed(0)
        #expect(options.bytesPerRow == .fixed(16))
        _ = HexLayout(options: options, length: 1000)
    }
}
