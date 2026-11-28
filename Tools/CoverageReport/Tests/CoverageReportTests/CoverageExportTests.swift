import CoverageReport
import Foundation
import Testing

/// Five files from a real `llvm-cov export` of TwinPanesKit, paths rewritten under
/// `/checkout`: fully covered, partly covered, and never-run code.
private func fixtureExport() throws -> CoverageExport {
    try CoverageExport(json: Data(contentsOf: fixtureURL("export.json")))
}

/// `llvm-cov show -format=text` for the same five files, cut to `line|count` rows under
/// a `path:` header. An empty count means the line is not code.
private func fixtureShowCounts() throws -> [String: [UInt64?]] {
    let text = try String(contentsOf: fixtureURL("show-counts.txt"), encoding: .utf8)
    var counts: [String: [UInt64?]] = [:]
    var path = ""
    for row in text.split(separator: "\n") {
        if row.hasSuffix(":") {
            path = String(row.dropLast())
            continue
        }
        let count = row.split(separator: "|", omittingEmptySubsequences: false)[1]
        counts[path, default: []].append(UInt64(count))
    }
    return counts
}

private func fixtureURL(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

private func exportJSON(
    type: String = "llvm.coverage.json.export", version: String = "3.0.1", dataCount: Int = 1
)
    -> Data
{
    let data = Array(repeating: #"{"files": []}"#, count: dataCount).joined(separator: ",")
    return Data(#"{"type": "\#(type)", "version": "\#(version)", "data": [\#(data)]}"#.utf8)
}

@Test func decodesEachFilesPathAndSegments() throws {
    let export = try fixtureExport()

    #expect(export.files.count == 5)
    let pathField = try #require(
        export.files.first { $0.path.hasSuffix("BrowserKit/PathField.swift") })
    #expect(pathField.path == "/checkout/TwinPanesKit/Sources/BrowserKit/PathField.swift")
    #expect(
        pathField.segments.first
            == CoverageSegment(line: 7, column: 39, count: 0, hasCount: true, isRegionEntry: true))
    #expect(pathField.segments.count == 2)
}

@Test func computedLinesMatchLlvmCovsOwnLineCounts() throws {
    let showCounts = try fixtureShowCounts()
    for file in try fixtureExport().files {
        let expected = try #require(showCounts[file.path])

        let lines = LineCoverage.lines(from: file.segments, lineCount: expected.count)

        #expect(lines.map(\.count) == expected, "\(file.path)")
    }
}

@Test func rejectsAnExportOfAnotherFormatVersion() {
    #expect(
        throws: CoverageExportError.unsupportedFormat(
            type: "llvm.coverage.json.export", version: "2.0.1")
    ) {
        try CoverageExport(json: exportJSON(version: "2.0.1"))
    }
}

@Test func rejectsJSONThatIsNotAnLlvmCovExport() {
    #expect(throws: CoverageExportError.unsupportedFormat(type: "something.else", version: "3.0.1"))
    {
        try CoverageExport(json: exportJSON(type: "something.else"))
    }
}

@Test func rejectsAnExportWithMoreThanOneDataEntry() {
    #expect(throws: CoverageExportError.unexpectedDataCount(2)) {
        try CoverageExport(json: exportJSON(dataCount: 2))
    }
}

@Test func rejectsASegmentWithMissingFields() {
    let json = Data(
        #"""
        {"type": "llvm.coverage.json.export", "version": "3.0.1", "data": [{"files": [
          {"filename": "/a.swift", "segments": [[1, 1, 0]], "summary": {"lines": {"count": 1, "covered": 0}}}
        ]}]}
        """#.utf8)

    #expect(throws: DecodingError.self) { try CoverageExport(json: json) }
}
