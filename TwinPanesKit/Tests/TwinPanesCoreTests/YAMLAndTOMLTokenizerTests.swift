import Foundation
import Testing

@testable import TwinPanesCore

@Suite struct YAMLAndTOMLTokenizerTests {
    private func check(
        _ name: String, _ content: String, _ format: StructuredFormat,
        _ tokens: [SyntaxToken], _ expected: [(SyntaxTokenKind, String)]
    ) throws {
        let ns = content as NSString
        let got = tokens.map { ($0.kind, ns.substring(with: $0.range)) }
        for (kind, text) in expected { #expect(got.contains { $0.0 == kind && $0.1 == text }) }
        #expect(!got.contains { $0.0 == .comment && $0.1.contains("not a comment") })
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YAMLAndTOML-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        let pretty = try StructuredPreviewLoader.load(url: file, format: format, pretty: true)
        #expect(!pretty.isPrettified && pretty.text == content && pretty.tokens == tokens)
        let raw = try StructuredPreviewLoader.load(url: file, format: format, pretty: false)
        #expect(!raw.isPrettified && raw.tokens.isEmpty && raw.text == content)
    }

    @Test func yamlTokenizesSyntaxUnicodeAndRawMode() throws {
        let sample = """
            ---
            # full-line comment
            defaults: &base
              flags: [true, no, null, ~]
              nums: [42, 0x1F, 0o755, -3.14] # inline comment
            "quoted:key": "hello \\"world\\" # not a comment"
            'single:key': 'it''s # also not a comment'
            items:
              - *base
              - label: 日本語 🌍
            ...
            """
        let expected: [(SyntaxTokenKind, String)] = [
            (.keyword, "---"), (.comment, "# full-line comment"), (.key, "defaults"),
            (.punctuation, ":"), (.attribute, "&base"), (.keyword, "true"), (.keyword, "no"),
            (.keyword, "null"), (.keyword, "~"), (.number, "42"), (.number, "0x1F"),
            (.number, "0o755"), (.number, "-3.14"), (.comment, "# inline comment"),
            (.key, "\"quoted:key\""), (.string, "\"hello \\\"world\\\" # not a comment\""),
            (.key, "'single:key'"), (.string, "'it''s # also not a comment'"),
            (.punctuation, "-"), (.attribute, "*base"), (.key, "label"),
            (.string, "日本語 🌍"), (.keyword, "..."),
        ]
        try check("config.yaml", sample, .yaml, YAMLTokenizer.tokenize(sample), expected)
    }

    @Test func tomlTokenizesSyntaxUnicodeAndRawMode() throws {
        let sample = """
            # top comment
            title = "日本語 🌍 # keep"
            literal = 'raw \\n # keep'
            multi = \"\"\"\nline one # not a comment\"\"\"
            lit_multi = '''\nstill # not a comment'''
            [server]
            host.name = "localhost"
            "quoted.key" = true
            ports = [80, 443]
            meta = { hex = 0xDEAD_BEEF, oct = 0o755, bin = 0b1010, f = -1.5e2, bad = nan }
            created = 2026-11-27T08:30:00Z # trailing comment
            local_dt = 2026-11-27 08:30:00
            [[products]]
            enabled = false
            """
        let expected: [(SyntaxTokenKind, String)] = [
            (.comment, "# top comment"), (.key, "title"), (.punctuation, "="),
            (.string, "\"日本語 🌍 # keep\""), (.string, "'raw \\n # keep'"),
            (.string, "\"\"\"\nline one # not a comment\"\"\""),
            (.string, "'''\nstill # not a comment'''"), (.header, "[server]"),
            (.key, "host.name"), (.key, "\"quoted.key\""), (.keyword, "true"),
            (.punctuation, "["), (.number, "80"), (.punctuation, ","), (.number, "443"),
            (.punctuation, "]"), (.punctuation, "{"), (.key, "hex"), (.number, "0xDEAD_BEEF"),
            (.number, "0o755"), (.number, "0b1010"), (.number, "-1.5e2"), (.number, "nan"),
            (.punctuation, "}"), (.number, "2026-11-27T08:30:00Z"),
            (.comment, "# trailing comment"), (.number, "2026-11-27 08:30:00"),
            (.header, "[[products]]"), (.key, "enabled"), (.keyword, "false"),
        ]
        try check("Cargo.toml", sample, .toml, TOMLTokenizer.tokenize(sample), expected)
    }
}
