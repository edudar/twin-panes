import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct StructuredDocumentTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StructuredDocument-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func smallFileLoadsInFullWithoutTruncation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "hello\nworld\n".write(to: file, atomically: true, encoding: .utf8)

        let doc = try StructuredPreviewLoader.load(url: file, format: nil, pretty: true)
        #expect(doc == StructuredDocument(text: "hello\nworld\n"))
    }

    @Test func largeFileReadsBoundedPrefixAndTrimsUTF8AndLineBoundary() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("big.txt")
        let body =
            "alpha=日本語\nbeta=🌍🌍🌍🌍🌍\n"
            + String(repeating: "gamma=0123456789\n", count: 40)
        try body.write(to: file, atomically: true, encoding: .utf8)

        let doc = try StructuredPreviewLoader.load(
            url: file, format: nil, pretty: false, maxPrettyBytes: 256, maxPrefixBytes: 24)
        #expect(doc.isTruncated && doc.text == "alpha=日本語")
        #expect(doc.notice?.contains("Showing first ") == true)
        #expect(doc.notice?.contains("open in Hex or Editor for full file") == true)

        // Single-line multi-byte UTF-8 with no newline: cuts mid-emoji without corruption.
        let emojiFile = dir.appendingPathComponent("emoji.txt")
        try String(repeating: "🌍", count: 100).write(
            to: emojiFile, atomically: true, encoding: .utf8)
        let emojiDoc = try StructuredPreviewLoader.load(
            url: emojiFile, format: nil, pretty: false, maxPrettyBytes: 64, maxPrefixBytes: 10)
        #expect(emojiDoc.isTruncated && emojiDoc.text == "🌍🌍")
    }

    @Test func decodeTextHandlesBOMsUTF8AndLatin1Fallback() {
        let decode = StructuredPreviewLoader.decodeText
        #expect(decode(Data([0xEF, 0xBB, 0xBF]) + Data("café".utf8)) == "café")
        #expect(decode(Data([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69])) == "Hi")
        #expect(decode(Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])) == "Hi")
        #expect(decode(Data("日本語🌍".utf8)) == "日本語🌍")
        #expect(decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café")
    }

    @Test func propertiesTokenizerCoversSyntaxUnicodeAndRawMode() throws {
        let sample = """
              # hash comment
            ! bang comment
            host = example.com
            port: 8080
            ratio = -3.14
            enabled true
            disabled=false
            key\\=name\\:1 = 日本語 🌍
            multi = first line \\
              second line
            """
        let tokens = PropertiesTokenizer.tokenize(sample)
        let ns = sample as NSString
        let pairs = tokens.map { ($0.kind, ns.substring(with: $0.range)) }

        let expected: [(SyntaxTokenKind, String)] = [
            (.comment, "# hash comment"), (.comment, "! bang comment"),
            (.key, "host"), (.punctuation, "="), (.string, "example.com"),
            (.key, "port"), (.punctuation, ":"), (.number, "8080"),
            (.key, "ratio"), (.number, "-3.14"), (.key, "enabled"), (.keyword, "true"),
            (.key, "disabled"), (.keyword, "false"), (.key, "key\\=name\\:1"),
            (.string, "日本語 🌍"), (.key, "multi"),
            (.string, "first line \\"), (.string, "second line"),
        ]
        for (kind, text) in expected { #expect(pairs.contains { $0.0 == kind && $0.1 == text }) }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let propFile = dir.appendingPathComponent("app.properties")
        try sample.write(to: propFile, atomically: true, encoding: .utf8)

        let prettyDoc = try StructuredPreviewLoader.load(
            url: propFile, format: .properties, pretty: true)
        #expect(!prettyDoc.isPrettified && prettyDoc.tokens == tokens)
        let rawDoc = try StructuredPreviewLoader.load(
            url: propFile, format: .properties, pretty: false)
        #expect(rawDoc.tokens.isEmpty && rawDoc.text == sample)
    }
}
