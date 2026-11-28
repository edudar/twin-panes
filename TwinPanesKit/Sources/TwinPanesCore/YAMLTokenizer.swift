import Foundation

/// Line-oriented lexer for YAML emitting UTF-16 `SyntaxToken` ranges (`docs/plans/M7b.md`, D-c).
enum YAMLTokenizer {
    static func tokenize(_ text: String) -> [SyntaxToken] {
        let u = Array(text.utf16)
        var (out, lineStart): ([SyntaxToken], Int) = ([], 0)
        while lineStart < u.count {
            let lineEnd = u[lineStart...].firstIndex(of: 0x0A) ?? u.count
            let end = (lineEnd > lineStart && u[lineEnd - 1] == 0x0D) ? lineEnd - 1 : lineEnd
            let first = u[lineStart..<end].firstIndex { !isSpace($0) } ?? end
            if first < end {
                var (ci, comment): (Int, Int?) = (first, nil)
                while ci < end {
                    switch u[ci] {
                    case 0x22, 0x27: ci = scanQuoted(u, ci, end)
                    case 0x23 where ci == first || isSpace(u[ci - 1]): (comment, ci) = (ci, end)
                    default: ci += 1
                    }
                }
                let rawEnd = comment ?? end
                let codeEnd = u[first..<rawEnd].lastIndex { !isSpace($0) }.map { $0 + 1 } ?? first
                if first < codeEnd { tokenizeCode(u, first, codeEnd, &out) }
                if let comment { emit(comment, end, .comment, &out) }
            }
            lineStart = min(lineEnd + 1, u.count)
        }
        return out
    }

    private static func tokenizeCode(
        _ u: [UInt16], _ first: Int, _ end: Int, _ out: inout [SyntaxToken]
    ) {
        let c0 = u[first]
        if first + 3 <= end && (c0 == 0x2D || c0 == 0x2E) && u[first + 1] == c0
            && u[first + 2] == c0 && (first + 3 == end || isSpace(u[first + 3]))
        {
            return emit(first, first + 3, .keyword, &out)
        }
        var (i, flow) = (first, 0)
        while i < end && u[i] == 0x2D && (i + 1 == end || isSpace(u[i + 1])) {
            emit(i, i + 1, .punctuation, &out)
            i = u[(i + 1)..<end].firstIndex { !isSpace($0) } ?? end
        }
        if let (kEnd, colon) = findKeyColon(u, i, end) {
            emit(i, kEnd, .key, &out)
            emit(colon, colon + 1, .punctuation, &out)
            i = u[(colon + 1)..<end].firstIndex { !isSpace($0) } ?? end
        }
        while i < end {
            switch u[i] {
            case 0x20, 0x09: i += 1
            case 0x26, 0x2A:
                let j = u[(i + 1)..<end].firstIndex { isSpace($0) || isFlow($0) } ?? end
                emit(i, j, .attribute, &out)
                i = j
            case 0x22, 0x27:
                let q = scanQuoted(u, i, end)
                emit(i, q, .string, &out)
                i = q
            case let c where isFlow(c):
                flow = max(0, flow + ((c == 0x5B || c == 0x7B) ? 1 : (c == 0x2C ? 0 : -1)))
                emit(i, i + 1, .punctuation, &out)
                i += 1
            default:
                let j = flow > 0 ? (u[i..<end].firstIndex { isFlow($0) } ?? end) : end
                let sEnd = u[i..<j].lastIndex { !isSpace($0) }.map { $0 + 1 } ?? i
                if sEnd > i { emit(i, sEnd, classifyScalar(u[i..<sEnd]), &out) }
                i = j
            }
        }
    }

    private static func findKeyColon(_ u: [UInt16], _ start: Int, _ end: Int) -> (Int, Int)? {
        guard start < end, !isFlow(u[start]), u[start] != 0x26, u[start] != 0x2A else { return nil }
        let from = (u[start] == 0x22 || u[start] == 0x27) ? scanQuoted(u, start, end) : start
        for i in from..<end {
            if u[i] == 0x3A && (i + 1 == end || isSpace(u[i + 1])) {
                let kEnd = u[start..<i].lastIndex { !isSpace($0) }.map { $0 + 1 } ?? start
                return kEnd > start ? (kEnd, i) : nil
            }
            if from > start && !isSpace(u[i]) { return nil }
        }
        return nil
    }
    private static func scanQuoted(_ u: [UInt16], _ start: Int, _ end: Int) -> Int {
        let q = u[start]
        var i = start + 1
        while i < end {
            switch u[i] {
            case 0x5C where q == 0x22: i = min(i + 2, end)
            case 0x27 where q == 0x27 && i + 1 < end && u[i + 1] == 0x27: i += 2
            case q: return i + 1
            default: i += 1
            }
        }
        return end
    }
    private static func classifyScalar(_ slice: ArraySlice<UInt16>) -> SyntaxTokenKind {
        let s = String(decoding: slice, as: UTF16.self).lowercased()
        if ["true", "false", "null", "~", "yes", "no"].contains(s) { return .keyword }
        let c = s.filter { $0 != "_" }
        let ok =
            [".inf", "+.inf", "-.inf", ".nan"].contains(s)
            || (c.hasPrefix("0x") && Int(c.dropFirst(2), radix: 16) != nil)
            || (c.hasPrefix("0o") && Int(c.dropFirst(2), radix: 8) != nil)
            || (Double(c) != nil && c.first.map { $0.isNumber || "+-.".contains($0) } == true)
        return ok ? .number : .string
    }
    private static func emit(_ s: Int, _ e: Int, _ k: SyntaxTokenKind, _ out: inout [SyntaxToken]) {
        out.append(SyntaxToken(range: NSRange(location: s, length: e - s), kind: k))
    }
    private static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }
    private static func isFlow(_ c: UInt16) -> Bool { [0x5B, 0x5D, 0x7B, 0x7D, 0x2C].contains(c) }
}
