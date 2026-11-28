// swift-tools-version: 6.0
// CoverageReport: turns `llvm-cov export` JSON into the HTML coverage pages that CI
// publishes (docs/plans/coverage-report.md). CI tooling only; the app never links it.

import PackageDescription

let package = Package(
    name: "CoverageReport",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "CoverageReport"),
        .executableTarget(name: "coverage-report", dependencies: ["CoverageReport"]),
        .testTarget(
            name: "CoverageReportTests",
            dependencies: ["CoverageReport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
