import Foundation

/// Lexer for Java `.properties` files emitting UTF-16 `SyntaxToken` ranges (`docs/plans/M7b.md`).
enum PropertiesTokenizer {
    static func tokenize(_ text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var lineStart = 0
        var inContinuation = false

        while lineStart < units.count {
            var lineEnd = lineStart
            while lineEnd < units.count && units[lineEnd] != 0x0A { lineEnd += 1 }
            let contentEnd =
                (lineEnd > lineStart && units[lineEnd - 1] == 0x0D) ? lineEnd - 1 : lineEnd
            tokenizeLine(
                units, start: lineStart, end: contentEnd,
                inContinuation: &inContinuation, into: &tokens)
            lineStart = lineEnd < units.count ? lineEnd + 1 : units.count
        }
        return tokens
    }

    private static func tokenizeLine(
        _ units: [UInt16], start: Int, end: Int,
        inContinuation: inout Bool, into tokens: inout [SyntaxToken]
    ) {
        let first = skipSpace(units, from: start, to: end)
        guard first < end else {
            inContinuation = false
            return
        }

        if inContinuation {
            let valueEnd = trimSpace(units, from: first, to: end)
            if first < valueEnd { tokens.append(token(first, valueEnd, .string)) }
            inContinuation = hasTrailingContinuation(units, start: first, end: end)
            return
        }

        if units[first] == 0x23 || units[first] == 0x21 {  // '#' or '!'
            tokens.append(token(first, end, .comment))
            return
        }

        var keyEnd = first
        while keyEnd < end {
            let unit = units[keyEnd]
            if unit == 0x5C {  // '\' escapes the next unit in a key
                keyEnd = min(keyEnd + 2, end)
            } else if unit == 0x3D || unit == 0x3A || isSpace(unit) {
                break
            } else {
                keyEnd += 1
            }
        }
        if keyEnd > first { tokens.append(token(first, keyEnd, .key)) }

        var cursor = skipSpace(units, from: keyEnd, to: end)
        if cursor < end && (units[cursor] == 0x3D || units[cursor] == 0x3A) {
            tokens.append(token(cursor, cursor + 1, .punctuation))
            cursor = skipSpace(units, from: cursor + 1, to: end)
        }

        let valueEnd = trimSpace(units, from: cursor, to: end)
        let continues = hasTrailingContinuation(units, start: cursor, end: end)
        if cursor < valueEnd {
            let kind: SyntaxTokenKind =
                continues ? .string : classifyValue(units[cursor..<valueEnd])
            tokens.append(token(cursor, valueEnd, kind))
        }
        inContinuation = continues
    }

    private static func token(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) -> SyntaxToken {
        SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)
    }

    private static func classifyValue(_ slice: ArraySlice<UInt16>) -> SyntaxTokenKind {
        let lowered = String(decoding: slice, as: UTF16.self).lowercased()
        if lowered == "true" || lowered == "false" { return .keyword }
        var idx = slice.startIndex
        if idx < slice.endIndex && (slice[idx] == 0x2B || slice[idx] == 0x2D) {
            idx = slice.index(after: idx)
        }
        var (digits, seenDot) = (0, false)
        while idx < slice.endIndex {
            let u = slice[idx]
            if u >= 0x30 && u <= 0x39 {
                digits += 1
            } else if u == 0x2E && !seenDot {
                seenDot = true
            } else {
                return .string
            }
            idx = slice.index(after: idx)
        }
        return digits > 0 ? .number : .string
    }

    private static func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0x0C }

    private static func skipSpace(_ units: [UInt16], from start: Int, to end: Int) -> Int {
        var i = start
        while i < end && isSpace(units[i]) { i += 1 }
        return i
    }

    private static func trimSpace(_ units: [UInt16], from start: Int, to end: Int) -> Int {
        var i = end
        while i > start && isSpace(units[i - 1]) { i -= 1 }
        return i
    }

    private static func hasTrailingContinuation(_ units: [UInt16], start: Int, end: Int) -> Bool {
        var (count, i) = (0, end)
        while i > start && units[i - 1] == 0x5C {
            count += 1
            i -= 1
        }
        return !count.isMultiple(of: 2)
    }
}
