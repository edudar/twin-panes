import AppKit
import Testing

@testable import HexViewKit

/// Overwrite typing against the fake source (bytes are their offset, truncated).
@MainActor
@Suite struct HexViewEditingTests {
    let source = FakeHexSource(count: 1000)
    let spy = DelegateSpy()
    let view = HexView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))

    init() {
        source.cached = true
        spy.source = source
        view.options.bytesPerRow = .fixed(16)
        view.delegate = spy
        view.dataSource = source
    }

    func byte(_ offset: Int) -> UInt8 { source.data[offset] }

    @Test func twoHexDigitsMakeOneByteAndAdvance() {
        view.go(to: 5)
        view.insertText("a")
        #expect(byte(5) == 0xA5)
        #expect(view.selection.cursor == 5)
        #expect(view.pendingNibble == 5)
        view.insertText("B")
        #expect(byte(5) == 0xAB)
        #expect(view.selection.cursor == 6)
        #expect(view.pendingNibble == nil)
        #expect(spy.writes.map(\.cursorAfter) == [5, 6])
        // Several digits in one insert: "1234" writes two bytes.
        view.insertText("1234")
        #expect(byte(6) == 0x12 && byte(7) == 0x34)
        #expect(view.selection.cursor == 8)
    }

    @Test func movingTheCursorDropsAHalfTypedByte() {
        view.go(to: 5)
        view.insertText("f")
        view.moveRight(nil)
        view.moveLeft(nil)
        view.insertText("1")
        // The second digit starts a new byte instead of finishing the first.
        #expect(byte(5) == 0x15)
        #expect(view.selection.cursor == 5)
    }

    @Test func refusesKeysThatMeanNothing() {
        view.go(to: 5)
        view.insertText("g")
        view.insertText("٣")  // a non-ASCII digit
        #expect(spy.writes.isEmpty)
        #expect(byte(5) == 5 && view.selection.cursor == 5)
        spy.readOnly = true
        view.insertText("a")
        #expect(byte(5) == 5)
    }

    @Test func textColumnTypesInItsEncoding() {
        view.go(to: 10)
        view.insertTab(nil)
        view.insertText("Zz")
        #expect(byte(10) == 0x5A && byte(11) == 0x7A)
        #expect(view.selection.cursor == 12)
        view.insertText("é")
        #expect(spy.unencodable == ["é"])
        #expect(byte(12) == 12)
        view.options.textEncoding = .latin1
        view.insertText("é")
        #expect(byte(12) == 0xE9)
        #expect(spy.writes.allSatisfy { $0.column == .text })
    }

    @Test func typingStartsAtTheSelectionAndStopsAtTheLastByte() {
        view.select(20..<30)
        view.insertTab(nil)
        view.insertText("Q")
        #expect(byte(20) == 0x51)
        #expect(view.selection.range == 21..<22)
        view.moveToEndOfDocument(nil)
        view.insertText("xy")
        #expect(byte(999) == 0x79)
        #expect(view.selection.cursor == 999)
        #expect(source.data.count == 1000)
    }

    @Test func hexTypingFallsBackToReadWhenUncachedAndReportsErrors() {
        source.cached = false
        view.go(to: 5)
        view.insertText("AB")
        #expect(byte(5) == 0xAB)
        #expect(view.selection.cursor == 6)

        source.readError = ReadFailed()
        view.insertText("C")
        #expect(byte(6) == 6)
        #expect(spy.errors == 1)
    }

    @Test func textColumnRejectsControlCharacters() {
        view.go(to: 10)
        view.insertTab(nil)
        view.insertText("\u{00}")
        view.insertText("\n")
        view.insertText("\u{7F}")
        #expect(spy.writes.isEmpty)
        #expect(spy.unencodable.count == 3)
        view.options.textEncoding = .latin1
        view.insertText("\u{85}")
        #expect(spy.writes.isEmpty)
        #expect(spy.unencodable.count == 4)
    }

    /// Drawing the changed-bytes fill with ranges past the end and short data must not trap.
    @Test func drawsModifiedRangesEvenOnShortData() {
        source.modified = [0..<5, 990..<5000]
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let rep { view.cacheDisplay(in: view.bounds, to: rep) }
        view.moveToEndOfDocument(nil)
        source.shortBy = 40
        if let rep { view.cacheDisplay(in: view.bounds, to: rep) }
    }
}
