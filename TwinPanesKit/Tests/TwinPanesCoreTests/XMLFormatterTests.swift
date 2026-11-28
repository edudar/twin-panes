import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct XMLFormatterTests {
    private func tokenPairs(_ text: String, _ tokens: [SyntaxToken]) -> [(SyntaxTokenKind, String)]
    {
        let ns = text as NSString
        return tokens.map { ($0.kind, ns.substring(with: $0.range)) }
    }

    private func withTempFile(_ name: String, data: Data, _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMLFormatter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        try body(file)
    }

    @Test func prettyPrintsMinifiedXMLAndEmitsExactUTF16Tokens() {
        let input =
            #"<?xml version="1.0" encoding="UTF-8"?><!-- note 🌍 --><root id="1" label='a🌍b'><item/><raw><![CDATA[<tag>]]></raw></root>"#
        let result = XMLFormatter.format(
            data: Data(input.utf8), text: input, format: .xml, pretty: true, isTruncated: false)
        #expect(result.isPrettified && result.notice == nil && result.text.contains("\n"))

        let pairs = tokenPairs(result.text, result.tokens)
        #expect(pairs.first?.0 == .keyword && pairs.first?.1.hasPrefix("<?xml ") == true)
        let expectedTail: [(SyntaxTokenKind, String)] = [
            (.comment, "<!-- note 🌍 -->"), (.punctuation, "<"), (.tag, "root"),
            (.attribute, "id"), (.punctuation, "="), (.string, #""1""#),
            (.attribute, "label"), (.punctuation, "="), (.string, #""a🌍b""#), (.punctuation, ">"),
            (.punctuation, "<"), (.tag, "item"), (.punctuation, "/>"),
            (.punctuation, "<"), (.tag, "raw"), (.punctuation, ">"),
            (.string, "<![CDATA[<tag>]]>"),
            (.punctuation, "</"), (.tag, "raw"), (.punctuation, ">"),
            (.punctuation, "</"), (.tag, "root"), (.punctuation, ">"),
        ]
        let tail = Array(pairs.dropFirst())
        #expect(tail.count == expectedTail.count)
        for (a, e) in zip(tail, expectedTail) { #expect(a.0 == e.0 && a.1 == e.1) }
        let single = tokenPairs("<a b='x🌍y'/>", XMLFormatter.tokenize("<a b='x🌍y'/>"))
        #expect(single.contains { $0.0 == .string && $0.1 == "'x🌍y'" })
    }

    @Test func binaryPlistDecodesInPrettyAndRawModesAndHandlesTruncatedOrCorrupt() throws {
        let bplist = try PropertyListSerialization.data(
            fromPropertyList: ["name": "Twin Panes", "count": 42, "enabled": true] as [String: Any],
            format: .binary, options: 0)
        #expect(XMLFormatter.isBinaryPlist(bplist))
        #expect(!XMLFormatter.isBinaryPlist(Data("<a/>".utf8)))

        try withTempFile("sample.plist", data: bplist) { file in
            let pretty = try StructuredPreviewLoader.load(url: file, format: .plist, pretty: true)
            #expect(pretty.isPrettified && pretty.notice == nil)
            #expect(pretty.text.contains("Twin Panes"))
            let pairs = tokenPairs(pretty.text, pretty.tokens)
            #expect(pairs.contains { $0.0 == .tag && $0.1 == "plist" })
            #expect(pairs.contains { $0.0 == .keyword && $0.1.hasPrefix("<!DOCTYPE") })

            let raw = try StructuredPreviewLoader.load(url: file, format: .plist, pretty: false)
            #expect(!raw.isPrettified && raw.notice == nil && raw.tokens.isEmpty)
            #expect(raw.text.contains("Twin Panes"))

            let truncated = try StructuredPreviewLoader.load(
                url: file, format: .plist, pretty: true, maxPrettyBytes: 16, maxPrefixBytes: 16)
            #expect(truncated.isTruncated && !truncated.isPrettified && truncated.text.isEmpty)
            #expect(truncated.tokens.isEmpty)
            #expect(
                truncated.notice == "Binary property list is too large to preview — open in Hex")
        }

        let res = XMLFormatter.format(
            data: Data("bplist00corrupt-bytes".utf8), text: "", format: .plist, pretty: true,
            isTruncated: false)
        #expect(res.text.isEmpty && res.tokens.isEmpty && !res.isPrettified)
        #expect(res.notice == "Invalid binary property list — open in Hex")
    }

    @Test func malformedXMLFallsBackToRawWithBestEffortTokens() {
        let raw = #"<root attr="ok"><unclosed></root>"#
        let result = XMLFormatter.format(
            data: Data(raw.utf8), text: raw, format: .xml, pretty: true, isTruncated: false)
        #expect(!result.isPrettified && result.text == raw)
        #expect(result.notice == "Invalid XML — showing raw")
        let pairs = tokenPairs(result.text, result.tokens)
        #expect(pairs.contains { $0.0 == .tag && $0.1 == "root" })
        #expect(pairs.contains { $0.0 == .attribute && $0.1 == "attr" })
        #expect(pairs.contains { $0.0 == .string && $0.1 == #""ok""# })
    }

    @Test func doesNotExpandExternalEntities() throws {
        let xxeHosts =
            "<?xml version=\"1.0\"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM \"file:///etc/hosts\">]>"
            + "<root>&xxe;</root>"
        let hostsRes = XMLFormatter.format(
            data: Data(xxeHosts.utf8), text: xxeHosts, format: .xml, pretty: true,
            isTruncated: false)
        #expect(!hostsRes.text.contains("127.0.0.1") && !hostsRes.text.contains("localhost"))

        let secret = "XXE_SECRET_SENTINEL_999"
        try withTempFile("secret.txt", data: Data(secret.utf8)) { secretURL in
            let xxeLocal =
                "<?xml version=\"1.0\"?><!DOCTYPE foo [<!ENTITY xxe SYSTEM "
                + "\"\(secretURL.absoluteString)\">]><root>&xxe;</root>"
            let localRes = XMLFormatter.format(
                data: Data(xxeLocal.utf8), text: xxeLocal, format: .xml, pretty: true,
                isTruncated: false)
            #expect(!localRes.text.contains(secret))
        }
    }

    @Test func rawModeAndTruncatedXMLBehaveCorrectly() throws {
        let raw = #"<a b="1"><c/></a>"#
        let rawRes = XMLFormatter.format(
            data: Data(raw.utf8), text: raw, format: .xml, pretty: false, isTruncated: false)
        #expect(rawRes.text == raw && rawRes.tokens.isEmpty && !rawRes.isPrettified)
        #expect(rawRes.notice == nil)

        let big = "<root>\n" + String(repeating: "  <item id=\"1\"/>\n", count: 20) + "</root>\n"
        try withTempFile("big.xml", data: Data(big.utf8)) { file in
            let doc = try StructuredPreviewLoader.load(
                url: file, format: .xml, pretty: true, maxPrettyBytes: 64, maxPrefixBytes: 40)
            #expect(doc.isTruncated && !doc.isPrettified)
            #expect(doc.notice?.contains("Showing first ") == true)
            let pairs = tokenPairs(doc.text, doc.tokens)
            #expect(pairs.contains { $0.0 == .tag && $0.1 == "root" })
        }
    }
}
