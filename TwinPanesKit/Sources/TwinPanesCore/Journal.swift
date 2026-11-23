import Foundation

/// One entry of a session's operation journal (docs/plans/M3c.md, D-e). Replaying the
/// records in order over `PieceTree(originalLength:)` rebuilds the session's tree.
public enum JournalRecord: Equatable, Sendable {
    /// The tree's bytes in `range` now come from `pieces` (an edit, undo, redo or revert).
    case replace(Range<UInt64>, [Piece])
    /// The version on disk is the tree after the first `n` replace records (a save writes
    /// the version current when it started; edits typed meanwhile come after).
    case saved(UInt64)
    /// The session closed cleanly.
    case closed
}

/// The journal's file format: each record is framed as
/// `length (UInt32 LE) · type (UInt8) · payload · CRC32C (UInt32 LE) of type and payload`,
/// so a reader can tell a record cut short by a crash, or damaged, from a whole one.
public enum JournalFormat {
    /// The bytes of `record`, framed.
    public static func encode(_ record: JournalRecord) -> Data {
        var body: [UInt8]
        switch record {
        case .replace(let range, let pieces):
            body = [1]
            append(range.lowerBound, to: &body)
            append(range.upperBound, to: &body)
            append(UInt32(pieces.count), to: &body)
            for piece in pieces {
                body.append(piece.source == .original ? 0 : 1)
                append(piece.offset, to: &body)
                append(piece.length, to: &body)
            }
        case .saved(let count):
            body = [2]
            append(count, to: &body)
        case .closed: body = [3]
        }
        var out: [UInt8] = []
        append(UInt32(body.count - 1), to: &out)
        out += body
        append(crc32c(body), to: &out)
        return Data(out)
    }

    /// The whole records at the start of `data`, and how many bytes they take; reading
    /// stops at the first record that is cut short or fails its checksum.
    public static func decode(_ data: Data) -> (records: [JournalRecord], validLength: Int) {
        let bytes = [UInt8](data)
        var records: [JournalRecord] = []
        var at = 0
        while at + 9 <= bytes.count {
            let payload = Int(read(UInt32.self, bytes, at))
            let end = at + 9 + payload
            guard payload < 1 << 30, end <= bytes.count else { break }
            let body = bytes[(at + 4)..<(end - 4)]
            guard crc32c(body) == read(UInt32.self, bytes, end - 4),
                let record = parse(Array(body))
            else { break }
            records.append(record)
            at = end
        }
        return (records, at)
    }

    private static func parse(_ body: [UInt8]) -> JournalRecord? {
        switch body[0] {
        case 2 where body.count == 9: return .saved(read(UInt64.self, body, 1))
        case 3 where body.count == 1: return .closed
        case 1 where body.count >= 21:
            let count = Int(read(UInt32.self, body, 17))
            guard body.count == 21 + count * 17 else { return nil }
            let lower = read(UInt64.self, body, 1), upper = read(UInt64.self, body, 9)
            guard lower <= upper else { return nil }
            let pieces = (0..<count).map { index in
                let at = 21 + index * 17
                return Piece(
                    body[at] == 0 ? .original : .add, offset: read(UInt64.self, body, at + 1),
                    length: read(UInt64.self, body, at + 9))
            }
            return .replace(lower..<upper, pieces)
        default: return nil
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes += $0 }
    }

    private static func read<T: FixedWidthInteger>(
        _: T.Type, _ bytes: some RandomAccessCollection<UInt8>, _ at: Int
    ) -> T {
        var value: T = 0
        let start = bytes.index(bytes.startIndex, offsetBy: at)
        for (shift, byte) in bytes[start...].prefix(MemoryLayout<T>.size).enumerated() {
            value |= T(byte) << (shift * 8)
        }
        return value
    }

    /// Rebuilds a session from its records over the original (the clone) of
    /// `originalLength` bytes: the current tree, and the saved one.
    public static func replay(
        _ records: [JournalRecord], originalLength: UInt64
    )
        -> (tree: PieceTree, saved: PieceTree)
    {
        var history = [PieceTree(originalLength: originalLength)]
        var saved = history[0]
        for record in records {
            switch record {
            case .replace(let range, let pieces):
                let (left, rest) = history[history.count - 1].split(at: range.lowerBound)
                let right = rest.split(at: range.upperBound - range.lowerBound).1
                let middle = pieces.reduce(PieceTree()) { $0.appending($1) }
                history.append(left.appending(middle).appending(right))
            case .saved(let count):
                saved = history[Int(min(count, UInt64(history.count - 1)))]
            case .closed:
                break
            }
        }
        return (history[history.count - 1], saved)
    }

    /// CRC32C (Castagnoli), as storage formats commonly use.
    static func crc32c(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0x82F6_3B78 : value >> 1 }
        return value
    }
}
