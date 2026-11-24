import Foundation
import Testing

@testable import TwinPanesCore

/// Recovered sessions wait for restored tabs to claim them (docs/plans/M5.md, D-c).
@MainActor
@Suite struct LaunchRecoveryTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("LaunchRecoveryTests-\(UUID().uuidString)")
    let registry = SessionRegistry()

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// A session on a new file `name` with an unsaved edit, recovered from a copy of its
    /// folder as if the app had crashed.
    func crashed(_ name: String) throws -> (url: URL, session: EditorSession) {
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        let live = try EditorSession(url: url, sessionsRoot: folder.appendingPathComponent("S"))
        try live.overwrite(Data([9]), at: 0, selectionBefore: 0..<1, selectionAfter: 1..<2)
        let copy = folder.appendingPathComponent("crashed-\(name)")
        try FileManager.default.copyItem(at: try #require(live.folder).url, to: copy)
        return (url, try EditorSession(recovering: SessionFolder(url: copy)))
    }

    @Test func aRestoredTabOnTheFileGetsTheRecoveredSession() throws {
        defer { cleanUp() }
        let (url, session) = try crashed("a.bin")
        weak var recovered = session
        let recovery = LaunchRecovery([session], registry: registry)
        let opened = try registry.open(url)
        #expect(recovered != nil && opened.session === recovered && !opened.isNew)
        #expect(opened.session.isDirty)
        _ = recovery
    }

    @Test func sessionsNoTabClaimedAreHandedBackInOrder() throws {
        defer { cleanUp() }
        let a = try crashed("a.bin"), b = try crashed("b.bin"), c = try crashed("c.bin")
        let recovery = LaunchRecovery([a.session, b.session, c.session], registry: registry)
        let unclaimed = recovery.takeUnclaimed { $0 === b.session }
        // Recovered URLs have their symlinks resolved (/private/var), so compare names.
        let names = unclaimed.map(\.url.lastPathComponent)
        #expect(names == [a.url.lastPathComponent, c.url.lastPathComponent])
    }

    @Test func takingTheUnclaimedLetsGoOfEverySession() throws {
        defer { cleanUp() }
        weak var recovered: EditorSession?
        let recovery = try {
            let session = try crashed("a.bin").session
            recovered = session
            return LaunchRecovery([session], registry: registry)
        }()
        #expect(recovered != nil)
        _ = recovery.takeUnclaimed { _ in true }
        #expect(recovered == nil)
    }
}
