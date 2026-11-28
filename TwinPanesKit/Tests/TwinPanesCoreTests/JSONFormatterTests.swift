import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct JSONFormatterTests {
    private func tokenPairs(_ text: String, _ tokens: [SyntaxToken]) -> [(SyntaxTokenKind, String)]
    {
        let ns = text as NSString
        return tokens.map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func withTempFile(_ name: String, content: String, _ body: (URL) throws -> Void) throws
    {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONFormatter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        try body(file)
    }

    @Test func prettyPrintsNestedJSONPreservingOrderExactNumbersAndCompactEmpties() {
        let input =
            #"{"z":9007199254740993,"a":{"ratio":1.500,"emptyObj":{},"emptyArr":[]},"m":[true,false,null,-2.5e+4]}"#
        let result = JSONFormatter.format(input, pretty: true, isTruncated: false)
        let expected =
            "{\n  \"z\": 9007199254740993,\n  \"a\": {\n    \"ratio\": 1.500,\n"
            + "    \"emptyObj\": {},\n    \"emptyArr\": []\n  },\n  \"m\": [\n"
            + "    true,\n    false,\n    null,\n    -2.5e+4\n  ]\n}"
        #expect(result.isPrettified && result.notice == nil && result.text == expected)
    }

    @Test func emitsExactUTF16TokenRangesWithUnicodeEmojiAndEscapes() {
        let input = #"{"emoji🌍":"say \"hi\" \\ \u0041","n":42,"ok":true}"#
        let result = JSONFormatter.format(input, pretty: true, isTruncated: false)
        let pairs = tokenPairs(result.text, result.tokens)
        let expected: [(SyntaxTokenKind, String)] = [
            (.punctuation, "{"), (.key, #""emoji🌍""#), (.punctuation, ":"),
            (.string, #""say \"hi\" \\ \u0041""#), (.punctuation, ","), (.key, #""n""#),
            (.punctuation, ":"), (.number, "42"), (.punctuation, ","), (.key, #""ok""#),
            (.punctuation, ":"), (.keyword, "true"), (.punctuation, "}"),
        ]
        #expect(pairs.count == expected.count)
        for (a, e) in zip(pairs, expected) { #expect(a.0 == e.0 && a.1 == e.1) }
    }

    @Test(arguments: [
        #"{"a": 1 "b": 2}"#, #"{"a": 1,}"#, #"{"a": [1, 2"#,
        #"{"a": "unclosed"#, #"{"a": 01}"#, #"{"a": 1} extra"#,
    ])
    func malformedJSONFallsBackToRawWithBestEffortTokens(_ raw: String) {
        let result = JSONFormatter.format(raw, pretty: true, isTruncated: false)
        #expect(!result.isPrettified && result.text == raw)
        #expect(result.notice == "Invalid JSON — showing raw")
        let pairs = tokenPairs(result.text, result.tokens)
        #expect(pairs.contains { $0.0 == .key && $0.1 == #""a""# })
        #expect(pairs.contains { $0.0 == .punctuation && $0.1 == "{" })
    }

    @Test func truncatedJSONSkipsReformattingPreservesNoticeAndEmitsTokens() throws {
        let body =
            "{\n  \"first\": 123,\n"
            + String(repeating: "  \"pad\": \"0123456789\",\n", count: 20) + "  \"last\": true\n}\n"
        try withTempFile("big.json", content: body) { file in
            let doc = try StructuredPreviewLoader.load(
                url: file, format: .json, pretty: true, maxPrettyBytes: 128, maxPrefixBytes: 40)
            #expect(doc.isTruncated && !doc.isPrettified)
            #expect(doc.notice?.contains("Showing first ") == true)
            #expect(doc.notice != "Invalid JSON — showing raw")
            let pairs = tokenPairs(doc.text, doc.tokens)
            #expect(pairs.contains { $0.0 == .key && $0.1 == #""first""# })
            #expect(pairs.contains { $0.0 == .number && $0.1 == "123" })
        }
    }

    @Test func rawModeReturnsOriginalTextWithEmptyTokens() throws {
        let raw = #"{"k":1}"#
        let formatted = JSONFormatter.format(raw, pretty: false, isTruncated: false)
        #expect(formatted.text == raw && formatted.tokens.isEmpty)
        #expect(!formatted.isPrettified && formatted.notice == nil)

        try withTempFile("small.json", content: raw) { file in
            let doc = try StructuredPreviewLoader.load(url: file, format: .json, pretty: false)
            #expect(doc.text == raw && doc.tokens.isEmpty && !doc.isPrettified && doc.notice == nil)
        }
    }
}
