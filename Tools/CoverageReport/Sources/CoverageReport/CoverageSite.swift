/// Every file of the coverage site built from one export: the index, the stylesheet and
/// a page per source file, plus the job summary. Values only; writing them is the
/// command's job.
public struct CoverageSite: Sendable {
    public struct File: Sendable, Equatable {
        /// Relative to the site's root, such as `coverage/BrowserKit/PathField.swift.html`.
        public let path: String
        public let contents: String
    }

    public let files: [File]
    public let jobSummary: String

    /// - Parameters:
    ///   - sourcesRoot: the absolute folder every file in the export must sit under, such
    ///     as `<checkout>/TwinPanesKit/Sources`; pages are named relative to it.
    ///   - readSource: the text of the source file at an absolute path, as it was when
    ///     the tests ran.
    /// - Throws: `CoverageSiteError` when a file lies outside `sourcesRoot` or is shorter
    ///   than its coverage reaches, and whatever `readSource` throws.
    public init(
        export: CoverageExport, sourcesRoot: String, tests: TestCounts?, commit: String?,
        readSource: (String) throws -> String
    ) throws {
        let root = sourcesRoot.hasSuffix("/") ? sourcesRoot : sourcesRoot + "/"
        var files: [File] = []
        var totals: [FileTotals] = []
        for file in export.files {
            let (page, lines) = try Self.sourcePage(of: file, root: root, readSource: readSource)
            files.append(File(path: page.sitePath, contents: page.html))
            totals.append(
                FileTotals(relativePath: page.relativePath, lines: LineSummary(lines: lines)))
        }
        files.append(
            File(
                path: IndexPage.sitePath,
                contents: IndexPage(files: totals, tests: tests, commit: commit).html))
        files.append(File(path: SiteStylesheet.fileName, contents: SiteStylesheet.contents))
        self.files = files
        self.jobSummary = JobSummary(files: totals, tests: tests, commit: commit).markdown
    }

    private static func sourcePage(
        of file: FileCoverage, root: String, readSource: (String) throws -> String
    ) throws -> (SourcePage, [LineCoverage]) {
        guard file.path.hasPrefix(root) else {
            throw CoverageSiteError.outsideSources(path: file.path)
        }
        let source = try readSource(file.path)
        let lineCount = SourcePage.lineCount(of: source)
        let coveredLine = file.segments.map(\.line).max() ?? 0
        guard coveredLine <= lineCount else {
            throw CoverageSiteError.sourceChanged(
                path: file.path, sourceLines: lineCount, coveredLine: coveredLine)
        }
        let lines = LineCoverage.lines(from: file.segments, lineCount: lineCount)
        let page = SourcePage(
            relativePath: String(file.path.dropFirst(root.count)), source: source, coverage: lines)
        return (page, lines)
    }
}

public enum CoverageSiteError: Error, Equatable {
    case outsideSources(path: String)
    /// The source has fewer lines than the export's segments reach, so it changed after
    /// the tests ran and the marks would land on the wrong lines. A file that grew can't
    /// be caught this way; the export and the checkout must come from the same build.
    case sourceChanged(path: String, sourceLines: Int, coveredLine: Int)
}
