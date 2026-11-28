import Foundation

/// Semantic token categories emitted by structured format tokenizers (`docs/plans/M7b.md`, D-c).
public enum SyntaxTokenKind: Equatable, Sendable {
    case key, string, number, keyword, comment, tag, attribute, punctuation, header, columnAlt
}

/// A syntax-highlighted range in UTF-16 code units for direct `NSAttributedString` application.
public struct SyntaxToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Decoded and optionally formatted/tokenized content for Quick View (`docs/plans/M7b.md`, D-c).
public struct StructuredDocument: Equatable, Sendable {
    public let text: String
    public let tokens: [SyntaxToken]
    public let isPrettified: Bool
    public let isTruncated: Bool
    public let notice: String?

    public init(
        text: String, tokens: [SyntaxToken] = [], isPrettified: Bool = false,
        isTruncated: Bool = false, notice: String? = nil
    ) {
        self.text = text
        self.tokens = tokens
        self.isPrettified = isPrettified
        self.isTruncated = isTruncated
        self.notice = notice
    }
}

/// Bounded, O(1)-size-checked loader for structured and plain-text Quick View files
/// (`docs/plans/M7b.md`, D-c, D-d).
public enum StructuredPreviewLoader {
    public static let maxPrettyBytes = 2 * 1024 * 1024
    public static let maxPrefixBytes = 128 * 1024

    /// Loads `url` with an O(1) size check so multi-GB files only read `maxPrefixBytes`.
    /// Runs synchronously; call off `@MainActor`.
    public static func load(
        url: URL, format: StructuredFormat?, pretty: Bool,
        maxPrettyBytes: Int = maxPrettyBytes, maxPrefixBytes: Int = maxPrefixBytes
    ) throws -> StructuredDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fileSize = Int64(info.st_size)
        let isTruncated = fileSize > Int64(maxPrettyBytes)
        let rawData =
            try handle.read(upToCount: max(0, isTruncated ? maxPrefixBytes : maxPrettyBytes))
            ?? Data()

        let text: String
        let notice: String?
        if isTruncated {
            text = trimToLineBoundary(decodeText(trimIncompleteTrailingSequence(rawData)))
            let prefixStr = ByteCountFormatter.string(
                fromByteCount: Int64(rawData.count), countStyle: .file)
            let totalStr = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            notice =
                "Showing first \(prefixStr) of \(totalStr) — open in Hex or Editor for full file"
        } else {
            text = decodeText(rawData)
            notice = nil
        }

        if pretty && format == .json {
            let formatted = JSONFormatter.format(text, pretty: true, isTruncated: isTruncated)
            return StructuredDocument(
                text: formatted.text, tokens: formatted.tokens,
                isPrettified: formatted.isPrettified, isTruncated: isTruncated,
                notice: isTruncated ? notice : formatted.notice)
        }
        if let format, format == .xml || format == .plist {
            let formatted = XMLFormatter.format(
                data: rawData, text: text, format: format, pretty: pretty,
                isTruncated: isTruncated)
            return StructuredDocument(
                text: formatted.text, tokens: formatted.tokens,
                isPrettified: formatted.isPrettified, isTruncated: isTruncated,
                notice: formatted.notice ?? notice)
        }
        let tokens = (pretty && format == .properties) ? PropertiesTokenizer.tokenize(text) : []
        return StructuredDocument(
            text: text, tokens: tokens, isPrettified: false, isTruncated: isTruncated,
            notice: notice)
    }

    /// Decodes text bytes handling UTF-8 BOM, UTF-16LE/BE BOM, valid UTF-8, and Latin-1 fallback.
    public static func decodeText(_ data: Data) -> String {
        let boms: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8), ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
        ]
        for (bom, enc) in boms where data.starts(with: bom) {
            if let s = String(data: data.dropFirst(bom.count), encoding: enc) { return s }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func trimIncompleteTrailingSequence(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        if data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE]) {
            return data.count.isMultiple(of: 2) ? data : data.dropLast()
        }
        let start = data.startIndex
        var (end, cont) = (data.count, 0)
        while end > 0 && cont < 3 && (data[start + end - 1] & 0xC0) == 0x80 {
            end -= 1
            cont += 1
        }
        guard end > 0 else { return data }
        let lead = data[start + end - 1]
        let expected = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : lead < 0xF8 ? 4 : 0
        return (lead >= 0xC0 && cont + 1 < expected) ? data.prefix(end - 1) : data
    }

    private static func trimToLineBoundary(_ text: String) -> String {
        guard let nl = text.lastIndex(of: "\n") else { return text }
        let line = text[..<nl]
        return String(line.hasSuffix("\r") ? line.dropLast() : line)
    }
}
