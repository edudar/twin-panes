/// The Markdown CI appends to the GitHub Actions job summary: test counts, total line
/// coverage and a row per module.
public struct JobSummary: Sendable {
    private let modules: [ModuleTotals]
    private let tests: TestCounts?
    private let commit: String?

    public init(files: [FileTotals], tests: TestCounts?, commit: String?) {
        self.modules = ModuleTotals.grouping(files)
        self.tests = tests
        self.commit = commit
    }

    public var markdown: String {
        let total = LineSummary(adding: modules.map(\.lines))
        var lines = [commit.map { "### Coverage at \($0)" } ?? "### Coverage", ""]
        if let tests {
            lines.append(
                "**\(groupingDigits(tests.total)) tests**: \(groupingDigits(tests.passed)) passed, "
                    + "\(groupingDigits(tests.failed)) failed, \(groupingDigits(tests.skipped)) skipped."
            )
        }
        lines.append(
            "Line coverage of `TwinPanesKit/Sources`: **\(total.percentText)** "
                + "(\(groupingDigits(total.covered)) of \(groupingDigits(total.count)) lines).")
        lines += [
            "", "| Module | Line coverage | Missed | Lines |", "| --- | ---: | ---: | ---: |",
        ]
        for module in modules {
            let missed = module.lines.count - module.lines.covered
            lines.append(
                "| \(module.name) | \(module.lines.percentText) | \(groupingDigits(missed)) "
                    + "| \(groupingDigits(module.lines.count)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
