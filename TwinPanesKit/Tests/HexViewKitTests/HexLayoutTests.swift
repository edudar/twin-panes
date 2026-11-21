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

    @Test func groupingRemovesInnerSpaces() {
        let layout = HexLayout(options: HexViewOptions(grouping: 4), length: 64)
        #expect(layout.hexCell(1) - layout.hexCell(0) == 2)
        #expect(layout.hexCell(4) - layout.hexCell(3) == 3)
        #expect(layout.hexCell(8) - layout.hexCell(7) == 4)
    }

    @Test func offsetWidthGrowsWithFile() {
        let small = HexLayout(options: HexViewOptions(), length: 16)
        let huge = HexLayout(options: HexViewOptions(), length: 1 << 40)
        #expect(small.offsetLabel(255) == "000000FF")
        #expect(huge.offsetCells == 10)
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
        #expect(layout.hit(cell: Double(layout.hexCell(5)) + 1)! == (5, .hex))
        #expect(layout.hit(cell: Double(layout.hexCell(5)) + 2.5)! == (5, .hex))
        #expect(layout.hit(cell: Double(layout.textCell(7)) + 0.5)! == (7, .text))
        #expect(layout.hit(cell: 500)! == (15, .text))
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
}
