import Foundation

/// One source file's line totals and where it sits in the report.
public struct FileTotals: Sendable, Equatable {
    /// The file's path below `TwinPanesKit/Sources`, such as `BrowserKit/PathField.swift`.
    public let relativePath: String
    public let lines: LineSummary

    public init(relativePath: String, lines: LineSummary) {
        self.relativePath = relativePath
        self.lines = lines
    }

    /// The first path component: the Swift module the file belongs to.
    public var module: String {
        String(relativePath.prefix { $0 != "/" })
    }
}

/// A module's files and their combined line totals.
public struct ModuleTotals: Sendable, Equatable {
    public let name: String
    /// Ordered by path.
    public let files: [FileTotals]
    public let lines: LineSummary

    /// The files grouped by module, modules ordered by name.
    public static func grouping(_ files: [FileTotals]) -> [ModuleTotals] {
        Dictionary(grouping: files, by: \.module)
            .map { name, files in
                ModuleTotals(
                    name: name, files: files.sorted { $0.relativePath < $1.relativePath },
                    lines: LineSummary(adding: files.map(\.lines)))
            }
            .sorted { $0.name < $1.name }
    }
}

/// How a test run ended, from its JUnit results.
public struct TestCounts: Sendable, Equatable {
    public let total: Int
    public let failed: Int
    public let skipped: Int

    public init(total: Int, failed: Int, skipped: Int) {
        self.total = total
        self.failed = failed
        self.skipped = skipped
    }

    public var passed: Int { total - failed - skipped }
}

extension LineSummary {
    /// Sums of several summaries, such as a module's files.
    init(adding summaries: some Sequence<LineSummary>) {
        var count = 0
        var covered = 0
        for summary in summaries {
            count += summary.count
            covered += summary.covered
        }
        self.init(count: count, covered: covered)
    }

    /// The covered share as shown everywhere in the report, such as `92.9%`; a summary
    /// with no code shows 100%, matching its tier.
    var percentText: String {
        String(format: "%.1f%%", percent)
    }

    var percent: Double {
        count == 0 ? 100 : Double(covered) * 100 / Double(count)
    }

    var tier: CoverageTier { CoverageTier(covered: covered, total: count) }
}

/// `number` with commas between groups of three digits, such as `13,126`. Fixed rather
/// than locale-dependent, so CI output doesn't change with the runner's settings.
func groupingDigits(_ number: Int) -> String {
    let digits = Array(String(number.magnitude))
    var grouped = ""
    for (index, digit) in digits.enumerated() {
        if index > 0, (digits.count - index) % 3 == 0 {
            grouped.append(",")
        }
        grouped.append(digit)
    }
    return number < 0 ? "-" + grouped : grouped
}
