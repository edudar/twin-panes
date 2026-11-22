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
        #expect(throws: SearchPattern.ParseError.empty) {
            try SearchPattern.text("", encoding: .utf8)
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

    /// The anchor is the exact position with the rarest byte; ties go to the first.
    @Test func anchorsOnTheRarestExactByte() throws {
        #expect(try SearchPattern(bytes: [0x00, 0x00, 0x7A]).anchor == 2)
        #expect(try SearchPattern(bytes: [0x00, 0xFF, 0x20]).anchor == 2)
        #expect(try SearchPattern(bytes: [0xFF, 0x00]).anchor == 0)
        #expect(try SearchPattern(bytes: [0x20, 0x65, 0x51]).anchor == 2)
        #expect(try SearchPattern(bytes: [0x41, 0x41]).anchor == 0)
        #expect(try SearchPattern(bytes: [0x65, 0x7A, 0xC3]).anchor == 2)
        // "hello" in UTF-16: the zero bytes and the commonest letters lose to "l".
        #expect(try SearchPattern.text("hello", encoding: .utf16LE).anchor == 4)
        #expect(try SearchPattern.text("hello", encoding: .utf16BE).anchor == 5)
        // Folded letters are not exact, so the digit anchors.
        #expect(try SearchPattern.text("ab1", encoding: .utf8, ignoringCase: true).anchor == 2)
    }
}
