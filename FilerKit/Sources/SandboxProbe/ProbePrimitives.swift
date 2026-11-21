import Darwin
import Foundation

// Low-level steps the probe runs: each returns a short note or throws a ProbeError.
extension SandboxProbe {
    static func readHead(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ProbeError.errno("open") }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count >= 0 else { throw ProbeError.errno("pread") }
        return "\(count) bytes"
    }

    static func fullFsync(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw ProbeError.errno("open for write") }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == 0 { return "F_FULLFSYNC ok" }
        let fullError = String(cString: strerror(errno))
        if fcntl(fd, F_BARRIERFSYNC) == 0 { return "F_FULLFSYNC failed (\(fullError)); barrier ok" }
        throw ProbeError(
            "F_FULLFSYNC: \(fullError); F_BARRIERFSYNC: \(String(cString: strerror(errno)))")
    }

    /// Writes the first byte back unchanged: an in-place write that keeps the content.
    static func rewriteFirstByte(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw ProbeError.errno("open for write") }
        defer { close(fd) }
        var byte: UInt8 = 0
        guard pread(fd, &byte, 1, 0) == 1 else { return "empty file, nothing to rewrite" }
        guard pwrite(fd, &byte, 1, 0) == 1 else { throw ProbeError.errno("pwrite") }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw ProbeError.errno("F_FULLFSYNC") }
        return "1 byte rewritten + F_FULLFSYNC"
    }

    static func setAndCheckXattr(_ url: URL) throws -> String {
        let value = Array("probe".utf8)
        guard setxattr(url.path, xattrName, value, value.count, 0, 0) == 0 else {
            throw ProbeError.errno("setxattr")
        }
        return hasXattr(url) ? "set and read back" : "set but not readable"
    }

    static func hasXattr(_ url: URL) -> Bool {
        getxattr(url.path, xattrName, nil, 0, 0, 0) >= 0
    }

    static func addTag(_ url: URL) throws -> String {
        let existing = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        // URLResourceValues.tagNames is only settable from macOS 26; NSURL works on 15.
        try (url as NSURL).setResourceValue(
            Array(Set(existing + [tagName])), forKey: .tagNamesKey)
        return "tag \(tagName) set"
    }

    static func clone(_ source: URL, to destination: URL, cleanUp: Bool) throws -> String {
        guard Darwin.clonefile(source.path, destination.path, 0) == 0 else {
            throw ProbeError.errno("clonefile → \(destination.deletingLastPathComponent().path)")
        }
        if cleanUp { try? FileManager.default.removeItem(at: destination) }
        return "cloned into \(destination.deletingLastPathComponent().path)"
    }

    static func replacementDirectory(for url: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url,
            create: true)
    }

    static func stat(_ url: URL) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { throw ProbeError.errno("stat") }
        return info
    }

    static func shortID() -> String { String(UUID().uuidString.prefix(8)) }

    static func describe(_ error: Error) -> String {
        if let probe = error as? ProbeError { return probe.message }
        let ns = error as NSError
        var text = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (underlying \(underlying.domain) \(underlying.code))"
        }
        return text
    }
}

/// Collects step results.
struct Steps {
    var results: [ProbeResult] = []

    mutating func record(_ name: String, _ outcome: ProbeOutcome) {
        results.append(ProbeResult(name: name, outcome: outcome))
    }

    @discardableResult
    mutating func run(_ name: String, _ body: () throws -> String) -> Bool {
        do {
            record(name, .ok(try body()))
            return true
        } catch {
            record(name, .failed(SandboxProbe.describe(error)))
            return false
        }
    }

    mutating func bookmark(for url: URL) -> Data? {
        var data: Data?
        run("app-scoped bookmark") {
            let created = try url.bookmarkData(
                options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                relativeTo: nil)
            var stale = false
            let resolved = try URL(
                resolvingBookmarkData: created, options: [.withSecurityScope], relativeTo: nil,
                bookmarkDataIsStale: &stale)
            data = created
            return "created \(created.count) B, resolves to \(resolved.lastPathComponent)"
                + (stale ? " (stale)" : "")
        }
        return data
    }
}

struct ProbeError: Error {
    let message: String
    init(_ message: String) { self.message = message }

    static func errno(_ call: String) -> ProbeError {
        ProbeError("\(call): \(String(cString: strerror(Darwin.errno))) (errno \(Darwin.errno))")
    }
}
