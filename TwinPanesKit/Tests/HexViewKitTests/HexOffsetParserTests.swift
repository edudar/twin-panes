import Testing

@testable import HexViewKit

@Suite struct HexOffsetParserTests {
    @Test(
        arguments: [
            ("4096", 4096), ("0x1000", 4096), ("$1000", 4096), ("1000h", 4096), ("1F00", 7936),
            ("1_000", 1000), ("0X10", 16), (" 64 ", 64),
        ] as [(String, UInt64)])
    func absolute(_ input: String, _ expected: UInt64) {
        #expect(HexOffsetParser.parse(input) == expected)
    }

    @Test func relative() {
        #expect(HexOffsetParser.parse("+0x10", current: 100) == 116)
        #expect(HexOffsetParser.parse("-200", current: 100) == 0)
        #expect(HexOffsetParser.parse("+1", current: .max) == nil)
    }

    @Test func rejectsGarbage() {
        #expect(HexOffsetParser.parse("") == nil)
        #expect(HexOffsetParser.parse("0xZZ") == nil)
        #expect(HexOffsetParser.parse("twelve") == nil)
    }
}
