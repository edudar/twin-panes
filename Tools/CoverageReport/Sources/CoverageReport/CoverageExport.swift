import Foundation

/// The coverage of every source file in one `llvm-cov export -format=text` run.
///
/// Reads format version 3 (LLVM 12 and later). Only the parts the report uses are
/// decoded: each file's path and its segments. llvm-cov's own summaries are left out:
/// they add up lines per function, so a line holding a closure counts twice.
public struct CoverageExport: Sendable {
    public let files: [FileCoverage]

    /// Decodes an export.
    ///
    /// - Throws: `CoverageExportError` when the JSON isn't a version 3 llvm-cov export
    ///   holding exactly one set of files, or `DecodingError` when it is malformed.
    public init(json: Data) throws {
        let decoder = JSONDecoder()
        let format = try decoder.decode(Format.self, from: json)
        guard format.type == "llvm.coverage.json.export", format.version.hasPrefix("3.") else {
            throw CoverageExportError.unsupportedFormat(type: format.type, version: format.version)
        }
        let contents = try decoder.decode(Contents.self, from: json)
        guard contents.data.count == 1 else {
            throw CoverageExportError.unexpectedDataCount(contents.data.count)
        }
        files = contents.data[0].files
    }

    /// Read on its own first, so an export of another version fails on its version
    /// instead of on whichever field changed shape.
    private struct Format: Decodable {
        let type: String
        let version: String
    }

    private struct Contents: Decodable {
        struct Entry: Decodable {
            let files: [FileCoverage]
        }
        let data: [Entry]
    }
}

public enum CoverageExportError: Error, Equatable {
    case unsupportedFormat(type: String, version: String)
    /// llvm-cov writes one entry per export; more would mean a merged or unknown file.
    case unexpectedDataCount(Int)
}

/// One source file's coverage as llvm-cov reports it.
public struct FileCoverage: Sendable, Decodable {
    /// The absolute path llvm-cov recorded at build time.
    public let path: String
    /// Ordered by line, then column.
    public let segments: [CoverageSegment]

    private enum CodingKeys: String, CodingKey {
        case path = "filename"
        case segments
    }
}

/// A point in a file where the active coverage region changes.
///
/// The region that starts here runs until the next segment. Encoded by llvm-cov as
/// `[line, column, count, hasCount, isRegionEntry, isGapRegion]`.
public struct CoverageSegment: Sendable, Equatable {
    public let line: Int
    /// 1-based.
    public let column: Int
    public let count: UInt64
    /// False for code the compiler skipped (for example an inactive `#if` branch).
    public let hasCount: Bool
    /// True when a region starts here; false when an enclosing region resumes.
    public let isRegionEntry: Bool
    /// True for the whitespace between regions, which never counts as code.
    public let isGapRegion: Bool

    public init(
        line: Int, column: Int, count: UInt64, hasCount: Bool = true,
        isRegionEntry: Bool = true, isGapRegion: Bool = false
    ) {
        self.line = line
        self.column = column
        self.count = count
        self.hasCount = hasCount
        self.isRegionEntry = isRegionEntry
        self.isGapRegion = isGapRegion
    }
}

extension CoverageSegment: Decodable {
    public init(from decoder: any Decoder) throws {
        var fields = try decoder.unkeyedContainer()
        self.init(
            line: try fields.decode(Int.self),
            column: try fields.decode(Int.self),
            count: try fields.decode(UInt64.self),
            hasCount: try fields.decode(Bool.self),
            isRegionEntry: try fields.decode(Bool.self),
            isGapRegion: try fields.decode(Bool.self)
        )
    }
}
