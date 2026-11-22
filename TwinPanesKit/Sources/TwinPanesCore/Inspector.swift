import Foundation

/// Decodes the bytes at the cursor for the data inspector (PLAN.md §4.6). Pure and
/// Foundation-only; the inspector panel shows the rows.
public enum Inspector {
    public enum Endianness: String, CaseIterable, Sendable {
        case little, big
    }

    public struct Row: Equatable, Sendable {
        public let name: String
        /// The decoded value, or nil when too few bytes are left before the end.
        public let value: String?
    }

    /// How many bytes from the cursor the rows can use.
    public static let byteCount = 8

    public static func rows(for bytes: Data, endianness: Endianness) -> [Row] {
        let bytes = Array(bytes.prefix(byteCount))
        func int<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard bytes.count >= size else { return nil }
            let ordered =
                endianness == .little ? bytes[0..<size].reversed() : Array(bytes[0..<size])
            return ordered.reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: $1) }
        }
        func show<T>(_ value: T?) -> String? { value.map { "\($0)" } }

        return [
            Row(name: "Binary", value: bytes.first.map(binary)),
            Row(name: "Int8", value: show(int(Int8.self))),
            Row(name: "UInt8", value: show(int(UInt8.self))),
            Row(name: "Int16", value: show(int(Int16.self))),
            Row(name: "UInt16", value: show(int(UInt16.self))),
            Row(name: "Int32", value: show(int(Int32.self))),
            Row(name: "UInt32", value: show(int(UInt32.self))),
            Row(name: "Int64", value: show(int(Int64.self))),
            Row(name: "UInt64", value: show(int(UInt64.self))),
            Row(name: "Float16", value: int(UInt16.self).map(half)),
            Row(name: "Float32", value: show(int(UInt32.self).map { Float(bitPattern: $0) })),
            Row(name: "Float64", value: show(int(UInt64.self).map { Double(bitPattern: $0) })),
            Row(name: "UTF-8", value: bytes.isEmpty ? nil : utf8(bytes)),
            Row(name: "UTF-16", value: bytes.count < 2 ? nil : utf16(bytes, endianness)),
            Row(
                name: "Unix time (32-bit)",
                value: int(Int32.self).map { date(Double($0), since: 0) }),
            Row(
                name: "Mac absolute time",
                value: int(UInt64.self).map {
                    date(
                        Double(bitPattern: $0), since: Date.timeIntervalBetween1970AndReferenceDate)
                }),
            Row(
                name: "Windows FILETIME",
                value: int(UInt64.self).map {
                    date(Double($0 / 10_000_000), since: -11_644_473_600)
                }),
        ]
    }

    /// A half-precision float from its bits. `Float16` exists only on Apple silicon; the
    /// app is arm64-only, but tools such as CodeQL may build the package for x86_64.
    static func half(_ bits: UInt16) -> String {
        #if arch(arm64)
            return "\(Float16(bitPattern: bits))"
        #else
            let sign: Float = bits >> 15 == 0 ? 1 : -1
            let exponent = Int((bits >> 10) & 0x1F)
            let fraction = Float(bits & 0x3FF)
            switch exponent {
            case 0: return "\(sign * fraction * 0x1p-24)"
            case 31: return fraction == 0 ? "\(sign * .infinity)" : "nan"
            default:
                return
                    "\(sign * (1 + fraction / 1024) * Float(sign: .plus, exponent: exponent - 15, significand: 1))"
            }
        #endif
    }

    static func binary(_ byte: UInt8) -> String {
        let bits = String(byte, radix: 2)
        let padded = String(repeating: "0", count: 8 - bits.count) + bits
        return padded.prefix(4) + " " + padded.suffix(4)
    }

    /// The first character, with its code point; "invalid" if the bytes don't start a
    /// UTF-8 sequence.
    static func utf8(_ bytes: [UInt8]) -> String {
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return "invalid" }
        return describe(scalar)
    }

    static func utf16(_ bytes: [UInt8], _ endianness: Inspector.Endianness) -> String {
        var units: [UInt16] = []
        var index = 0
        while index + 1 < bytes.count {
            let (a, b) = (UInt16(bytes[index]), UInt16(bytes[index + 1]))
            units.append(endianness == .little ? b << 8 | a : a << 8 | b)
            index += 2
        }
        var decoder = UTF16()
        var iterator = units.makeIterator()
        guard case .scalarValue(let scalar) = decoder.decode(&iterator) else { return "invalid" }
        return describe(scalar)
    }

    static func describe(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        let code = "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        let printable = !scalar.properties.generalCategory.isControlOrUnassigned
        return printable ? "\(code) “\(Character(scalar))”" : code
    }

    /// `seconds` after the epoch that lies `epoch` seconds after 1970, as ISO 8601 UTC.
    static func date(_ seconds: Double, since epoch: Double) -> String {
        let unix = seconds + epoch
        // Years 1 through 9999.
        guard unix.isFinite, (-62_135_596_800...253_402_300_799).contains(unix) else {
            return "out of range"
        }
        return Date(timeIntervalSince1970: unix).formatted(.iso8601)
    }
}

extension Unicode.GeneralCategory {
    fileprivate var isControlOrUnassigned: Bool {
        switch self {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator,
            .paragraphSeparator, .spaceSeparator:
            return true
        default:
            return false
        }
    }
}
