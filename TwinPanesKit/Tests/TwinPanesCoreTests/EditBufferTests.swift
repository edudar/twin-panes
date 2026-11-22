import Foundation
import Testing

@testable import TwinPanesCore

@MainActor
struct EditBufferTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("EditBufferTests-\(UUID().uuidString)")

    func makeFile(_ bytes: [UInt8]) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("file.bin")
        try Data(bytes).write(to: url)
        return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func prefetched(_ snapshot: EditSnapshot, _ range: Range<UInt64>) async -> ByteSourceError? {
        await withCheckedContinuation { done in
            snapshot.prefetch(range) { error in done.resume(returning: error) }
        }
    }

    @Test func overwritesAndTracksModifiedRanges() async throws {
        defer { cleanUp() }
        let buffer = try EditBuffer(
            original: ByteSource(url: makeFile(Array(0..<100))), addDirectory: folder)
        #expect(!buffer.isModified)
        let before = buffer.snapshot()
        #expect(try buffer.overwrite(at: 10, with: Data([0xAA, 0xBB])) == 10..<12)
        try buffer.overwrite(at: 12, with: Data([0xCC]))
        try buffer.overwrite(at: 50, with: Data([0xDD]))
        #expect(buffer.isModified)
        let after = buffer.snapshot()
        #expect(try after.read(9..<13) == Data([9, 0xAA, 0xBB, 0xCC]))
        #expect(try after.readSequential(49..<52) == Data([49, 0xDD, 51]))
        #expect(after.modifiedRanges(in: 0..<100) == [10..<13, 50..<51])
        #expect(after.modifiedRanges(in: 11..<60) == [11..<13, 50..<51])
        #expect(try before.read(10..<13) == Data([10, 11, 12]))
        #expect(await prefetched(after, 0..<100) == nil)
        #expect(after.cachedBytes(48..<52) == Data([48, 49, 0xDD, 51]))
        buffer.restore(buffer.openedTree)
        #expect(!buffer.isModified)
        #expect(throws: (any Error).self) { try buffer.overwrite(at: 99, with: Data([1, 2])) }
    }

    @Test func reportsTheOriginalGettingShorter() async throws {
        defer { cleanUp() }
        let url = try makeFile(Array(repeating: 7, count: 1000))
        let buffer = try EditBuffer(original: ByteSource(url: url), addDirectory: folder)
        try buffer.overwrite(at: 0, with: Data([1]))
        truncate(url.path, 100)
        #expect(throws: ByteSourceError.self) { try buffer.snapshot().read(0..<1000) }
        #expect(await prefetched(buffer.snapshot(), 0..<1000) != nil)
        #expect(buffer.snapshot().cachedBytes(0..<1000) == nil)
    }

    /// Random overwrites against a byte array, read back through every path.
    @Test func randomOverwritesMatchAFlatModel() async throws {
        defer { cleanUp() }
        let seed: UInt64 = 0xB0FF_E125_0000_0003
        var rng = SplitMix64(seed: seed)
        var model = (0..<5000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let buffer = try EditBuffer(
            original: ByteSource(url: makeFile(model)), addDirectory: folder)
        var written = Set<Int>()
        for step in 0..<400 {
            let offset = Int.random(in: 0..<model.count, using: &rng)
            let count = min(Int.random(in: 1...16, using: &rng), model.count - offset)
            let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            try buffer.overwrite(at: UInt64(offset), with: Data(bytes))
            model.replaceSubrange(offset..<(offset + count), with: bytes)
            written.formUnion(offset..<(offset + count))
            if step % 50 == 0 {
                let context: Comment = "seed \(seed), step \(step)"
                let snapshot = buffer.snapshot()
                #expect(try snapshot.read(0..<5000) == Data(model), context)
                #expect(try snapshot.readSequential(0..<5000) == Data(model), context)
                let marked = snapshot.modifiedRanges(in: 0..<5000).flatMap { $0.map(Int.init) }
                #expect(Set(marked) == written, context)
            }
        }
        #expect(await prefetched(buffer.snapshot(), 0..<5000) == nil)
        #expect(buffer.snapshot().cachedBytes(0..<5000) == Data(model))
    }
}
