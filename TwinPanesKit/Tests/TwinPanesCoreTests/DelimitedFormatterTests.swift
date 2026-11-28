import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct DelimitedFormatterTests {
    private func tokenPairs(_ text: String, _ tokens: [SyntaxToken]) -> [(SyntaxTokenKind, String)]
    {
        let ns = text as NSString
        return tokens.map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func withTempFile(_ name: String, content: String, _ body: (URL) throws -> Void) throws
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DelimitedFormatter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        try body(file)
    }

    @Test func alignsCSVWithQuotesEscapesCRLFEmbeddedNewlinesAndUTF16Tokens() {
        let input =
            "name,note,tag\r\n"
            + "\"Ada, L.\",\"say \"\"hi\"\"\nnext\",🌍ok\r\n"
            + "Bob,short,end\r\n"
        let result = DelimitedFormatter.format(
            input, delimiter: ",", pretty: true, isTruncated: false)
        let expected =
            "name    │ note          │ tag\n"
            + "Ada, L. │ say \"hi\" next │ 🌍ok\n"
            + "Bob     │ short         │ end"
        #expect(result.isPrettified && result.notice == nil && result.text == expected)

        let pairs = tokenPairs(result.text, result.tokens)
        let expectedTokens: [(SyntaxTokenKind, String)] = [
            (.header, "name"), (.punctuation, "│"), (.header, "note"), (.punctuation, "│"),
            (.header, "tag"),
            (.punctuation, "│"), (.columnAlt, "say \"hi\" next"), (.punctuation, "│"),
            (.punctuation, "│"), (.columnAlt, "short"), (.punctuation, "│"),
        ]
        #expect(pairs.count == expectedTokens.count)
        for (a, e) in zip(pairs, expectedTokens) { #expect(a.0 == e.0 && a.1 == e.1) }
    }

    @Test func alignsTSVAndCapsColumnWidthAtMaxColumnWidth() {
        let wide = String(repeating: "x", count: 60)
        let capped = String(repeating: "x", count: DelimitedFormatter.maxColumnWidth - 1) + "…"
        let input = "id\tdescription\tflag\n1\t\(wide)\tyes\n"
        let result = DelimitedFormatter.format(
            input, delimiter: "\t", pretty: true, isTruncated: false)
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(result.isPrettified && result.notice == nil && lines.count == 2)
        #expect(lines[0] == "id │ description" + String(repeating: " ", count: 37) + " │ flag")
        #expect(lines[1] == "1  │ \(capped) │ yes")
        let pairs = tokenPairs(result.text, result.tokens)
        #expect(pairs.contains { $0.0 == .columnAlt && $0.1 == capped })
    }

    @Test(arguments: [
        "a,b\n\"unclosed,2", "a,b\n\"bad\"extra,2", "a,b\n1,quo\"te",
    ])
    func malformedCSVFallsBackToRawWithDelimiterTokens(_ raw: String) {
        let result = DelimitedFormatter.format(
            raw, delimiter: ",", pretty: true, isTruncated: false)
        #expect(!result.isPrettified && result.text == raw)
        #expect(result.notice == "Invalid CSV — showing raw")
        let pairs = tokenPairs(result.text, result.tokens)
        #expect(!pairs.isEmpty && pairs.allSatisfy { $0.0 == .punctuation && $0.1 == "," })
    }

    @Test func malformedTSVReportsTSVNotice() {
        let raw = "a\tb\n\"unclosed\t2"
        let result = DelimitedFormatter.format(
            raw, delimiter: "\t", pretty: true, isTruncated: false)
        #expect(!result.isPrettified && result.text == raw)
        #expect(result.notice == "Invalid TSV — showing raw")
        let pairs = tokenPairs(result.text, result.tokens)
        #expect(pairs.count == 2 && pairs.allSatisfy { $0.0 == .punctuation && $0.1 == "\t" })
    }

    @Test func truncatedCSVSkipsAlignmentPreservesNoticeAndEmitsDelimiterTokens() throws {
        let body = "col1,col2\n" + String(repeating: "alpha,0123456789\n", count: 20)
        try withTempFile("big.csv", content: body) { file in
            let doc = try StructuredPreviewLoader.load(
                url: file, format: .csv, pretty: true, maxPrettyBytes: 128, maxPrefixBytes: 48)
            #expect(doc.isTruncated && !doc.isPrettified)
            #expect(doc.notice?.contains("Showing first ") == true)
            #expect(doc.notice != "Invalid CSV — showing raw")
            let pairs = tokenPairs(doc.text, doc.tokens)
            #expect(!pairs.isEmpty && pairs.allSatisfy { $0.0 == .punctuation && $0.1 == "," })
        }
    }

    @Test func rawModeAndEmptyInputReturnUnalignedTextWithoutNotice() throws {
        let raw = "k,v\n1,2\n"
        let formatted = DelimitedFormatter.format(
            raw, delimiter: ",", pretty: false, isTruncated: false)
        #expect(formatted.text == raw && formatted.tokens.isEmpty)
        #expect(!formatted.isPrettified && formatted.notice == nil)

        let empty = DelimitedFormatter.format("", delimiter: ",", pretty: true, isTruncated: false)
        #expect(
            empty.text.isEmpty && empty.tokens.isEmpty && !empty.isPrettified && empty.notice == nil
        )

        try withTempFile("small.tsv", content: "k\tv\n1\t2\n") { file in
            let rawDoc = try StructuredPreviewLoader.load(url: file, format: .tsv, pretty: false)
            #expect(rawDoc.text == "k\tv\n1\t2\n" && rawDoc.tokens.isEmpty && !rawDoc.isPrettified)
            let prettyDoc = try StructuredPreviewLoader.load(url: file, format: .tsv, pretty: true)
            #expect(prettyDoc.isPrettified && prettyDoc.text == "k │ v\n1 │ 2")
        }
    }
}
