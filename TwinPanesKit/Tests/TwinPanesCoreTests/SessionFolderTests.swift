import Foundation
import Testing

@testable import TwinPanesCore

struct SessionFolderTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionFolderTests-\(UUID().uuidString)")

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func manifest() throws -> SessionManifest {
        let file = root.deletingLastPathComponent().appendingPathComponent("\(UUID()).bin")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return SessionManifest(
            path: file.path, bookmark: Data([9]), identity: try FileIdentity(url: file))
    }

    @Test func keepsItsManifestUntilClosed() throws {
        defer { cleanUp() }
        let stored = try manifest()
        let id = UUID()
        let folder = try SessionFolder.create(in: root, id: id, manifest: stored)
        #expect(folder == SessionFolder(url: root.appendingPathComponent(id.uuidString)))
        #expect(try folder.manifest() == stored && !folder.isClosed)
        #expect(throws: (any Error).self) {
            try SessionFolder.create(in: root, id: id, manifest: stored)
        }
        try folder.markClosed()
        #expect(folder.isClosed)
        folder.delete()
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    /// At launch: closed folders and ones that never got a manifest (a crash while making
    /// it) go; unclosed ones with a manifest are crashed sessions to recover.
    @Test func sweepKeepsOnlyCrashedSessions() throws {
        defer { cleanUp() }
        #expect(SessionFolder.sweep(root).isEmpty)  // no root yet
        let crashed = try SessionFolder.create(in: root, id: UUID(), manifest: try manifest())
        let closed = try SessionFolder.create(in: root, id: UUID(), manifest: try manifest())
        try closed.markClosed()
        let unfinished = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: root.appendingPathComponent(".DS_Store"))

        #expect(SessionFolder.sweep(root) == [crashed])
        #expect(!FileManager.default.fileExists(atPath: closed.url.path))
        #expect(!FileManager.default.fileExists(atPath: unfinished.path))
        #expect(try crashed.manifest().bookmark == Data([9]))
    }
}
