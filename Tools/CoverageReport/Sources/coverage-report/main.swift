// coverage-report: writes the coverage site and the job summary for one llvm-cov export.
// The logic lives in the CoverageReport library; this file only reads and writes files.
// Exit status: 0 on success, 64 (EX_USAGE) for bad arguments, 1 for anything else.
// Files already in the output folder are overwritten, never deleted.

import CoverageReport
import Foundation

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

/// Our own errors say what went wrong in a sentence; Foundation's carry it in
/// `localizedDescription`.
func message(for error: any Error) -> String {
    switch error {
    case let error as CoverageSiteError: error.description
    case let error as CoverageExportError: error.description
    default: error.localizedDescription
    }
}

let options: ReportOptions
do {
    options = try ReportOptions(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("coverage-report: \(error)\n\(ReportOptions.usage)", status: 64)
}

do {
    let export = try CoverageExport(
        json: Data(contentsOf: URL(fileURLWithPath: options.exportPath)))
    let site = try CoverageSite(
        export: export,
        sourcesRoot: URL(fileURLWithPath: options.sourcesRoot).standardizedFileURL.path,
        tests: options.tests, commit: options.commit
    ) { path in
        try String(contentsOfFile: path, encoding: .utf8)
    }
    let output = URL(fileURLWithPath: options.outputFolder)
    for file in site.files {
        let url = output.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.contents.utf8).write(to: url)
    }
    if let summaryPath = options.summaryPath {
        try Data(site.jobSummary.utf8).write(to: URL(fileURLWithPath: summaryPath))
    }
    print("Wrote \(site.files.count) files to \(options.outputFolder)")
} catch {
    fail("coverage-report: \(message(for: error))", status: 1)
}
