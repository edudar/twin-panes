import Foundation
import Testing

@testable import CoverageReport

private struct MissingSource: Error, Equatable {
    let path: String
}

/// An export of the given files, each covered from line 1 to `lastLine` with count 1.
private func export(_ files: [(path: String, lastLine: Int)]) throws -> CoverageExport {
    let entries = files.map { file in
        #"{"filename": "\#(file.path)", "segments": [[1, 1, 1, true, true, false], "#
            + #"[\#(file.lastLine), 2, 0, false, false, false]]}"#
    }
    let json =
        #"{"type": "llvm.coverage.json.export", "version": "3.0.1", "data": [{"files": ["#
        + entries.joined(separator: ",") + "]}]}"
    return try CoverageExport(json: Data(json.utf8))
}

private let sources = [
    "/checkout/Sources/Core/Model.swift": "struct Model<T> {\n    let value: T\n}\n",
    "/checkout/Sources/App/View.swift": "let view = 1\nlet other = 2\n",
]

private func readSource(_ path: String) throws -> String {
    guard let source = sources[path] else { throw MissingSource(path: path) }
    return source
}

private func site(
    _ files: [(path: String, lastLine: Int)], sourcesRoot: String = "/checkout/Sources"
) throws -> CoverageSite {
    try CoverageSite(
        export: export(files), sourcesRoot: sourcesRoot, tests: nil, commit: "abc1234",
        readSource: readSource)
}

private let bothFiles = [
    (path: "/checkout/Sources/Core/Model.swift", lastLine: 3),
    (path: "/checkout/Sources/App/View.swift", lastLine: 2),
]

@Test func theSiteHasTheIndexTheStylesheetAndAPagePerFile() throws {
    let site = try site(bothFiles)

    #expect(
        site.files.map(\.path).sorted() == [
            "coverage/App/View.swift.html", "coverage/Core/Model.swift.html", "index.html",
            "report.css",
        ])
    #expect(site.files.first { $0.path == "report.css" }?.contents == SiteStylesheet.contents)
}

@Test func pagesShowTheSourceTextAndTheIndexListsEveryModule() throws {
    let site = try site(bothFiles)

    let page = try #require(site.files.first { $0.path == "coverage/Core/Model.swift.html" })
    #expect(page.contents.contains("struct Model&lt;T&gt; {"))
    let index = try #require(site.files.first { $0.path == "index.html" })
    #expect(index.contents.contains(#"data-name="App""#))
    #expect(index.contents.contains(#"data-name="Core""#))
}

@Test func theJobSummaryCoversTheSameFiles() throws {
    let site = try site(bothFiles)

    #expect(site.jobSummary.contains("| App | 100.0% | 0 | 2 |"))
    #expect(site.jobSummary.contains("| Core | 100.0% | 0 | 3 |"))
    #expect(site.jobSummary.hasPrefix("### Coverage at abc1234"))
}

@Test func aTrailingSlashOnTheSourcesRootChangesNothing() throws {
    let site = try site(bothFiles, sourcesRoot: "/checkout/Sources/")

    #expect(site.files.contains { $0.path == "coverage/App/View.swift.html" })
}

@Test func aFileOutsideTheSourcesIsRejected() {
    #expect(throws: CoverageSiteError.outsideSources(path: "/elsewhere/Tool.swift")) {
        try site([(path: "/elsewhere/Tool.swift", lastLine: 1)])
    }
}

@Test func aSourceShorterThanItsCoverageIsRejected() {
    #expect(
        throws: CoverageSiteError.sourceChanged(
            path: "/checkout/Sources/App/View.swift", sourceLines: 2, coveredLine: 5)
    ) {
        try site([(path: "/checkout/Sources/App/View.swift", lastLine: 5)])
    }
}

@Test func aMissingSourceFailsWithTheReadersError() {
    #expect(throws: MissingSource(path: "/checkout/Sources/App/Gone.swift")) {
        try site([(path: "/checkout/Sources/App/Gone.swift", lastLine: 1)])
    }
}
