/// Where everything sits in a hex view, in character cells of a monospaced font
/// (PLAN.md §4.4). Pure value type: the view multiplies by the font's advance.
///
/// A row is: offset gutter, 2 cells gap, hex column, 2 cells gap, text column. In the
/// hex column each byte takes 2 cells; groups are separated by one space, plus one
/// more every 8 bytes when groups are smaller than 8.
public struct HexLayout: Equatable, Sendable {
    public enum Column: Equatable, Sendable {
        case hex
        case text
    }

    public let options: HexViewOptions
    public let length: UInt64
    public let bytesPerRow: Int
    public let offsetCells: Int
    public let hexStart: Int
    public let textStart: Int

    /// The cursor can sit after the last byte (insert mode), which may need a row of its
    /// own.
    public let includesEndPosition: Bool

    /// - Parameter availableCells: the view's width in cells, used by `.autoFit`.
    /// - Parameter includesEndPosition: rows and offsets also cover the position at
    ///   `length`, after the last byte.
    public init(
        options: HexViewOptions, length: UInt64, availableCells: Int = 80,
        includesEndPosition: Bool = false
    ) {
        self.options = options
        self.length = length
        self.includesEndPosition = includesEndPosition
        let lastOffset = max(Self.positions(length, includesEndPosition), 1) - 1
        let hexDigits = Self.digits(of: lastOffset, radix: 16, minimum: 8)
        let decimalDigits = Self.digits(of: lastOffset, radix: 10, minimum: 10)
        switch options.offsetBase {
        case .hex: offsetCells = hexDigits
        case .decimal: offsetCells = decimalDigits
        case .both: offsetCells = hexDigits + 1 + decimalDigits
        }
        hexStart = offsetCells + 2
        switch options.bytesPerRow {
        case .fixed(let count):
            bytesPerRow = max(1, count)
        case .autoFit:
            // Hex column, the 2-cell gap and the text column must all fit.
            var fit = 8
            while hexStart + Self.width(bytes: fit + 8, grouping: options.grouping) + 2
                + (fit + 8) <= availableCells
            {
                fit += 8
            }
            bytesPerRow = fit
        }
        textStart = hexStart + Self.width(bytes: bytesPerRow, grouping: options.grouping) + 2
    }

    public var totalCells: Int { textStart + bytesPerRow }

    /// Rows needed for the whole file and the end position; an empty file still shows
    /// one (empty) row.
    public var rowCount: UInt64 {
        let count = Self.positions(length, includesEndPosition)
        return max(1, (count + UInt64(bytesPerRow) - 1) / UInt64(bytesPerRow))
    }

    /// Places the cursor can be: every byte, and the end position if there is one.
    private static func positions(_ length: UInt64, _ includesEndPosition: Bool) -> UInt64 {
        includesEndPosition ? length + 1 : length
    }

    public func rowStart(_ row: UInt64) -> UInt64 { row * UInt64(bytesPerRow) }

    public func row(of offset: UInt64) -> UInt64 { offset / UInt64(bytesPerRow) }

    /// First cell of byte `index` (0..<bytesPerRow) in the hex column.
    public func hexCell(_ index: Int) -> Int {
        hexStart + index * 2 + Self.gaps(before: index, grouping: options.grouping)
    }

    public func textCell(_ index: Int) -> Int { textStart + index }

    /// The byte index within a row at horizontal cell position `cell`, and which column
    /// it is in. Positions in gaps snap to the nearest byte; outside both columns, nil.
    public func hit(cell: Double) -> (index: Int, column: Column)? {
        if cell >= Double(textStart - 1) {
            let index = Int(cell) - textStart
            return (min(max(index, 0), bytesPerRow - 1), .text)
        }
        guard cell >= Double(hexStart - 1) else { return nil }
        var best = 0
        for index in 0..<bytesPerRow where Double(hexCell(index)) <= cell {
            best = index
        }
        return (best, .hex)
    }

    // MARK: Formatting

    public func offsetLabel(_ offset: UInt64) -> String {
        let hexDigits = Self.digits(of: max(length, 1) - 1, radix: 16, minimum: 8)
        let decimalDigits = Self.digits(of: max(length, 1) - 1, radix: 10, minimum: 10)
        let hex = Self.pad(String(offset, radix: 16, uppercase: true), hexDigits)
        let decimal = Self.pad(String(offset), decimalDigits)
        switch options.offsetBase {
        case .hex: return hex
        case .decimal: return decimal
        case .both: return hex + " " + decimal
        }
    }

    // MARK: Helpers

    static func gaps(before index: Int, grouping: Int) -> Int {
        index / grouping + (grouping < 8 ? index / 8 : 0)
    }

    static func width(bytes: Int, grouping: Int) -> Int {
        bytes * 2 + gaps(before: bytes - 1, grouping: grouping)
    }

    static func digits(of value: UInt64, radix: Int, minimum: Int) -> Int {
        max(minimum, String(value, radix: radix).count)
    }

    static func pad(_ text: String, _ width: Int) -> String {
        String(repeating: "0", count: max(0, width - text.count)) + text
    }
}
