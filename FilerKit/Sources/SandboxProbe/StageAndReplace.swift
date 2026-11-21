import Darwin
import Foundation

extension SandboxProbe {
    /// Strategy A of PLAN.md §4.3: clone (or copy) to a staging file, patch it, flush,
    /// coordinated `replaceItemAt`. Reports what survived.
    func stageAndReplace(_ url: URL) throws -> String {
        let fm = FileManager.default
        let before = try Self.stat(url)
        let beforeData = try Data(contentsOf: url)
        let beforeCreation = try url.resourceValues(forKeys: [.creationDateKey]).creationDate

        // Staging candidates, best first.
        var staging: URL?
        var stagingNote = ""
        var attempts: [String] = []
        let candidates: [(String, () throws -> URL)] = [
            ("itemReplacementDirectory", { try Self.replacementDirectory(for: url) }),
            ("sibling", { url.deletingLastPathComponent() }),
        ]
        for (label, makeDirectory) in candidates {
            do {
                let dir = try makeDirectory()
                let target = dir.appendingPathComponent(".filer-staging-\(Self.shortID())")
                if Darwin.clonefile(url.path, target.path, 0) == 0 {
                    stagingNote = "clone in \(label)"
                } else {
                    let cloneError = String(cString: strerror(errno))
                    try fm.copyItem(at: url, to: target)
                    stagingNote = "copy in \(label) (clone: \(cloneError))"
                }
                staging = target
                break
            } catch {
                attempts.append("\(label): \(Self.describe(error))")
            }
        }
        guard let staging else {
            throw ProbeError("no staging location — " + attempts.joined(separator: "; "))
        }

        // Patch the staging file with the same bytes, as a save of unchanged content.
        let handle = try FileHandle(forUpdating: staging)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: beforeData.prefix(1))
        try handle.close()
        _ = try? Self.fullFsync(staging)

        var coordinationError: NSError?
        var replaceError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { target in
            do {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } catch {
                replaceError = error
            }
        }
        if let error = replaceError ?? coordinationError {
            try? fm.removeItem(at: staging)
            throw ProbeError("\(stagingNote); replace failed: \(Self.describe(error))")
        }

        let after = try Self.stat(url)
        let afterData = try Data(contentsOf: url)
        let values = try url.resourceValues(forKeys: [.creationDateKey, .tagNamesKey])
        var notes = [stagingNote]
        notes.append(after.st_ino == before.st_ino ? "same inode" : "new inode")
        notes.append(afterData == beforeData ? "content ok" : "CONTENT CHANGED")
        notes.append("mode \(after.st_mode == before.st_mode ? "kept" : "changed")")
        notes.append("xattr \(Self.hasXattr(url) ? "kept" : "lost")")
        notes.append("tag \(values.tagNames?.contains(Self.tagName) == true ? "kept" : "lost")")
        notes.append(
            "creation date \(values.creationDate == beforeCreation ? "kept" : "changed")")
        return notes.joined(separator: ", ")
    }
}
