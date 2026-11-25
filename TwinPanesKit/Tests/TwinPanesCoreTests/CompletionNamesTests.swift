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

    @Test func aFolderThatCantBeReadHasNoNames() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(CompletionNames.readFolder(missing).isEmpty)
    }
}
