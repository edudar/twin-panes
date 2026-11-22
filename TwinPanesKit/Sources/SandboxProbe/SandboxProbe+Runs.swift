import Darwin
import Foundation

// The two probe runs (file grant, folder grant), the relaunch check, and the
// clone-stage-replace save they both exercise.
extension SandboxProbe {
    // MARK: File grant

    /// `coveringFolder` is a folder grant the app already holds over `url`, if any. With
    /// one, the sibling and replace rows show folder access, not the file grant alone.
    public func probeFile(_ url: URL, coveringFolder: URL? = nil) -> ProbeReport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var steps = Steps()
        steps.record("security scope", scoped ? .ok("started") : .skipped("not a scoped URL"))
        steps.record(
            "covering folder grant",
            coveringFolder.map { .skipped("\($0.path): rows include folder access") }
                ?? .ok("none: rows show the file grant alone"))

        // Before the read, which downloads an evicted iCloud file.
        steps.run("dataless (evicted)") {
            (try Self.stat(url).st_flags & UInt32(SF_DATALESS)) != 0
                ? "yes: content is in the cloud" : "no: content is local"
        }
        steps.run("read") { try Self.readHead(url) }
        let bookmark = steps.bookmark(for: url)
        steps.run("fullfsync") { try Self.fullFsync(url) }
        steps.run("in-place write") { try Self.rewriteFirstByte(url) }
        steps.run("xattr set+get") { try Self.setAndCheckXattr(url) }
        steps.run("finder tag") { try Self.addTag(url) }

        let sibling = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).probe-\(Self.shortID())")
        steps.run("clone → sibling") { try Self.clone(url, to: sibling, cleanUp: true) }
        steps.run("clone → container") {
            try Self.clone(url, to: containerFile(named: "clone"), cleanUp: true)
        }
        steps.run("clone → itemReplacementDirectory") {
            let dir = try Self.replacementDirectory(for: url)
            defer { try? FileManager.default.removeItem(at: dir) }
            return try Self.clone(url, to: dir.appendingPathComponent("clone"), cleanUp: true)
        }
        steps.run("copy → itemReplacementDirectory") {
            let dir = try Self.replacementDirectory(for: url)
            defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("copy"))
            return "copied"
        }
        steps.run("clone-stage-replace") { try stageAndReplace(url) }
        steps.record("trash", .skipped("file mode keeps the test file; run folder mode"))

        return report(url, .file, steps, bookmark)
    }

    // MARK: Folder grant

    public func probeFolder(_ url: URL) -> ProbeReport {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var steps = Steps()
        steps.record("security scope", scoped ? .ok("started") : .skipped("not a scoped URL"))
        let bookmark = steps.bookmark(for: url)

        let scratch = url.appendingPathComponent(
            "TwinPanesProbe-\(Self.shortID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard
            steps.run(
                "create scratch folder",
                { () -> String in
                    try FileManager.default.createDirectory(
                        at: scratch, withIntermediateDirectories: false)
                    return scratch.lastPathComponent
                })
        else {
            return report(url, .folder, steps, bookmark)
        }

        let file = scratch.appendingPathComponent("sample.bin")
        steps.run("create file") {
            try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) }).write(to: file)
            return "64 KiB"
        }
        steps.run("fullfsync") { try Self.fullFsync(file) }
        steps.run("in-place write") { try Self.rewriteFirstByte(file) }
        steps.run("xattr set+get") { try Self.setAndCheckXattr(file) }
        steps.run("finder tag") { try Self.addTag(file) }
        steps.run("clone → sibling") {
            try Self.clone(file, to: scratch.appendingPathComponent("clone.bin"), cleanUp: false)
        }
        steps.run("clone → container") {
            try Self.clone(file, to: containerFile(named: "clone"), cleanUp: true)
        }
        steps.run("clone → itemReplacementDirectory") {
            let dir = try Self.replacementDirectory(for: file)
            defer { try? FileManager.default.removeItem(at: dir) }
            return try Self.clone(file, to: dir.appendingPathComponent("clone"), cleanUp: true)
        }
        // Replace a file with one link first, then a hard-linked one, so a failure
        // on the second can't be mistaken for a folder-grant limit.
        steps.run("clone-stage-replace") { try stageAndReplace(file) }
        let link = scratch.appendingPathComponent("hardlink.bin")
        steps.run("hard link") {
            try FileManager.default.linkItem(at: file, to: link)
            return "nlink \(try Self.stat(file).st_nlink)"
        }
        steps.run("clone-stage-replace (hard-linked)") { try stageAndReplace(file) }
        steps.run("hard link after replace") {
            let fileInode = try Self.stat(file).st_ino
            let linkInode = try Self.stat(link).st_ino
            return fileInode == linkInode
                ? "link still shares the file" : "link now points at the old inode (broken)"
        }
        steps.run("trash") {
            let victim = scratch.appendingPathComponent("trash-me.txt")
            try Data("probe".utf8).write(to: victim)
            var resulting: NSURL?
            try FileManager.default.trashItem(at: victim, resultingItemURL: &resulting)
            if let resulting { try? FileManager.default.removeItem(at: resulting as URL) }
            return "moved to \(resulting?.deletingLastPathComponent?.path ?? "?")"
        }
        return report(url, .folder, steps, bookmark)
    }

    // MARK: Bookmarks after relaunch

    /// Resolves a bookmark saved by an earlier run (the relaunch check).
    public static func resolveSavedBookmark(_ data: Data) -> ProbeResult {
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let readable = FileManager.default.isReadableFile(atPath: url.path)
            return ProbeResult(
                name: "resolve \(url.lastPathComponent)",
                outcome: started && readable
                    ? .ok("access ok\(stale ? ", stale (recreate)" : "") — \(url.path)")
                    : .failed("started \(started), readable \(readable) — \(url.path)"))
        } catch {
            return ProbeResult(name: "resolve bookmark", outcome: .failed(Self.describe(error)))
        }
    }

    // MARK: Report

    func report(
        _ url: URL, _ grant: GrantKind, _ steps: Steps, _ bookmark: Data?
    )
        -> ProbeReport
    {
        ProbeReport(
            date: Date(), path: url.path, grant: grant, volume: VolumeInfo(for: url),
            isSandboxed: Self.isSandboxed, results: steps.results, bookmark: bookmark)
    }
}
