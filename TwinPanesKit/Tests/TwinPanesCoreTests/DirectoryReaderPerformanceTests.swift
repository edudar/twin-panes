import Foundation
import XCTest

@testable import TwinPanesCore

/// Listing time (docs/plans/M4.md, step 1). Measured by hand on 100,500 entries: 7.5 s
/// with Finder's type descriptions and display names, 0.73 s with the keys read now.
/// Here 10,000 files, so the suite stays quick.
final class DirectoryReaderPerformanceTests: XCTestCase {
    func testListingTenThousandFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryReaderPerformance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let extensions = ["txt", "png", "swift", "json", "bin", "md", ""]
        for i in 0..<10_000 {
            let ext = extensions[i % extensions.count]
            let name = String(format: "f%05d", i) + (ext.isEmpty ? "" : ".\(ext)")
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path, contents: nil)
        }
        measure {
            let entries = try? DirectoryReader.entries(of: dir)
            XCTAssertEqual(entries?.count, 10_000)
            XCTAssertEqual(entries?.reduce(0) { $0 + ($1.kind.isEmpty ? 0 : 1) }, 10_000)
        }
    }
}
