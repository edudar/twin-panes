/// What the `coverage-report` command was asked to do, read from its arguments.
public struct ReportOptions: Sendable, Equatable {
    public static let usage = """
        usage: coverage-report --export <llvm-cov export.json> --sources <sources folder>
                               --output <site folder> [--summary <summary.md>]
                               [--commit <sha>] [--tests <n> --failed <n> --skipped <n>]
        """

    public let exportPath: String
    /// The folder every file in the export sits under, such as `TwinPanesKit/Sources`.
    public let sourcesRoot: String
    public let outputFolder: String
    /// Where to write the job summary's Markdown; nil writes none.
    public let summaryPath: String?
    public let commit: String?
    public let tests: TestCounts?

    /// - Throws: `ReportOptionsError` for an unknown option, an option without its
    ///   value, a missing required option, a count that isn't a whole number, or only
    ///   some of the three test counts.
    public init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            guard Self.options.contains(option) else {
                throw ReportOptionsError.unknownOption(option)
            }
            guard index + 1 < arguments.endIndex else {
                throw ReportOptionsError.missingValue(option: option)
            }
            values[option] = arguments[index + 1]
            index += 2
        }
        func required(_ option: String) throws -> String {
            guard let value = values[option] else { throw ReportOptionsError.missingOption(option) }
            return value
        }
        exportPath = try required("--export")
        sourcesRoot = try required("--sources")
        outputFolder = try required("--output")
        summaryPath = values["--summary"]
        commit = values["--commit"]
        tests = try Self.testCounts(from: values)
    }

    private static let options: Set = [
        "--export", "--sources", "--output", "--summary", "--commit", "--tests", "--failed",
        "--skipped",
    ]

    private static func testCounts(from values: [String: String]) throws -> TestCounts? {
        let counts = try ["--tests", "--failed", "--skipped"].map { option in
            try values[option].map { value in
                guard let count = Int(value), count >= 0 else {
                    throw ReportOptionsError.notACount(option: option, value: value)
                }
                return count
            }
        }
        if counts.allSatisfy({ $0 == nil }) {
            return nil
        }
        guard let total = counts[0], let failed = counts[1], let skipped = counts[2] else {
            throw ReportOptionsError.partialTestCounts
        }
        return TestCounts(total: total, failed: failed, skipped: skipped)
    }
}

public enum ReportOptionsError: Error, Equatable {
    case unknownOption(String)
    case missingValue(option: String)
    case missingOption(String)
    case notACount(option: String, value: String)
    /// `--tests`, `--failed` and `--skipped` come together or not at all.
    case partialTestCounts
}

extension ReportOptionsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownOption(let option): "Unknown option \(option)."
        case .missingValue(let option): "\(option) needs a value."
        case .missingOption(let option): "\(option) is required."
        case .notACount(let option, let value): "\(option) takes a whole number, not \"\(value)\"."
        case .partialTestCounts: "--tests, --failed and --skipped go together."
        }
    }
}

extension CoverageSiteError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .outsideSources(let path):
            "\(path) is not inside the sources folder."
        case .sourceChanged(let path, let sourceLines, let coveredLine):
            "\(path) has \(sourceLines) lines but its coverage reaches line \(coveredLine): "
                + "the export and the sources come from different builds."
        }
    }
}

extension CoverageExportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unsupportedFormat(let type, let version):
            "Not an llvm-cov export of format 3 (type \(type), version \(version))."
        case .unexpectedDataCount(let count):
            "Expected one export in the file, found \(count)."
        }
    }
}
