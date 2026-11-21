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
    }

    public static let allowedBytesPerRow = [8, 16, 32]
    public static let allowedGrouping = [1, 2, 4, 8]

    public var bytesPerRow: BytesPerRow
    /// Bytes per group in the hex column: 1, 2, 4 or 8.
    public var grouping: Int
    public var offsetBase: OffsetBase
    public var textEncoding: TextEncoding

    public init(
        bytesPerRow: BytesPerRow = .fixed(16), grouping: Int = 1, offsetBase: OffsetBase = .hex,
        textEncoding: TextEncoding = .ascii
    ) {
        self.bytesPerRow = bytesPerRow
        self.grouping = Self.allowedGrouping.contains(grouping) ? grouping : 1
        self.offsetBase = offsetBase
        self.textEncoding = textEncoding
    }
}
