import Foundation
import Testing

@testable import SandboxProbe

/// Runs the probes unsandboxed on a temporary folder (APFS on the boot volume), so the
/// probe code itself is known to work before anyone runs it on real volumes.
@Suite struct SandboxProbeTests {
    let root: URL
    let probe: SandboxProbe

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwinPanesProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        probe = SandboxProbe(containerDirectory: container)
    }

    @Test func folderProbeSucceedsOnLocalAPFS() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let granted = root.appendingPathComponent("granted", isDirectory: true)
        try FileManager.default.createDirectory(at: granted, withIntermediateDirectories: true)

        // Not to the Trash: this process can't empty ~/.Trash afterwards, so each run left
        // a trash-me.txt there (review, test hygiene). The Debug menu still trashes.
        let report = probe.probeFolder(granted, trash: false)
        #expect(report.outcome(of: "trash") == .skipped("left out of this run"))

        for name in [
            "create scratch folder", "create file", "fullfsync", "in-place write",
            "xattr set+get", "hard link", "clone → sibling", "clone → container",
            "clone-stage-replace",
        ] {
            let outcome = try #require(report.outcome(of: name), "missing step \(name)")
            #expect(!outcome.isFailure, "\(name): \(outcome.detail)")
        }
        let replace = try #require(report.outcome(of: "clone-stage-replace"))
        #expect(replace.detail.contains("new inode"))
        #expect(replace.detail.contains("content ok"))
        // The scratch folder is removed afterwards.
        #expect(try FileManager.default.contentsOfDirectory(atPath: granted.path).isEmpty)
        #expect(report.markdown.contains("| clone-stage-replace | ✅ |"))
        let names = report.results.map(\.name)
        #expect(
            try #require(names.firstIndex(of: "clone-stage-replace"))
                < #require(names.firstIndex(of: "hard link")))
        #expect(names.contains("clone-stage-replace (hard-linked)"))
    }

    @Test func fileProbeKeepsContent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("disposable.bin")
        let content = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try content.write(to: file)

        let report = probe.probeFile(file)

        #expect(report.grant == .file)
        #expect(report.outcome(of: "covering folder grant")?.isFailure == false)
        #expect(report.outcome(of: "read")?.isFailure == false)
        #expect(report.outcome(of: "dataless (evicted)") == .ok("no: content is local"))
        #expect(report.outcome(of: "clone-stage-replace")?.isFailure == false)
        #expect(try Data(contentsOf: file) == content)
        #expect(
            report.outcome(of: "trash")
                == .skipped("file mode keeps the test file; run folder mode"))
    }

    @Test func savedBookmarkResolvesAndNotesCoveringGrant() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bookmarked.txt")
        try Data("x".utf8).write(to: file)
        let report = probe.probeFile(file, coveringFolder: root)
        #expect(
            report.outcome(of: "covering folder grant")
                == .skipped("\(root.path): rows include folder access"))
        let data = try #require(report.bookmark)
        let result = SandboxProbe.resolveSavedBookmark(data)
        #expect(!result.outcome.isFailure, "\(result.outcome.detail)")
    }
}
