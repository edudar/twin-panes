import CoverageReport
import Testing

private let required = ["--export", "e.json", "--sources", "src", "--output", "site"]

@Test func readsTheRequiredOptions() throws {
    let options = try ReportOptions(arguments: required)

    #expect(options.exportPath == "e.json")
    #expect(options.sourcesRoot == "src")
    #expect(options.outputFolder == "site")
    #expect(options.summaryPath == nil)
    #expect(options.commit == nil)
    #expect(options.tests == nil)
}

@Test func readsTheOptionalOnesInAnyOrder() throws {
    let options = try ReportOptions(
        arguments: ["--commit", "abc1234", "--skipped", "1", "--summary", "summary.md"] + required
            + ["--failed", "2", "--tests", "905"])

    #expect(options.summaryPath == "summary.md")
    #expect(options.commit == "abc1234")
    #expect(options.tests == TestCounts(total: 905, failed: 2, skipped: 1))
}

@Test func rejectsAnUnknownOption() {
    #expect(throws: ReportOptionsError.unknownOption("--colour")) {
        try ReportOptions(arguments: required + ["--colour", "red"])
    }
}

@Test func rejectsAnOptionWithoutItsValue() {
    #expect(throws: ReportOptionsError.missingValue(option: "--commit")) {
        try ReportOptions(arguments: required + ["--commit"])
    }
}

@Test func rejectsAMissingRequiredOption() {
    #expect(throws: ReportOptionsError.missingOption("--sources")) {
        try ReportOptions(arguments: ["--export", "e.json", "--output", "site"])
    }
}

@Test func rejectsACountThatIsNotAWholeNumber() {
    #expect(throws: ReportOptionsError.notACount(option: "--failed", value: "two")) {
        try ReportOptions(
            arguments: required + ["--tests", "3", "--failed", "two", "--skipped", "0"])
    }
}

@Test func rejectsSomeButNotAllTestCounts() {
    #expect(throws: ReportOptionsError.partialTestCounts) {
        try ReportOptions(arguments: required + ["--tests", "3"])
    }
}

@Test func errorsReadAsSentences() {
    #expect(ReportOptionsError.missingOption("--sources").description == "--sources is required.")
    #expect(
        CoverageSiteError.sourceChanged(path: "/s/A.swift", sourceLines: 612, coveredLine: 642)
            .description
            == "/s/A.swift has 612 lines but its coverage reaches line 642: "
            + "the export and the sources come from different builds.")
    #expect(
        CoverageExportError.unsupportedFormat(type: "x", version: "2.0")
            .description == "Not an llvm-cov export of format 3 (type x, version 2.0).")
}
