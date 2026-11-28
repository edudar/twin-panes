import AppKit
import Testing

@testable import HexViewKit

/// What the view actually puts on screen: rendered into a bitmap and checked for ink, so
/// a draw path that silently draws nothing fails here.
@MainActor
@Suite struct HexViewDrawingTests {
    let source = FakeHexSource(count: 1000)
    let view = HexView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))

    init() {
        source.cached = true
        view.options.bytesPerRow = .fixed(16)
        view.dataSource = source
    }

    /// Renders the view and returns how many pixels in `rect` (view coordinates, flipped)
    /// differ clearly from the background.
    func inkedPixels(in rect: NSRect, appearance: NSAppearance.Name) throws -> Int {
        view.appearance = NSAppearance(named: appearance)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / view.bounds.width
        let background = try #require(rep.colorAt(x: rep.pixelsWide - 30, y: rep.pixelsHigh - 10))
        var count = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let difference =
                    abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if difference > 0.3 { count += 1 }
            }
        }
        return count
    }

    /// Offsets, hex digits and text glyphs are drawn, in light and dark appearance, on a
    /// row without selection or cursor (whose fills would count as ink). On macOS 27.2 a
    /// flipped text matrix drew every glyph outside the view and this found nothing.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func rowsShowOffsetHexAndText(appearance: NSAppearance.Name) throws {
        // Row 2 holds bytes 0x20…0x2F, printable in the text column. The cursor sits on a
        // row further down so no selection or cursor box covers it.
        view.select(0x80..<0x81)  // visible already, so the view doesn't scroll
        #expect(view.position.topRow == 0)
        let top = view.inset.top + 2 * view.rowHeight + 2, height = view.rowHeight - 4
        func cells(_ first: Int, _ count: Int) -> NSRect {
            NSRect(
                x: view.inset.left + Double(first) * view.charWidth, y: top,
                width: Double(count) * view.charWidth, height: height)
        }
        let offsets = cells(0, view.layout.offsetCells)
        let hex = cells(view.layout.hexCell(0), 8)
        let text = cells(view.layout.textCell(1), 8)  // "!\"#$%&'(": skip the space
        #expect(try inkedPixels(in: offsets, appearance: appearance) > 20, "offset gutter")
        #expect(try inkedPixels(in: hex, appearance: appearance) > 20, "hex column")
        #expect(try inkedPixels(in: text, appearance: appearance) > 10, "text column")
    }

    /// In insert mode an empty file still shows where typing goes: a bar where the first
    /// byte's hex digits would be. Out of it, an empty file draws no cursor.
    @Test func insertModeDrawsABarInAnEmptyFile() throws {
        source.data = Data()
        view.reloadData()
        let bar = NSRect(
            x: view.inset.left + Double(view.layout.hexCell(0)) * view.charWidth - 3,
            y: view.inset.top + 2, width: 4, height: view.rowHeight - 4)
        #expect(try inkedPixels(in: bar, appearance: .aqua) == 0)
        view.isInsertMode = true
        #expect(try inkedPixels(in: bar, appearance: .aqua) > 10)
    }

    /// An `NSScroller` takes its orientation from the frame it's created with; one made
    /// with a zero frame stays vertical, and the bar under a too-narrow view showed a
    /// small vertical knob instead of a horizontal one.
    @Test func horizontalScrollerIsHorizontal() {
        view.options.bytesPerRow = .fixed(32)
        #expect(!view.horizontalScroller.isHidden)
        let bar = view.horizontalScroller.frame
        #expect(bar.width > bar.height)
        let knob = view.horizontalScroller.rect(for: .knob)
        #expect(knob.width > knob.height, "knob \(knob) in bar \(bar)")
        let track = view.horizontalScroller.rect(for: .knobSlot)
        #expect(track.width > bar.width / 2, "track \(track) in bar \(bar)")
    }

    /// A data source may answer with a `Data` slice whose indices start at the range's
    /// offset (the fake does). Drawing a view scrolled past row 0 cut rows out of it as if
    /// it started at 0 and trapped.
    @Test func drawsScrolledRowsFromDataSlices() throws {
        view.go(to: 0x200)
        #expect(view.position.topRow > 0)
        #expect(source.cachedBytes(0x100..<0x110)?.startIndex == 0x100)
        let top = view.inset.top + 2, height = view.rowHeight - 4
        let hex = NSRect(
            x: view.inset.left + Double(view.layout.hexCell(0)) * view.charWidth, y: top,
            width: 8 * view.charWidth, height: height)
        #expect(try inkedPixels(in: hex, appearance: .aqua) > 20)
    }

    @Test func glyphTableRebuildsOnlyWhenFontChanges() {
        #expect(view.glyphTableBuilds == 1)
        let initialWidth = view.charWidth
        let initialHeight = view.rowHeight

        view.reloadData()
        view.contentLengthDidChange()
        view.options.bytesPerRow = .autoFit
        view.setFrameSize(NSSize(width: 500, height: 300))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #expect(view.glyphTableBuilds == 1)

        view.font = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        #expect(view.glyphTableBuilds == 2)
        #expect(view.charWidth > initialWidth)
        #expect(view.rowHeight > initialHeight)
    }
}
