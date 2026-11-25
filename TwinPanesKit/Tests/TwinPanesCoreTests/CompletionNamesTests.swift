import Foundation
import Synchronization
import Testing

@testable import TwinPanesCore

/// The names path completion reads (docs/plans/M5.md, D-e, step 21).
@MainActor
@Suite struct CompletionNamesTests {
    /// A folder listing the test controls: counts reads and can hold one back.
    final class Listing: Sendable {
        let reads = Mutex<[String]>([])
        let held = Mutex<String?>(nil)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        func read(_ folder: URL) -> [PathCompletion.Candidate] {
            reads.withLock { $0.append(folder.lastPathComponent) }
            if held.withLock({ $0 }) == folder.lastPathComponent {
                started.signal()
                release.wait()
            }
            return [.init(name: "in-\(folder.lastPathComponent)", isFolder: false)]
        }
    }

    let listing = Listing()
    let a = URL(fileURLWithPath: "/x/a", isDirectory: true)
    let b = URL(fileURLWithPath: "/x/b", isDirectory: true)

    var names: CompletionNames {
        let listing = listing
        return CompletionNames(read: { listing.read($0) })
    }

    @Test func aFolderIsReadOnceAndKept() async {
        let names = names
        #expect(names.cached(in: a) == nil)
        let first = await names.names(in: a)
        let again = await names.names(in: a)
        #expect(first?.map(\.name) == ["in-a"] && again == first)
        #expect(names.cached(in: a) == first)
        #expect(listing.reads.withLock { $0 } == ["a"])
    }

    @Test func aReadOvertakenByAnotherFolderIsDropped() async {
        let names = names
        listing.held.withLock { $0 = "a" }
        async let slow = names.names(in: a)
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                self.listing.started.wait()
                done.resume()
            }
        }
        let fast = await names.names(in: b)
        listing.release.signal()
        #expect(await slow == nil)
        #expect(fast?.map(\.name) == ["in-b"])
        #expect(names.cached(in: a)?.map(\.name) == ["in-a"])
    }

    @Test func concurrentRequestsForSameFolderCoalesceToOneRead() async {
        let names = names
        listing.held.withLock { $0 = "a" }
        async let first = names.names(in: a)
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                self.listing.started.wait()
                done.resume()
            }
        }
        async let second = names.names(in: a)
        await Task.yield()
        listing.release.signal()
        let firstResult = await first
        let secondResult = await second
        #expect(firstResult == nil)
        #expect(secondResult?.map(\.name) == ["in-a"])
        #expect(listing.reads.withLock { $0 } == ["a"])
    }

    @Test func securityScopeIsAcquiredOnMainActorAndHeldAcrossBackgroundRead() async {
        let heldWhileReading = Mutex<Bool?>(nil)
        final class ScopeBox: @unchecked Sendable {
            weak var scope: SecurityScope?
        }
        let box = ScopeBox()
        let listing = listing
        listing.held.withLock { $0 = "a" }
        let names = CompletionNames(
            read: { folder in
                let result = listing.read(folder)
                heldWhileReading.withLock { $0 = box.scope != nil }
                return result
            },
            access: { url in
                MainActor.assertIsolated()
                let scope = SecurityScope(url: url)
                box.scope = scope
                return scope
            })
        async let result = names.names(in: a)
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                self.listing.started.wait()
                done.resume()
            }
        }
        listing.release.signal()
        #expect((await result)?.map(\.name) == ["in-a"])
        #expect(heldWhileReading.withLock { $0 } == true)
        #expect(box.scope == nil)
    }

    @Test func unstandardizedURLSharesCacheAndAccessURL() async {
        let accessed = Mutex<[URL]>([])
        let listing = listing
        let names = CompletionNames(
            read: { listing.read($0) },
            access: { url in
                accessed.withLock { $0.append(url) }
                return nil
            })
        let unstandardized = URL(fileURLWithPath: "/x/sub/../a", isDirectory: true)
        let first = await names.names(in: unstandardized)
        let second = await names.names(in: a)
        #expect(first == second)
        #expect(names.cached(in: a) == first)
        #expect(names.cached(in: unstandardized) == first)
        #expect(listing.reads.withLock { $0 } == ["a"])
        #expect(accessed.withLock { $0 } == [a.standardizedFileURL])
    }

    @Test func theFolderReaderOffersFoldersHiddenNamesAndPackagesAsFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletionNamesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["Sub", "Tool.app", ".git"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data([1]).write(to: root.appendingPathComponent("file.txt"))
        let read = CompletionNames.readFolder(root)
        let kinds = Dictionary(uniqueKeysWithValues: read.map { ($0.name, $0.isFolder) })
        #expect(kinds == ["Sub": true, ".git": true, "Tool.app": false, "file.txt": false])
    }

    @Test func theFolderReaderHandlesSymlinksAndBrokenSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompletionNamesTests-symlinks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let realDir = root.appendingPathComponent("RealDir")
        let realFile = root.appendingPathComponent("real.txt")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try Data([1]).write(to: realFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("LinkToDir"), withDestinationURL: realDir)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("LinkToFile"), withDestinationURL: realFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("BrokenLink"),
            withDestinationURL: root.appendingPathComponent("missing-target"))

        let read = CompletionNames.readFolder(root)
        let kinds = Dictionary(uniqueKeysWithValues: read.map { ($0.name, $0.isFolder) })
        #expect(
            kinds == [
                "RealDir": true, "real.txt": false, "LinkToDir": true, "LinkToFile": false,
                "BrokenLink": false,
            ])
    }

    @Test func aFolderThatCantBeReadHasNoNames() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(CompletionNames.readFolder(missing).isEmpty)
    }
}
