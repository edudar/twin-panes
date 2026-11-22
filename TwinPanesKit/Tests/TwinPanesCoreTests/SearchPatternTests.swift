import Testing

@testable import TwinPanesCore

@Suite struct SearchPatternTests {
    func bytes(_ pattern: SearchPattern) -> [UInt8] { pattern.elements.map(\.byte) }

    @Test(arguments: ["4F 2A", "4f2a", "0x4F, 0x2A", " 4F\t2a\n", "4F;2A"])
    func parsesHex(_ text: String) throws {
        #expect(bytes(try SearchPattern.hex(text)) == [0x4F, 0x2A])
    }

    @Test func rejectsBadHex() {
        #expect(throws: SearchPattern.ParseError.notHex("4G")) { try SearchPattern.hex("4G") }
        #expect(throws: SearchPattern.ParseError.oddDigitCount) { try SearchPattern.hex("4F2") }
        #expect(throws: SearchPattern.ParseError.empty) { try SearchPattern.hex("  ") }
        #expect(throws: SearchPattern.ParseError.notHex("0x")) { try SearchPattern.hex("0x") }
        let long = String(repeating: "00", count: SearchPattern.maxLength + 1)
        #expect(throws: SearchPattern.ParseError.tooLong) { try SearchPattern.hex(long) }
    }

    @Test func encodesText() throws {
        #expect(bytes(try .text("Aé", encoding: .utf8)) == [0x41, 0xC3, 0xA9])
        #expect(bytes(try .text("Aé", encoding: .utf16LE)) == [0x41, 0x00, 0xE9, 0x00])
        #expect(bytes(try .text("Aé", encoding: .utf16BE)) == [0x00, 0x41, 0x00, 0xE9])
        #expect(bytes(try .text("😀", encoding: .utf16LE)) == [0x3D, 0xD8, 0x00, 0xDE])
        #expect(bytes(try .text("😀", encoding: .utf16BE)) == [0xD8, 0x3D, 0xDE, 0x00])
        #expect(throws: SearchPattern.ParseError.empty) {
            try SearchPattern.text("", encoding: .utf8)
        }
        let tooLong = String(repeating: "a", count: SearchPattern.maxLength + 1)
        #expect(throws: SearchPattern.ParseError.tooLong) {
            try SearchPattern.text(tooLong, encoding: .utf8)
        }
    }

    @Test func foldsOnlyAsciiLetters() throws {
        let pattern = try SearchPattern.text("a1É", encoding: .utf16LE, ignoringCase: true)
        #expect(
            pattern.elements == [
                .init(0x61, or: 0x41), .init(0x00), .init(0x31), .init(0x00),
                .init(0xC9), .init(0x00),
            ])
        #expect(pattern.anchor == 4)
        let letters = try SearchPattern.text("Ab", encoding: .utf8, ignoringCase: true)
        #expect(letters.anchor == nil)
    }

    /// Anchor invariants: always an exact position, avoids 0x00 when another exact byte
    /// exists, picks the earliest index on a tie, and is nil when all positions fold.
    @Test func anchorInvariants() throws {
        let withZeros = try SearchPattern(bytes: [0x00, 0x00, 0x7A])
        #expect(withZeros.anchor == 2)
        let tied = try SearchPattern(bytes: [0x41, 0x41])
        #expect(tied.anchor == 0)
        let utf16 = try SearchPattern.text("hello", encoding: .utf16LE)
        let anchor = try #require(utf16.anchor)
        #expect(utf16.elements[anchor].isExact && utf16.elements[anchor].byte != 0x00)
        let foldedWithDigit = try SearchPattern.text("ab1", encoding: .utf8, ignoringCase: true)
        #expect(foldedWithDigit.anchor == 2)
        let allFolded = try SearchPattern.text("abc", encoding: .utf8, ignoringCase: true)
        #expect(allFolded.anchor == nil)
    }
}
