import Foundation

/// RFC 4180 CSV/TSV parser, width-capped monospaced column aligner, and UTF-16 syntax tokenizer
/// (`docs/plans/M7b.md`, D-c).
enum DelimitedFormatter {
    static let maxColumnWidth = 48

    /// Formats and tokenizes delimited text into padded monospaced columns when `pretty` is true.
    /// Falls back to raw text with delimiter tokens when `isTruncated` is true or input is invalid.
    static func format(
        _ text: String, delimiter: Character, pretty: Bool, isTruncated: Bool
    ) -> (text: String, tokens: [SyntaxToken], isPrettified: Bool, notice: String?) {
        guard pretty else { return (text, [], false, nil) }
        if isTruncated {
            return (text, delimiterTokens(text, delimiter: delimiter), false, nil)
        }

        let (rows, valid) = parseRows(text, delimiter: delimiter)
        guard valid else {
            let label = delimiter == "\t" ? "TSV" : "CSV"
            return (
                text, delimiterTokens(text, delimiter: delimiter), false,
                "Invalid \(label) — showing raw"
            )
        }
        guard !rows.isEmpty else { return (text, [], false, nil) }

        let (aligned, tokens) = renderAligned(rows)
        return (aligned, tokens, true, nil)
    }

    static func parseRows(_ text: String, delimiter: Character) -> (rows: [[String]], valid: Bool) {
        var rows: [[String]] = []
        var index = text.startIndex
        let end = text.endIndex

        while index < end {
            var row: [String] = []
            while true {
                guard let field = parseField(text, from: &index, delimiter: delimiter) else {
                    return ([], false)
                }
                row.append(field)

                if index < end && text[index] == delimiter {
                    index = text.index(after: index)
                    continue
                }
                if index < end && isNewline(text[index]) {
                    index = text.index(after: index)
                }
                break
            }
            rows.append(row)
        }
        return (rows, true)
    }

    private static func parseField(
        _ text: String, from index: inout String.Index, delimiter: Character
    ) -> String? {
        let end = text.endIndex
        if index < end && text[index] == "\"" {
            return parseQuotedField(text, from: &index, delimiter: delimiter)
        }
        var field = ""
        while index < end {
            let ch = text[index]
            if ch == delimiter || isNewline(ch) { break }
            if ch == "\"" { return nil }
            field.append(ch)
            index = text.index(after: index)
        }
        return field
    }

    private static func parseQuotedField(
        _ text: String, from index: inout String.Index, delimiter: Character
    ) -> String? {
        let end = text.endIndex
        index = text.index(after: index)  // Opening quote.
        var field = ""
        var closed = false

        while index < end {
            let ch = text[index]
            index = text.index(after: index)
            if ch == "\"" {
                if index < end && text[index] == "\"" {
                    field.append("\"")
                    index = text.index(after: index)
                } else {
                    closed = true
                    break
                }
            } else {
                field.append(ch)
            }
        }

        guard closed else { return nil }
        if index < end && text[index] != delimiter && !isNewline(text[index]) {
            return nil
        }
        return field
    }

    private static func renderAligned(_ rows: [[String]]) -> (String, [SyntaxToken]) {
        let displayRows = rows.map { $0.map(displayCell) }
        var widths: [Int] = []
        for row in displayRows {
            if row.count > widths.count {
                widths.append(contentsOf: repeatElement(0, count: row.count - widths.count))
            }
            for (col, cell) in row.enumerated() where cell.count > widths[col] {
                widths[col] = cell.count
            }
        }

        var output = ""
        var tokens: [SyntaxToken] = []
        var utf16Offset = 0

        for (rowIndex, row) in displayRows.enumerated() {
            if rowIndex > 0 {
                output.append("\n")
                utf16Offset += 1
            }
            for (colIndex, cell) in row.enumerated() {
                let utf16Len = cell.utf16.count
                if utf16Len > 0 {
                    if rowIndex == 0 {
                        tokens.append(
                            SyntaxToken(
                                range: NSRange(location: utf16Offset, length: utf16Len),
                                kind: .header))
                    } else if colIndex % 2 == 1 {
                        tokens.append(
                            SyntaxToken(
                                range: NSRange(location: utf16Offset, length: utf16Len),
                                kind: .columnAlt))
                    }
                    output.append(cell)
                    utf16Offset += utf16Len
                }

                if colIndex < row.count - 1 {
                    let padding = widths[colIndex] - cell.count
                    if padding > 0 {
                        output.append(String(repeating: " ", count: padding))
                        utf16Offset += padding
                    }
                    output.append(" │ ")
                    tokens.append(
                        SyntaxToken(
                            range: NSRange(location: utf16Offset + 1, length: 1),
                            kind: .punctuation))
                    utf16Offset += 3
                }
            }
        }
        return (output, tokens)
    }

    private static func displayCell(_ raw: String) -> String {
        var singleLine = ""
        singleLine.reserveCapacity(min(raw.count, maxColumnWidth))
        var count = 0
        for ch in raw {
            let mapped: Character = isNewline(ch) ? " " : ch
            if count == maxColumnWidth {
                return String(singleLine.dropLast()) + "…"
            }
            singleLine.append(mapped)
            count += 1
        }
        return singleLine
    }

    private static func delimiterTokens(_ text: String, delimiter: Character) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var utf16Offset = 0
        for ch in text {
            let len = ch.utf16.count
            if ch == delimiter {
                tokens.append(
                    SyntaxToken(
                        range: NSRange(location: utf16Offset, length: len), kind: .punctuation))
            }
            utf16Offset += len
        }
        return tokens
    }

    private static func isNewline(_ ch: Character) -> Bool {
        ch == "\n" || ch == "\r\n" || ch == "\r"
    }
}
