import Foundation
import Testing

@testable import TwinPanesCore

/// Listing off the main actor in batches (docs/plans/M4.md, D-a, step 2).
@MainActor
@Suite struct FolderListerTests {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderListerTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: dir)
    }

    func makeFiles(_ count: Int, in folder: URL? = nil) {
        let folder = folder ?? dir
        for i in 0..<count {
            FileManager.default.createFile(
                atPath: folder.appendingPathComponent("f\(i).bin").path, contents: nil)
        }
    }

    final class Recorder {
        var events: [FolderLister.Event] = []
        var batches: [[DirectoryEntry]] {
            events.compactMap { if case .batch(let b) = $0 { b } else { nil } }
        }
    }

    /// Runs `lister` to its end, recording what it delivered; `onEvent` may cancel it.
    func run(
        _ lister: FolderLister,
        onEvent: @escaping @MainActor (FolderLister.Event) -> Void = { _ in }
    ) async -> Recorder {
        let recorder = Recorder()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            lister.start { event in
                recorder.events.append(event)
                onEvent(event)
            }
            lister.whenFinished { done.resume() }
        }
        return recorder
    }

    @Test func batchesAddUpToTheFolder() async throws {
        defer { cleanUp() }
        makeFiles(2_500)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        makeFiles(10, in: dir.appendingPathComponent("sub"))  // not listed: one level only
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(".dot").path, contents: nil)
        // A long interval, so batches are cut by size alone: 100, 400, 1,000, 1,000…
        let recorder = await run(
            FolderLister(folder: dir, batchSize: 100, maxBatchSize: 1_000, interval: .seconds(10)))
        let names = Set(recorder.batches.joined().map(\.name))
        #expect(names.count == 2_502 && names.contains("sub") && names.contains(".dot"))
        #expect(recorder.batches.map(\.count).prefix(3) == [100, 400, 1_000])
        #expect(recorder.batches.allSatisfy { $0.count <= 1_000 })
        #expect(recorder.events.last == .done)
        #expect(recorder.batches.joined().first { $0.name == ".dot" }?.isHidden == true)
    }

    @Test func anEmptyFolderIsJustDone() async {
        defer { cleanUp() }
        let recorder = await run(FolderLister(folder: dir))
        #expect(recorder.events == [.done])
    }

    /// A cancelled listing delivers nothing more, even what was already on its way.
    @Test func cancellingStopsDelivery() async {
        defer { cleanUp() }
        makeFiles(3_000)
        let lister = FolderLister(folder: dir, batchSize: 100)
        let recorder = await run(lister) { _ in lister.cancel() }
        #expect(recorder.events.count == 1)
    }

    /// Navigating starts a new lister and cancels the old one: only the new folder's
    /// entries arrive afterwards.
    @Test func aSupersededListingNeverReachesTheNewFolder() async throws {
        defer { cleanUp() }
        let other = dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        makeFiles(2_000)
        makeFiles(3, in: other)
        let old = FolderLister(folder: dir, batchSize: 50)
        let new = FolderLister(folder: other)
        var shown: [String] = []
        old.start { if case .batch(let b) = $0 { shown += b.map(\.name) } }
        old.cancel()
        shown = []
        _ = await run(new) { if case .batch(let b) = $0 { shown += b.map(\.name) } }
        await withCheckedContinuation { done in old.whenFinished { done.resume() } }
        #expect(Set(shown) == ["f0.bin", "f1.bin", "f2.bin"])
    }

    @Test func errorsArriveAsEvents() async throws {
        defer { cleanUp() }
        let missing = dir.appendingPathComponent("missing")
        #expect(await run(FolderLister(folder: missing)).events == [.failed(.notFound(missing))])
        let file = dir.appendingPathComponent("file.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        #expect(await run(FolderLister(folder: file)).events == [.failed(.notAFolder(file))])
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        let lister = FolderLister(folder: locked)
        #expect(await run(lister).events == [.failed(.needsAccess(lister.folder))])
    }
}
