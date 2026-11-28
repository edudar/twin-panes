import Foundation

/// XML and binary/XML `.plist` pretty-printer and UTF-16 syntax tokenizer
/// (`docs/plans/M7b.md`, D-c).
enum XMLFormatter {
    private static let binaryPlistMagic: [UInt8] = Array("bplist00".utf8)
    private static let commentStart = Array("<!--".utf16)
    private static let commentEnd = Array("-->".utf16)
    private static let cdataStart = Array("<![CDATA[".utf16)
    private static let cdataEnd = Array("]]>".utf16)
    private static let piStart = Array("<?".utf16)
    private static let piEnd = Array("?>".utf16)
    private static let declStart = Array("<!".utf16)

    /// Returns `true` when `data` begins with the 8-byte `bplist00` binary property list header.
    static func isBinaryPlist(_ data: Data) -> Bool { data.starts(with: binaryPlistMagic) }

    /// Formats and tokenizes XML or binary/XML `.plist` content.
    /// Decodes binary plists to XML (including in raw mode), pretty-prints valid XML without
    /// loading external entities, and falls back to raw text with best-effort tokens on errors.
    static func format(
        data: Data, text: String, format: StructuredFormat, pretty: Bool, isTruncated: Bool
    ) -> (text: String, tokens: [SyntaxToken], isPrettified: Bool, notice: String?) {
        if (format == .plist || format == .xml) && isBinaryPlist(data) {
            return formatBinaryPlist(data: data, pretty: pretty, isTruncated: isTruncated)
        }
        guard pretty else { return (text, [], false, nil) }
        if isTruncated { return (text, tokenize(text), false, nil) }
        if let prettyText = prettyPrint(xmlData: Data(text.utf8)) {
            return (prettyText, tokenize(prettyText), true, nil)
        }
        return (text, tokenize(text), false, "Invalid XML — showing raw")
    }

    /// Tokenizes XML text into UTF-16 `NSRange` syntax tokens (tags, attributes, strings,
    /// comments, CDATA, processing instructions, and DOCTYPE declarations).
    static func tokenize(_ text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var (tokens, i) = ([SyntaxToken](), 0)
        while i < units.count {
            guard units[i] == 0x3C else {
                i += 1
                continue
            }
            if matches(units, at: i, commentStart) {
                let end = scanUntil(units, from: i + commentStart.count, delimiter: commentEnd)
                tokens.append(token(i, end, .comment))
                i = end
            } else if matches(units, at: i, cdataStart) {
                let end = scanUntil(units, from: i + cdataStart.count, delimiter: cdataEnd)
                tokens.append(token(i, end, .string))
                i = end
            } else if matches(units, at: i, piStart) {
                let end = scanUntil(units, from: i + piStart.count, delimiter: piEnd)
                tokens.append(token(i, end, .keyword))
                i = end
            } else if matches(units, at: i, declStart) {
                let end = scanDeclaration(units, from: i)
                tokens.append(token(i, end, .keyword))
                i = end
            } else {
                i = scanTag(units, from: i, into: &tokens)
            }
        }
        return tokens
    }

    private static func formatBinaryPlist(
        data: Data, pretty: Bool, isTruncated: Bool
    ) -> (text: String, tokens: [SyntaxToken], isPrettified: Bool, notice: String?) {
        if isTruncated {
            return ("", [], false, "Binary property list is too large to preview — open in Hex")
        }
        var plistFormat = PropertyListSerialization.PropertyListFormat.binary
        guard
            let object = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &plistFormat),
            plistFormat == .binary,
            let xmlData = try? PropertyListSerialization.data(
                fromPropertyList: object, format: .xml, options: 0),
            let xmlString = String(data: xmlData, encoding: .utf8)
        else {
            return ("", [], false, "Invalid binary property list — open in Hex")
        }
        guard pretty else { return (xmlString, [], false, nil) }
        let formatted = prettyPrint(xmlData: xmlData) ?? xmlString
        return (formatted, tokenize(formatted), true, nil)
    }

    private static func prettyPrint(xmlData: Data) -> String? {
        // Explicitly disable external entity / DTD network or file loads (XXE-safe).
        let options: XMLNode.Options = [.nodePreserveAll, .nodeLoadExternalEntitiesNever]
        guard let doc = try? XMLDocument(data: xmlData, options: options) else { return nil }
        return String(data: doc.xmlData(options: [.nodePrettyPrint]), encoding: .utf8)
    }

    private static func scanTag(
        _ units: [UInt16], from start: Int, into tokens: inout [SyntaxToken]
    ) -> Int {
        let isClosing = start + 1 < units.count && units[start + 1] == 0x2F
        let openEnd = start + (isClosing ? 2 : 1)
        tokens.append(token(start, openEnd, .punctuation))

        var i = openEnd
        while i < units.count && isNameChar(units[i]) { i += 1 }
        if i > openEnd { tokens.append(token(openEnd, i, .tag)) }

        while i < units.count {
            while i < units.count && isWhitespace(units[i]) { i += 1 }
            guard i < units.count else { break }
            let u = units[i]
            if u == 0x3E {
                tokens.append(token(i, i + 1, .punctuation))
                return i + 1
            } else if u == 0x2F && i + 1 < units.count && units[i + 1] == 0x3E {
                tokens.append(token(i, i + 2, .punctuation))
                return i + 2
            } else if u == 0x3C {
                return i
            } else if u == 0x3D {
                tokens.append(token(i, i + 1, .punctuation))
                i += 1
            } else if u == 0x22 || u == 0x27 {
                let end = scanQuoted(units, from: i)
                tokens.append(token(i, end, .string))
                i = end
            } else if isNameChar(u) {
                let attrStart = i
                while i < units.count && isNameChar(units[i]) { i += 1 }
                tokens.append(token(attrStart, i, .attribute))
            } else {
                i += 1
            }
        }
        return i
    }

    private static func scanDeclaration(_ units: [UInt16], from start: Int) -> Int {
        var (i, bracketDepth) = (start + declStart.count, 0)
        while i < units.count {
            let u = units[i]
            if u == 0x22 || u == 0x27 {
                i = scanQuoted(units, from: i)
            } else if u == 0x5B {
                bracketDepth += 1
                i += 1
            } else if u == 0x5D {
                bracketDepth = max(0, bracketDepth - 1)
                i += 1
            } else if u == 0x3E && bracketDepth == 0 {
                return i + 1
            } else {
                i += 1
            }
        }
        return i
    }

    private static func scanQuoted(_ units: [UInt16], from start: Int) -> Int {
        var i = start + 1
        while i < units.count {
            if units[i] == units[start] { return i + 1 }
            i += 1
        }
        return i
    }

    private static func scanUntil(_ units: [UInt16], from start: Int, delimiter: [UInt16]) -> Int {
        var i = start
        while i + delimiter.count <= units.count {
            if matches(units, at: i, delimiter) { return i + delimiter.count }
            i += 1
        }
        return units.count
    }

    private static func matches(_ units: [UInt16], at index: Int, _ pattern: [UInt16]) -> Bool {
        guard index + pattern.count <= units.count else { return false }
        return !pattern.indices.contains { units[index + $0] != pattern[$0] }
    }

    private static func token(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) -> SyntaxToken {
        SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)
    }

    private static func isWhitespace(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D
    }

    private static func isNameChar(_ u: UInt16) -> Bool {
        !isWhitespace(u) && u != 0x3C && u != 0x3E && u != 0x2F && u != 0x3D
            && u != 0x22 && u != 0x27 && u != 0x3F && u != 0x21
    }
}
