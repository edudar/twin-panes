import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import TwinPanesCore

/// Fast, deterministic listing check across mixed and dynamic extensions (docs/plans/M4.md).
@Suite struct DirectoryReaderPerformanceTests {
    @Test func mixedAndDynamicExtensionsStayFastWithoutLeakingTypeCache() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryReaderPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let standard = ["txt", "png", "swift", "json", "bin", "md", ""]
        let total = 1_000
        let dynamicCount = 100
        for i in 0..<total {
            let ext =
                i < dynamicCount
                ? "dyn\(UUID().uuidString.prefix(8))"
                : standard[i % standard.count]
            let name = String(format: "f%04d", i) + (ext.isEmpty ? "" : ".\(ext)")
            let path = dir.appendingPathComponent(name).path
            let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
            #expect(fd >= 0)
            if fd >= 0 { close(fd) }
        }

        // Prime standard types, then verify unique dynamic extensions do not grow TypeNames.cache.
        _ = standard.filter { !$0.isEmpty }.map {
            TypeNames.description(of: UTType(filenameExtension: $0) ?? .data)
        }
        let cacheBefore = TypeNames.cachedCount
        let entries = try DirectoryReader.entries(of: dir)
        let cacheAfter = TypeNames.cachedCount

        #expect(entries.count == total)
        #expect(entries.allSatisfy { !$0.kind.isEmpty })
        #expect(cacheAfter - cacheBefore <= standard.count)
    }
}
