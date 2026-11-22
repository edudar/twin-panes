import Foundation
import Testing

@testable import TwinPanesCore

/// Claims `length` bytes but only has `data`: a file that got shorter after opening.
private struct ShrunkBytes: ByteReading {
    let data: Data
    let length: UInt64

    func read(_ range: Range<UInt64>) throws -> Data {
        let end = min(Int(range.upperBound), data.count)
        return Int(range.lowerBound) < end ? data[Int(range.lowerBound)..<end] : Data()
    }
}

@Suite struct ByteReadingWriteTests {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("ByteReadingWriteTests-\(UUID().uuidString).bin")
    let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })

    @Test func writesTheRangeInChunks() throws {
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = ShrunkBytes(data: data, length: UInt64(data.count))
        try source.write(100..<9_100, to: destination, chunkSize: 1000)
        #expect(try Data(contentsOf: destination) == data[100..<9_100])
    }

    /// Review bug 4: a short read used to be written as if complete and reported as saved.
    @Test func throwsWhenTheSourceEndsEarly() throws {
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = ShrunkBytes(data: data[0..<2_500], length: UInt64(data.count))
        #expect(throws: ByteSourceError.truncated(expected: 9_000, available: 2_500)) {
            try source.write(1_000..<9_000, to: destination, chunkSize: 1000)
        }
    }
}
