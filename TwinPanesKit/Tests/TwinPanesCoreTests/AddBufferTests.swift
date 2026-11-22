import Foundation
import Testing

@testable import TwinPanesCore

/// The byte at position `index` of every test stream, so any range can be checked.
private func pattern(_ range: Range<UInt64>) -> Data {
    Data(range.map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
}

struct AddBufferTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("AddBufferTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    @Test func appendsAndReadsBack() throws {
        defer { cleanUp() }
        let buffer = try AddBuffer(directory: folder)
        #expect(try buffer.append(pattern(0..<3)) == 0..<3)
        #expect(try buffer.append(pattern(3..<10)) == 3..<10)
        #expect(buffer.length == 10)
        #expect(try buffer.read(2..<9) == pattern(2..<9))
        #expect(buffer.cachedBytes(0..<10) == pattern(0..<10))
        #expect(try buffer.append(Data()) == 10..<10)
        #expect(buffer.length == 10)
        #expect(throws: ByteSourceError.self) { try buffer.read(5..<11) }
    }

    @Test func errorsReportPosixReasonsAndReadSequentialBypassesCache() throws {
        defer { cleanUp() }
        // Creating inside a regular file fails with a real POSIX errno (not hardcoded EACCES).
        let file = folder.appendingPathComponent("not-a-dir")
        try Data([1]).write(to: file)
        do {
            _ = try AddBuffer(directory: file)
            Issue.record("expected createFailed")
        } catch let error as AddBufferError {
            guard case .createFailed(_, let code) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(code != EACCES)
            #expect(error.description.contains(file.path))
        }
        let writeErr = AddBufferError.writeFailed(offset: 16, errno: ENOSPC)
        #expect(writeErr.description.contains("16"))
        #expect(writeErr.description.contains(String(cString: strerror(ENOSPC))))

        // Exact page-boundary reads and readSequential not repopulating evicted cache pages.
        let buffer = try AddBuffer(directory: folder, pageCapacity: 2)
        let total = AddBuffer.pageSize * 4
        _ = try buffer.append(pattern(0..<total))
        #expect(buffer.cachedBytes(0..<AddBuffer.pageSize) == nil)
        let boundary = (AddBuffer.pageSize - 1)..<(AddBuffer.pageSize + 1)
        #expect(
            try buffer.readSequential(0..<AddBuffer.pageSize) == pattern(0..<AddBuffer.pageSize))
        #expect(try buffer.readSequential(boundary) == pattern(boundary))
        #expect(buffer.cachedBytes(0..<AddBuffer.pageSize) == nil)
        #expect(throws: ByteSourceError.self) { try buffer.readSequential(total..<(total + 1)) }
    }

    /// Just-written bytes are in memory; pages evicted from the small cache come back
    /// from the file.
    @Test func cachesRecentPagesAndRereadsEvictedOnes() throws {
        defer { cleanUp() }
        let buffer = try AddBuffer(directory: folder, pageCapacity: 2)
        let total = AddBuffer.pageSize * 5 + 100
        _ = try buffer.append(pattern(0..<total))
        #expect(buffer.cachedBytes((total - 50)..<total) == pattern((total - 50)..<total))
        #expect(buffer.cachedBytes(0..<10) == nil)
        #expect(
            try buffer.read(0..<(AddBuffer.pageSize + 9)) == pattern(0..<(AddBuffer.pageSize + 9)))
        #expect(buffer.cachedBytes(0..<10) == pattern(0..<10))
    }

    @Test func deletesItsFileWhenReleased() throws {
        defer { cleanUp() }
        var buffer: AddBuffer? = try AddBuffer(directory: folder)
        let url = try #require(buffer?.url)
        _ = try buffer?.append(pattern(0..<100))
        #expect(FileManager.default.fileExists(atPath: url.path))
        buffer = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    /// Readers on other threads see consistent bytes for everything already written
    /// while one thread keeps appending.
    @Test func readsWhileAppending() throws {
        defer { cleanUp() }
        let buffer = try AddBuffer(directory: folder, pageCapacity: 4)
        let chunk: UInt64 = 10_000
        let failed = Flag()
        DispatchQueue.concurrentPerform(iterations: 6) { worker in
            if worker == 0 {
                for index in 0..<100 {
                    let start = UInt64(index) * chunk
                    _ = try? buffer.append(pattern(start..<(start + chunk)))
                }
                return
            }
            var rng = SplitMix64(seed: UInt64(worker))
            for _ in 0..<300 {
                let written = buffer.length
                guard written > 0 else { continue }
                let start = UInt64.random(in: 0..<written, using: &rng)
                let end = min(written, start + UInt64.random(in: 1...70_000, using: &rng))
                let expected = pattern(start..<end)
                if (try? buffer.read(start..<end)) != expected { failed.set() }
                if let cached = buffer.cachedBytes(start..<end), cached != expected {
                    failed.set()
                }
            }
        }
        #expect(!failed.isSet)
        #expect(buffer.length == 100 * chunk)
    }
}
