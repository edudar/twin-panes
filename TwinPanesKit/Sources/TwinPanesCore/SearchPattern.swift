import Foundation

/// What `Searcher` looks for (PLAN.md §4.5): a run of byte positions, each matching
/// one byte, or either of two for a letter searched without regard to case.
public struct SearchPattern: Equatable, Sendable {
    /// One position of the pattern.
    public struct Element: Equatable, Sendable {
        public let byte: UInt8
        /// Equal to `byte` for an exact match.
        public let alternative: UInt8

        public init(_ byte: UInt8, or alternative: UInt8? = nil) {
            self.byte = byte
            self.alternative = alternative ?? byte
        }

        public var isExact: Bool { byte == alternative }

        @inline(__always)
        func matches(_ value: UInt8) -> Bool { value == byte || value == alternative }
    }

    public enum TextEncoding: String, CaseIterable, Sendable {
        case utf8, utf16LE, utf16BE
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case notHex(String)
        case oddDigitCount
        case tooLong

        public var description: String {
            switch self {
            case .empty: return "Enter something to find"
            case .notHex(let token): return "“\(token)” isn't hex"
            case .oddDigitCount: return "Hex needs two digits per byte"
            case .tooLong: return "Patterns are limited to \(SearchPattern.maxLength) bytes"
            }
        }
    }

    public static let maxLength = 4096

    public let elements: [Element]

    /// The exact position whose byte is rarest by `commonness(of:)` (the first, on a
    /// tie), which the search finds with `memchr`; nil when every position folds case.
    let anchor: Int?

    public init(elements: [Element]) throws {
        guard !elements.isEmpty else { throw ParseError.empty }
        guard elements.count <= Self.maxLength else { throw ParseError.tooLong }
        self.elements = elements
        // `min(by:)` keeps the first of equal elements, so ties go to the earliest.
        self.anchor = elements.indices.filter { elements[$0].isExact }.min {
            Self.commonness(of: elements[$0].byte) < Self.commonness(of: elements[$1].byte)
        }
    }

    /// Lowercase letters from most to least common in English text.
    private static let letterOrder = Array("etaoinshrdlcumwfgypbvkjxqz".utf8)

    /// A fixed ranking of how often `byte` turns up in typical files: higher is more
    /// common. Zero (padding, UTF-16 high bytes), 0xFF and space top it, then lowercase
    /// letters by English frequency, then other text bytes; non-ASCII bytes rank lowest.
    static func commonness(of byte: UInt8) -> Int {
        switch byte {
        case 0x00: return 255
        case 0xFF: return 250
        case 0x20: return 245
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return 240 - letterOrder.firstIndex(of: byte)!
        case 0x0A, 0x0D, 0x09: return 190
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return 180
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return 170
        case 0x21...0x7E: return 150
        case 0x01...0x1F, 0x7F: return 120
        default: return 100
        }
    }

    public init(bytes: [UInt8]) throws {
        try self.init(elements: bytes.map { Element($0) })
    }

    public var count: Int { elements.count }

    /// Parses hex such as `4F 2A`, `4f2a` or `0x4F, 0x2A`.
    public static func hex(_ text: String) throws -> SearchPattern {
        var digits = ""
        let separators = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",;"))
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            let body = token.lowercased().hasPrefix("0x") ? String(token.dropFirst(2)) : token
            guard !body.isEmpty, body.allSatisfy(\.isHexDigit) else {
                throw ParseError.notHex(token)
            }
            digits += body
        }
        guard !digits.isEmpty else { throw ParseError.empty }
        guard digits.count.isMultiple(of: 2) else { throw ParseError.oddDigitCount }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        return try SearchPattern(bytes: bytes)
    }

    /// Text in `encoding`. Ignoring case folds ASCII letters only.
    public static func text(
        _ text: String, encoding: TextEncoding, ignoringCase: Bool = false
    ) throws -> SearchPattern {
        var elements: [Element] = []
        for scalar in text.unicodeScalars {
            let letter = ignoringCase && scalar.isASCII && scalar.properties.isAlphabetic
            let units: [UInt8]
            switch encoding {
            case .utf8: units = Array(String(scalar).utf8)
            case .utf16LE:
                units = String(scalar).utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            case .utf16BE:
                units = String(scalar).utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            }
            for unit in units {
                // In UTF-16 only the letter's byte folds; its zero byte stays exact.
                if letter, unit != 0 {
                    elements.append(Element(unit | 0x20, or: unit & ~0x20))
                } else {
                    elements.append(Element(unit))
                }
            }
        }
        return try SearchPattern(elements: elements)
    }
}
