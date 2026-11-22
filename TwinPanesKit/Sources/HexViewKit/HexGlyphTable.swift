import AppKit
import CoreText

/// Pre-shaped glyphs for a monospaced font (PLAN.md §4.4), built once per font change
/// so `HexView.draw(_:)` renders rows directly with `CTFontDrawGlyphs` and never shapes
/// strings or allocates attribute dictionaries per frame.
struct HexGlyphTable {
    let ctFont: CTFont
    let advance: Double
    let baselineOffset: Double
    let hexDigits: [CGGlyph]
    let decimalDigits: [CGGlyph]
    let ascii: [CGGlyph]
    let latin1: [CGGlyph]
    let dot: CGGlyph
    let placeholder: CGGlyph
    let space: CGGlyph

    init(font: NSFont) {
        let ctFont = font as CTFont
        self.ctFont = ctFont
        let dot = Self.glyph(for: 0x002E, in: ctFont)
        self.dot = dot
        let middleDot = Self.glyph(for: 0x00B7, in: ctFont)
        self.placeholder = middleDot != 0 ? middleDot : dot
        self.space = Self.glyph(for: 0x0020, in: ctFont)

        var zero = Self.glyph(for: 0x0030, in: ctFont)
        var size = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &zero, &size, 1)
        self.advance =
            size.width > 0
            ? Double(size.width)
            : Double(("0" as NSString).size(withAttributes: [.font: font]).width)
        self.baselineOffset = 1.5 + Double(font.ascender)

        self.hexDigits = "0123456789ABCDEF".utf16.map { Self.glyph(for: $0, in: ctFont) }
        self.decimalDigits = Array(self.hexDigits.prefix(10))

        var ascii = [CGGlyph](repeating: dot, count: 256)
        var latin1 = [CGGlyph](repeating: dot, count: 256)
        for byte in 0x20...0x7E {
            let g = Self.glyph(for: UniChar(byte), in: ctFont)
            if g != 0 {
                ascii[byte] = g
                latin1[byte] = g
            }
        }
        for byte in 0xA0...0xFF {
            let g = Self.glyph(for: UniChar(byte), in: ctFont)
            if g != 0 { latin1[byte] = g }
        }
        self.ascii = ascii
        self.latin1 = latin1
    }

    func textGlyph(for byte: UInt8, encoding: HexViewOptions.TextEncoding) -> CGGlyph {
        switch encoding {
        case .ascii: return ascii[Int(byte)]
        case .latin1: return latin1[Int(byte)]
        }
    }

    func glyph(for asciiScalar: UInt8) -> CGGlyph {
        asciiScalar == 0x20 ? space : ascii[Int(asciiScalar)]
    }

    private static func glyph(for codeUnit: UniChar, in font: CTFont) -> CGGlyph {
        var unit = codeUnit
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1)
        return glyph
    }
}
