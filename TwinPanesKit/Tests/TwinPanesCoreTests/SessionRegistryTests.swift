import Foundation
import Testing

@testable import TwinPanesCore

@MainActor
@Suite struct SessionRegistryTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SessionRegistryTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func file(_ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func open(_ registry: SessionRegistry, _ url: URL) throws -> (EditorSession, Bool) {
        let opened = try registry.open(url, addDirectory: folder.appendingPathComponent("add"))
        return (opened.session, opened.isNew)
    }

    @Test func oneSessionPerFile() throws {
        defer { cleanUp() }
        let registry = SessionRegistry()
        let a = try file("a.bin"), b = try file("b.bin")
        #expect(registry.session(for: a) == nil)
        let (first, firstIsNew) = try open(registry, a)
        let (again, againIsNew) = try open(registry, a)
        #expect(firstIsNew && !againIsNew && first === again)
        #expect(registry.session(for: a) === first)
        let (other, otherIsNew) = try open(registry, b)
        #expect(otherIsNew && other !== first)
        #expect(registry.sessions.count == 2)
    }

    /// Another path to the same file: a hard link, or a spelling with "..".
    @Test func otherPathsToTheSameFileShareTheSession() throws {
        defer { cleanUp() }
        let registry = SessionRegistry()
        let a = try file("a.bin")
        let (session, _) = try open(registry, a)
        let link = folder.appendingPathComponent("link.bin")
        try FileManager.default.linkItem(at: a, to: link)
        #expect(registry.session(for: link) === session)
        let roundabout = folder.appendingPathComponent("sub/../a.bin")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        #expect(try open(registry, roundabout).0 === session)
    }

    /// The registry doesn't keep sessions alive: when the last tab lets go, opening the
    /// file again starts fresh (and an unedited version, not the old edits).
    @Test func sessionsLeaveWithTheirLastHolder() throws {
        defer { cleanUp() }
        let registry = SessionRegistry()
        let a = try file("a.bin")
        weak var gone: EditorSession?
        do {
            let (session, _) = try open(registry, a)
            try session.overwrite(Data([9]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
            gone = session
        }
        #expect(gone == nil)
        #expect(registry.session(for: a) == nil && registry.sessions.isEmpty)
        let (fresh, isNew) = try open(registry, a)
        #expect(isNew && !fresh.isDirty)
    }

    @Test func filesThatCantOpenAreNotRegistered() throws {
        defer { cleanUp() }
        let registry = SessionRegistry()
        #expect(throws: ByteSourceError.self) {
            try registry.open(folder.appendingPathComponent("missing.bin"))
        }
        #expect(throws: ByteSourceError.self) { try registry.open(folder) }
        #expect(registry.sessions.isEmpty)
        #expect(registry.session(for: folder.appendingPathComponent("missing.bin")) == nil)
    }
}
