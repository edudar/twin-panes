import Foundation

/// Lexer for TOML files emitting UTF-16 `SyntaxToken` ranges (`docs/plans/M7b.md`, D-c).
enum TOMLTokenizer {
    static func tokenize(_ text: String) -> [SyntaxToken] {
        let u = Array(text.utf16)
        var (out, stack): ([SyntaxToken], [UInt16]) = ([], [])
        var (i, lineStart, expectKey) = (0, true, false)
        while i < u.count {
            let c = u[i]
            switch c {
            case 0x20, 0x09: i += 1
            case 0x0A, 0x0D: (i, lineStart) = (i + 1, true)
            case 0x23:
                let e = u[i...].firstIndex { $0 == 0x0A || $0 == 0x0D } ?? u.count
                emit(i, e, .comment, &out)
                i = e
            case 0x5B where lineStart && stack.isEmpty:
                let (s, dbl) = (i, i + 1 < u.count && u[i + 1] == 0x5B)
                i += dbl ? 2 : 1
                header: while i < u.count && u[i] != 0x0A && u[i] != 0x0D {
                    switch u[i] {
                    case 0x22, 0x27: i = scanLineString(u, i)
                    case 0x5D:
                        i += (dbl && i + 1 < u.count && u[i + 1] == 0x5D) ? 2 : 1
                        break header
                    default: i += 1
                    }
                }
                emit(s, i, .header, &out)
                lineStart = false
            default:
                let tryKey = (lineStart && stack.isEmpty) || (expectKey && c != 0x7D)
                (lineStart, expectKey) = (false, false)
                if tryKey && scanKeyAndEquals(u, &i, &out) { continue }
                switch c {
                case 0x22, 0x27:
                    let s = i
                    if i + 2 < u.count && u[i + 1] == c && u[i + 2] == c {
                        i += 3
                        multi: while i < u.count {
                            switch u[i] {
                            case 0x5C where c == 0x22: i = min(i + 2, u.count)
                            case c where i + 2 < u.count && u[i + 1] == c && u[i + 2] == c:
                                i += 3
                                for _ in 0..<2 where i < u.count && u[i] == c { i += 1 }
                                break multi
                            default: i += 1
                            }
                        }
                    } else {
                        i = scanLineString(u, i)
                    }
                    emit(s, i, .string, &out)
                case 0x5B, 0x5D, 0x7B, 0x7D, 0x2C:
                    emit(i, i + 1, .punctuation, &out)
                    if c == 0x5B || c == 0x7B { stack.append(c) }
                    if (c == 0x5D || c == 0x7D) && !stack.isEmpty { stack.removeLast() }
                    expectKey = c == 0x7B || (c == 0x2C && stack.last == 0x7B)
                    i += 1
                default:
                    let s = i
                    i = u[i...].firstIndex(where: isDelim) ?? u.count
                    if isISODate(u[s..<i]) && i + 5 < u.count && u[i] == 0x20 && isTime(u, i + 1) {
                        i = u[(i + 1)...].firstIndex(where: isDelim) ?? u.count
                    }
                    emit(s, i, classify(u[s..<i]), &out)
                }
            }
        }
        return out
    }

    private static func scanKeyAndEquals(
        _ u: [UInt16], _ idx: inout Int, _ out: inout [SyntaxToken]
    ) -> Bool {
        var i = idx
        while i < u.count && u[i] != 0x0A && u[i] != 0x0D && u[i] != 0x23 {
            switch u[i] {
            case 0x22, 0x27: i = scanLineString(u, i)
            case 0x3D:
                let kEnd = u[idx..<i].lastIndex { $0 != 0x20 && $0 != 0x09 }.map { $0 + 1 } ?? idx
                if kEnd > idx { emit(idx, kEnd, .key, &out) }
                emit(i, i + 1, .punctuation, &out)
                idx = i + 1
                return true
            default: i += 1
            }
        }
        return false
    }
    private static func scanLineString(_ u: [UInt16], _ start: Int) -> Int {
        let q = u[start]
        var i = start + 1
        while i < u.count && u[i] != 0x0A && u[i] != 0x0D {
            switch u[i] {
            case 0x5C where q == 0x22: i = min(i + 2, u.count)
            case q: return i + 1
            default: i += 1
            }
        }
        return i
    }
    private static func classify(_ slice: ArraySlice<UInt16>) -> SyntaxTokenKind {
        let s = String(decoding: slice, as: UTF16.self)
        if s == "true" || s == "false" { return .keyword }
        let (u, c) = (Array(slice), s.filter { $0 != "_" })
        let ok =
            ["inf", "+inf", "-inf", "nan", "+nan", "-nan"].contains(s)
            || isISODate(u[...]) || isTime(u, 0)
            || (c.hasPrefix("0x") && Int(c.dropFirst(2), radix: 16) != nil)
            || (c.hasPrefix("0o") && Int(c.dropFirst(2), radix: 8) != nil)
            || (c.hasPrefix("0b") && Int(c.dropFirst(2), radix: 2) != nil)
            || (Double(c) != nil && c.first.map { $0.isNumber || "+-".contains($0) } == true)
        return ok ? .number : .string
    }
    private static func isISODate(_ s: ArraySlice<UInt16>) -> Bool {
        s.count >= 10 && s[s.startIndex + 4] == 0x2D && s[s.startIndex + 7] == 0x2D
            && [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy { (0x30...0x39).contains(s[s.startIndex + $0]) }
    }
    private static func isTime(_ u: [UInt16], _ i: Int) -> Bool {
        i + 4 < u.count && u[i + 2] == 0x3A
            && [0, 1, 3, 4].allSatisfy { (0x30...0x39).contains(u[i + $0]) }
    }
    private static func emit(_ s: Int, _ e: Int, _ k: SyntaxTokenKind, _ out: inout [SyntaxToken]) {
        out.append(SyntaxToken(range: NSRange(location: s, length: e - s), kind: k))
    }
    private static func isDelim(_ c: UInt16) -> Bool {
        c <= 0x20 || [0x23, 0x2C, 0x5D, 0x7D].contains(c)
    }
}
