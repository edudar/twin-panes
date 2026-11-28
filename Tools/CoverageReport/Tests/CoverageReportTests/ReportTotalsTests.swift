import Testing

@testable import CoverageReport

/// Two modules, files out of order, one file with no code.
let sampleFiles = [
    FileTotals(relativePath: "Core/Zeta.swift", lines: LineSummary(count: 10, covered: 10)),
    FileTotals(relativePath: "App/UI/View.swift", lines: LineSummary(count: 100, covered: 70)),
    FileTotals(relativePath: "Core/Alpha.swift", lines: LineSummary(count: 30, covered: 27)),
    FileTotals(relativePath: "App/Model.swift", lines: LineSummary(count: 0, covered: 0)),
]

@Test func filesAreGroupedByModuleInNameOrder() {
    let modules = ModuleTotals.grouping(sampleFiles)

    #expect(modules.map(\.name) == ["App", "Core"])
    #expect(modules[0].files.map(\.relativePath) == ["App/Model.swift", "App/UI/View.swift"])
    #expect(modules[1].files.map(\.relativePath) == ["Core/Alpha.swift", "Core/Zeta.swift"])
}

@Test func aModulesTotalsAddUpItsFiles() {
    let modules = ModuleTotals.grouping(sampleFiles)

    #expect(modules[0].lines == LineSummary(count: 100, covered: 70))
    #expect(modules[1].lines == LineSummary(count: 40, covered: 37))
}

@Test func percentagesHaveOneDecimalAndNoCodeCountsAsFull() {
    #expect(LineSummary(count: 3, covered: 2).percentText == "66.7%")
    #expect(LineSummary(count: 0, covered: 0).percentText == "100.0%")
}

@Test func digitsAreGroupedInThrees() {
    #expect(groupingDigits(7) == "7")
    #expect(groupingDigits(1_000) == "1,000")
    #expect(groupingDigits(14_133) == "14,133")
    #expect(groupingDigits(1_234_567) == "1,234,567")
}
