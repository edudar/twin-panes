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

        let report = probe.probeFolder(granted)

        for name in [
            "create scratch folder", "create file", "fullfsync", "in-place write",
            "xattr set+get", "hard link", "clone → sibling", "clone → container",
            "clone-stage-replace", "trash",
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

    @Test func fileProbeNotesACoveringFolderGrant() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("covered.bin")
        try Data("x".utf8).write(to: file)
        #expect(probe.probeFile(file).outcome(of: "covering folder grant")?.isFailure == false)
        let covered = probe.probeFile(file, coveringFolder: root)
        #expect(
            covered.outcome(of: "covering folder grant")
                == .skipped("\(root.path): rows include folder access"))
    }

    @Test func fileProbeKeepsContent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("disposable.bin")
        let content = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        try content.write(to: file)

        let report = probe.probeFile(file)

        #expect(report.grant == .file)
        #expect(report.outcome(of: "read")?.isFailure == false)
        #expect(report.outcome(of: "dataless (evicted)") == .ok("no: content is local"))
        #expect(report.outcome(of: "clone-stage-replace")?.isFailure == false)
        #expect(try Data(contentsOf: file) == content)
        #expect(
            report.outcome(of: "trash")
                == .skipped("file mode keeps the test file; run folder mode"))
    }

    @Test func savedBookmarkResolves() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bookmarked.txt")
        try Data("x".utf8).write(to: file)
        let report = probe.probeFile(file)
        let data = try #require(report.bookmark)
        let result = SandboxProbe.resolveSavedBookmark(data)
        #expect(!result.outcome.isFailure, "\(result.outcome.detail)")
    }
}
