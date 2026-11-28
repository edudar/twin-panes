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

    @Test func prefetchesEvictedAddPagesAndSkipsLargeOverwrittenGaps() async throws {
        defer { cleanUp() }
        let page = Int(ByteSource.pageSize)
        let url = try makeFile(Array(repeating: 0x11, count: page * 5))
        let original = try ByteSource(url: url)
        let buffer = try EditBuffer(original: original, addDirectory: folder, addPageCapacity: 2)
        // Empty overwrite is a no-op and leaves the buffer unmodified.
        #expect(try buffer.overwrite(at: 0, with: Data()) == 0..<0)
        #expect(!buffer.isModified)

        // Overwrite pages 1, 2, 3 (3 pages > addPageCapacity 2, so page 1's add bytes get evicted).
        let edited = Data(repeating: 0xAA, count: page * 3)
        try buffer.overwrite(at: UInt64(page), with: edited)
        let snap = buffer.snapshot()
        #expect(snap.cachedBytes(UInt64(page)..<UInt64(page + 16)) == nil)

        // Prefetching a 100%-overwritten range (originals empty) reloads the evicted add page.
        #expect(await prefetched(snap, UInt64(page)..<UInt64(page + 16)) == nil)
        #expect(
            snap.cachedBytes(UInt64(page)..<UInt64(page + 16)) == Data(repeating: 0xAA, count: 16))

        // Prefetching across pages 0..5 must not load original page 2, which is fully overwritten.
        #expect(await prefetched(snap, 0..<UInt64(page * 5)) == nil)
        #expect(original.cachedBytes(UInt64(page * 2)..<UInt64(page * 2 + 16)) == nil)
        #expect(snap.cachedBytes(0..<16) == Data(repeating: 0x11, count: 16))
        #expect(
            snap.cachedBytes(UInt64(page * 4)..<UInt64(page * 4 + 16))
                == Data(repeating: 0x11, count: 16))
    }

    /// Viewing writes nothing: the add buffer comes with the first edit.
    @Test func insertsDeletesAndReplacesWithAnotherLength() throws {
        defer { cleanUp() }
        let buffer = try EditBuffer(
            original: ByteSource(url: makeFile(Array(0..<100))), addDirectory: folder)
        #expect(try buffer.replace(10..<10, with: Data([0xAA, 0xBB])) == 10..<12)
        #expect(
            try buffer.length == 102
                && buffer.snapshot().read(8..<14)
                    == Data([8, 9, 0xAA, 0xBB, 10, 11])
        )
        #expect(try buffer.replace(0..<5, with: Data()) == 0..<0)
        #expect(try buffer.length == 97 && buffer.snapshot().read(0..<2) == Data([5, 6]))
        #expect(try buffer.replace(90..<97, with: Data([1])) == 90..<91)
        #expect(try buffer.length == 91 && buffer.snapshot().read(89..<91) == Data([92, 1]))
        let before = buffer.tree
        #expect(throws: ByteSourceError.self) { try buffer.replace(90..<92, with: Data([2])) }
        #expect(buffer.tree.isSameVersion(as: before))
    }

    /// A delete writes no bytes, so it doesn't make the add buffer.
    @Test func aDeleteMakesNoAddBuffer() throws {
        defer { cleanUp() }
        let buffer = EditBuffer(original: try ByteSource(url: makeFile(Array(0..<10))))
        try buffer.replace(2..<4, with: Data())
        #expect(buffer.add == nil)
        #expect(try buffer.snapshot().read(0..<8) == Data([0, 1, 4, 5, 6, 7, 8, 9]))
    }

    /// Random inserts, deletes, replaces and overwrites against a flat model, through
    /// every read path and the dirty marks (bytes typed or pasted, wherever they moved).
    @Test func randomReplacesMatchAFlatModel() throws {
        defer { cleanUp() }
        let seed: UInt64 = 0xB0FF_E125_0000_0008
        var rng = SplitMix64(seed: seed)
        var model = (0..<3000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        var typed = [Bool](repeating: false, count: model.count)
        let buffer = try EditBuffer(
            original: ByteSource(url: makeFile(model)), addDirectory: folder)
        for step in 0..<400 {
            let offset = Int.random(in: 0...model.count, using: &rng)
            let removed = Int.random(in: 0...min(16, model.count - offset), using: &rng)
            let count = Int.random(in: 0...16, using: &rng)
            let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let range = offset..<(offset + removed)
            try buffer.replace(
                UInt64(range.lowerBound)..<UInt64(range.upperBound), with: Data(bytes))
            model.replaceSubrange(range, with: bytes)
            typed.replaceSubrange(range, with: [Bool](repeating: true, count: count))
            if step % 40 == 0 {
                let context: Comment = "seed \(seed), step \(step)"
                let all = 0..<UInt64(model.count)
                let snapshot = buffer.snapshot()
                #expect(snapshot.length == UInt64(model.count), context)
                #expect(try snapshot.read(all) == Data(model), context)
                #expect(try snapshot.readSequential(all) == Data(model), context)
                let marked = snapshot.modifiedRanges(in: all).flatMap { $0.map(Int.init) }
                #expect(Set(marked) == Set(typed.indices.filter { typed[$0] }), context)
            }
        }
    }

    @Test func makesItsAddBufferOnTheFirstEdit() throws {
        defer { cleanUp() }
        let url = try makeFile(Array(0..<10))
        let buffer = EditBuffer(original: try ByteSource(url: url))
        #expect(buffer.add == nil && buffer.snapshot().add == nil)
        #expect(try buffer.snapshot().read(2..<4) == Data([2, 3]))
        try buffer.overwrite(at: 3, with: Data([0xAA]))
        #expect(try buffer.add != nil && buffer.snapshot().read(2..<5) == Data([2, 0xAA, 4]))
    }

    /// The session's clone replaces the original before the first edit; snapshots taken
    /// earlier keep reading the file they had.
    @Test func attachSwitchesSourcesForLaterSnapshots() throws {
        defer { cleanUp() }
        let opened = try makeFile(Array(0..<10))
        let stand = folder.appendingPathComponent("clone.bin")  // a "clone" told apart
        try Data(repeating: 7, count: 10).write(to: stand)
        let buffer = EditBuffer(original: try ByteSource(url: opened))
        let before = buffer.snapshot()
        let add = try AddBuffer(directory: folder)
        buffer.attach(original: try ByteSource(url: stand), add: add)
        #expect(try before.read(0..<2) == Data([0, 1]))
        #expect(try buffer.snapshot().read(0..<2) == Data([7, 7]))
        try buffer.overwrite(at: 1, with: Data([0xBB]))
        #expect(buffer.add === add && add.length == 1)
        #expect(try buffer.snapshot().read(0..<3) == Data([7, 0xBB, 7]))
    }
}
