import Foundation

/// Cursor and selection over a file of `length` bytes. The cursor is always a valid
/// byte offset (0 for an empty file); the selection runs from `anchor` to `cursor`,
/// both inclusive.
public struct HexSelection: Equatable, Sendable {
    public let length: UInt64
    public private(set) var anchor: UInt64 = 0
    public private(set) var cursor: UInt64 = 0

    public init(length: UInt64) { self.length = length }

    private var lastOffset: UInt64 { length > 0 ? length - 1 : 0 }

    /// Selected bytes; empty only for an empty file.
    public var range: Range<UInt64> {
        guard length > 0 else { return 0..<0 }
        return min(anchor, cursor)..<(max(anchor, cursor) + 1)
    }

    /// Moves the cursor to `offset`; `extending` keeps the anchor (shift-click,
    /// shift-arrow), otherwise the selection collapses to the cursor.
    public mutating func move(to offset: UInt64, extending: Bool = false) {
        cursor = min(offset, lastOffset)
        if !extending { anchor = cursor }
    }

    /// Moves the cursor by `delta` bytes, stopping at the ends of the file.
    public mutating func move(by delta: Int64, extending: Bool = false) {
        let target: UInt64
        if delta < 0 {
            target = cursor >= delta.magnitude ? cursor - delta.magnitude : 0
        } else {
            target = cursor &+ UInt64(delta) < cursor ? lastOffset : cursor + UInt64(delta)
        }
        move(to: target, extending: extending)
    }

    /// Selects `range` (clamped to the file), with the cursor on its last byte.
    public mutating func select(_ range: Range<UInt64>) {
        guard !range.isEmpty else { return move(to: range.lowerBound) }
        anchor = min(range.lowerBound, lastOffset)
        cursor = min(range.upperBound - 1, lastOffset)
    }

    public mutating func selectAll() {
        anchor = 0
        cursor = lastOffset
    }
}

/// Text for the pasteboard from a byte selection (PLAN.md §4.4).
public enum HexCopy {
    /// Copying more than this many bytes asks the user to save to a file instead:
    /// as hex it would be ~3 bytes of text per byte, about 48 MB here.
    public static let maxBytes = 16 * 1024 * 1024

    public enum Format: Sendable {
        /// "4F 2A 9C" — space-separated pairs.
        case hex
        /// The bytes as text in the view's encoding; undrawable bytes become ".".
        case text(HexViewOptions.TextEncoding)
    }

    public static func string(_ bytes: Data, as format: Format) -> String {
        switch format {
        case .hex:
            let digits = Array("0123456789ABCDEF".utf8)
            var out = [UInt8]()
            out.reserveCapacity(bytes.count * 3)
            for (index, byte) in bytes.enumerated() {
                if index > 0 { out.append(0x20) }
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 0x0F)])
            }
            return String(decoding: out, as: UTF8.self)
        case .text(let encoding):
            return String(bytes.map { encoding.character(for: $0) ?? "." })
        }
    }
}
