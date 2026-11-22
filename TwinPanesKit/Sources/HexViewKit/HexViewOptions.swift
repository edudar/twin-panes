/// User-selectable display settings of a hex view (D18, PLAN.md §4.4).
public struct HexViewOptions: Equatable, Sendable {
    public enum OffsetBase: String, CaseIterable, Sendable {
        case hex
        case decimal
        case both
    }

    public enum BytesPerRow: Equatable, Sendable {
        case fixed(Int)
        /// As many bytes as fit the view's width, in multiples of 8.
        case autoFit
    }

    /// How the text column draws bytes. More encodings (UTF-8, UTF-16, EBCDIC) are M10.
    public enum TextEncoding: String, CaseIterable, Sendable {
        case ascii
        case latin1

        /// The character drawn for `byte`, or `nil` for a placeholder dot.
        public func character(for byte: UInt8) -> Character? {
            switch self {
            case .ascii:
                return (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : nil
            case .latin1:
                return (0x20...0x7E).contains(byte) || byte >= 0xA0
                    ? Character(UnicodeScalar(byte)) : nil
            }
        }

        /// The byte that typing `character` writes, or nil if this encoding can't hold it.
        /// Restricted to printable characters (matching `character(for:)`); arbitrary byte
        /// values are typed in the hex column.
        public func byte(for character: Character) -> UInt8? {
            guard character.unicodeScalars.count == 1,
                let value = character.unicodeScalars.first?.value, value < 0x100
            else { return nil }
            let byte = UInt8(value)
            return self.character(for: byte) != nil ? byte : nil
        }
    }

    public static let allowedBytesPerRow = [8, 16, 32]
    public static let allowedGrouping = [1, 2, 4, 8]

    /// 8, 16 or 32, or fit to the width; anything else falls back to 16.
    public var bytesPerRow: BytesPerRow {
        didSet { bytesPerRow = Self.valid(bytesPerRow) }
    }
    /// Bytes per group in the hex column: 1, 2, 4 or 8; anything else falls back to 1.
    public var grouping: Int {
        didSet { grouping = Self.valid(grouping: grouping) }
    }
    public var offsetBase: OffsetBase
    public var textEncoding: TextEncoding

    public init(
        bytesPerRow: BytesPerRow = .fixed(16), grouping: Int = 1, offsetBase: OffsetBase = .hex,
        textEncoding: TextEncoding = .ascii
    ) {
        self.bytesPerRow = Self.valid(bytesPerRow)
        self.grouping = Self.valid(grouping: grouping)
        self.offsetBase = offsetBase
        self.textEncoding = textEncoding
    }

    private static func valid(_ value: BytesPerRow) -> BytesPerRow {
        if case .fixed(let count) = value, !allowedBytesPerRow.contains(count) { return .fixed(16) }
        return value
    }

    private static func valid(grouping: Int) -> Int {
        allowedGrouping.contains(grouping) ? grouping : 1
    }
}
