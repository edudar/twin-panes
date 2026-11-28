/// The colour band a coverage percentage falls in (docs/plans/coverage-report.md, D-d).
public enum CoverageTier: String, Sendable {
    /// 90% and up.
    case high
    /// 75% and up.
    case medium
    case low

    /// The tier of `covered` out of `total`; a file with no code counts as high,
    /// since nothing in it went untested.
    public init(covered: Int, total: Int) {
        // Whole numbers, so a file exactly on a boundary never lands below it.
        if covered * 100 >= total * 90 {
            self = .high
        } else if covered * 100 >= total * 75 {
            self = .medium
        } else {
            self = .low
        }
    }
}
