import Foundation

/// Token-based JSON pretty-printer and UTF-16 syntax tokenizer (`docs/plans/M7b.md`, D-c).
enum JSONFormatter {
    private enum RawKind {
        case lBrace, rBrace, lBracket, rBracket, colon, comma, string, number, keyword
    }

    private typealias RawToken = (kind: RawKind, start: Int, end: Int)

    private static let punctuation: [UInt16: RawKind] = [
        0x7B: .lBrace, 0x7D: .rBrace, 0x5B: .lBracket,
        0x5D: .rBracket, 0x3A: .colon, 0x2C: .comma,
    ]

    /// Formats and tokenizes JSON text, preserving key order and exact numeric/string literals.
    /// Falls back to raw text with best-effort tokens when `isTruncated` is true or JSON is invalid.
    static func format(
        _ text: String, pretty: Bool, isTruncated: Bool
    ) -> (text: String, tokens: [SyntaxToken], isPrettified: Bool, notice: String?) {
        guard pretty else { return (text, [], false, nil) }

        let units = Array(text.utf16)
        let (raw, lexValid) = lex(units)
        if isTruncated { return (text, bestEffortTokens(raw), false, nil) }

        if lexValid && !raw.isEmpty {
            var printer = PrettyPrinter(units: units, raw: raw)
            if printer.printDocument() {
                return (String(decoding: printer.output, as: UTF16.self), printer.tokens, true, nil)
            }
        }
        return (text, bestEffortTokens(raw), false, "Invalid JSON — showing raw")
    }

    private static func lex(_ units: [UInt16]) -> (tokens: [RawToken], valid: Bool) {
        var tokens: [RawToken] = []
        var (valid, i) = (true, 0)
        while i < units.count {
            let u = units[i]
            if u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D {
                i += 1
            } else if let punct = punctuation[u] {
                tokens.append((punct, i, i + 1))
                i += 1
            } else if u == 0x22 {
                let end = scanString(units, from: i, valid: &valid)
                tokens.append((.string, i, end))
                i = end
            } else if u == 0x2D || isDigit(u) {
                let end = scanNumber(units, from: i, valid: &valid)
                tokens.append((.number, i, end))
                i = end
            } else if isAlpha(u) {
                var end = i + 1
                while end < units.count && isAlpha(units[end]) { end += 1 }
                let word = String(decoding: units[i..<end], as: UTF16.self)
                if word == "true" || word == "false" || word == "null" {
                    tokens.append((.keyword, i, end))
                } else {
                    valid = false
                }
                i = end
            } else {
                valid = false
                i += 1
            }
        }
        return (tokens, valid)
    }

    private static func scanString(_ units: [UInt16], from start: Int, valid: inout Bool) -> Int {
        var i = start + 1
        while i < units.count {
            let u = units[i]
            if u == 0x22 { return i + 1 }
            if u == 0x5C {
                i += 1
                guard i < units.count else {
                    valid = false
                    return i
                }
                if units[i] == 0x75 {  // \uXXXX
                    let ok = i + 4 < units.count && (1...4).allSatisfy { isHex(units[i + $0]) }
                    i += ok ? 5 : 1
                    if !ok { valid = false }
                } else {
                    if !isSimpleEscape(units[i]) { valid = false }
                    i += 1
                }
            } else {
                if u < 0x20 { valid = false }
                i += 1
            }
        }
        valid = false
        return i
    }

    private static func scanNumber(_ units: [UInt16], from start: Int, valid: inout Bool) -> Int {
        var i = start
        func skipDigits() -> Int {
            let from = i
            while i < units.count && isDigit(units[i]) { i += 1 }
            return i - from
        }
        if i < units.count && units[i] == 0x2D { i += 1 }
        if i < units.count && units[i] == 0x30 {
            i += 1
            if skipDigits() > 0 { valid = false }
        } else if skipDigits() == 0 {
            valid = false
        }
        if i < units.count && units[i] == 0x2E {
            i += 1
            if skipDigits() == 0 { valid = false }
        }
        if i < units.count && (units[i] == 0x65 || units[i] == 0x45) {
            i += 1
            if i < units.count && (units[i] == 0x2B || units[i] == 0x2D) { i += 1 }
            if skipDigits() == 0 { valid = false }
        }
        return i
    }

    private static func bestEffortTokens(_ raw: [RawToken]) -> [SyntaxToken] {
        raw.indices.map { idx in
            let tok = raw[idx]
            let kind: SyntaxTokenKind =
                switch tok.kind {
                case .string: (idx + 1 < raw.count && raw[idx + 1].kind == .colon) ? .key : .string
                case .number: .number
                case .keyword: .keyword
                case .lBrace, .rBrace, .lBracket, .rBracket, .colon, .comma: .punctuation
                }
            return SyntaxToken(
                range: NSRange(location: tok.start, length: tok.end - tok.start), kind: kind)
        }
    }

    private static func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
    private static func isAlpha(_ u: UInt16) -> Bool { (u | 0x20) >= 0x61 && (u | 0x20) <= 0x7A }
    private static func isHex(_ u: UInt16) -> Bool {
        isDigit(u) || ((u | 0x20) >= 0x61 && (u | 0x20) <= 0x66)
    }
    private static func isSimpleEscape(_ u: UInt16) -> Bool {
        [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(u)
    }

    private struct PrettyPrinter {
        private static let maxDepth = 512
        let units: [UInt16]
        let raw: [RawToken]
        var index = 0
        var output: [UInt16] = []
        var tokens: [SyntaxToken] = []

        mutating func printDocument() -> Bool {
            output.reserveCapacity(units.count + units.count / 4)
            tokens.reserveCapacity(raw.count)
            return parseValue(depth: 0) && index == raw.count
        }

        private func peek(_ kind: RawKind) -> Bool { index < raw.count && raw[index].kind == kind }

        private mutating func parseValue(depth: Int) -> Bool {
            guard index < raw.count else { return false }
            switch raw[index].kind {
            case .lBrace: return parseObject(depth: depth)
            case .lBracket: return parseArray(depth: depth)
            case .string: return emitCurrent(as: .string)
            case .number: return emitCurrent(as: .number)
            case .keyword: return emitCurrent(as: .keyword)
            case .rBrace, .rBracket, .colon, .comma: return false
            }
        }

        private mutating func parseObject(depth: Int) -> Bool {
            guard depth < Self.maxDepth else { return false }
            emitCurrent(as: .punctuation)
            if peek(.rBrace) { return emitCurrent(as: .punctuation) }
            while true {
                emitIndent(depth + 1)
                guard peek(.string), emitCurrent(as: .key), peek(.colon),
                    emitCurrent(as: .punctuation)
                else { return false }
                output.append(0x20)
                guard parseValue(depth: depth + 1),
                    let closed = consumeCommaOrClose(.rBrace, depth: depth)
                else { return false }
                if closed { return true }
            }
        }

        private mutating func parseArray(depth: Int) -> Bool {
            guard depth < Self.maxDepth else { return false }
            emitCurrent(as: .punctuation)
            if peek(.rBracket) { return emitCurrent(as: .punctuation) }
            while true {
                emitIndent(depth + 1)
                guard parseValue(depth: depth + 1),
                    let closed = consumeCommaOrClose(.rBracket, depth: depth)
                else { return false }
                if closed { return true }
            }
        }

        private mutating func consumeCommaOrClose(_ close: RawKind, depth: Int) -> Bool? {
            if peek(.comma) {
                emitCurrent(as: .punctuation)
                return false
            }
            guard peek(close) else { return nil }
            emitIndent(depth)
            emitCurrent(as: .punctuation)
            return true
        }

        @discardableResult
        private mutating func emitCurrent(as kind: SyntaxTokenKind) -> Bool {
            let tok = raw[index]
            index += 1
            let range = NSRange(location: output.count, length: tok.end - tok.start)
            output.append(contentsOf: units[tok.start..<tok.end])
            tokens.append(SyntaxToken(range: range, kind: kind))
            return true
        }

        private mutating func emitIndent(_ depth: Int) {
            output.append(0x0A)
            for _ in 0..<(depth * 2) { output.append(0x20) }
        }
    }
}
