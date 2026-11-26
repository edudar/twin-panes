import Foundation
import Synchronization
import Testing

@testable import TwinPanesCore

/// The first edit of a file whose bytes are only in iCloud (docs/plans/M6.md, D-h,
/// step 17).
@MainActor
@Suite struct EditorSessionDatalessTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "EditorSessionDatalessTests-\(UUID().uuidString)", isDirectory: true
        )
        .standardizedFileURL
    var url: URL { root.appendingPathComponent("file.bin") }
    var sessions: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(count: 16).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func session(_ cloud: FakeCloud) throws -> EditorSession {
        let session = try EditorSession(url: url, sessionsRoot: sessions)
        session.cloudDownloads = cloud
        return session
    }

    func edit(_ session: EditorSession) throws {
        try session.overwrite(
            Data([0xFF]), at: 0, selectionBefore: 0..<0, selectionAfter: 1..<2, coalescing: false)
    }

    @Test func aDatalessFileStartsDownloadingAndRefusesTheEdit() throws {
        defer { cleanUp() }
        let cloud = FakeCloud(dataless: true)
        let session = try session(cloud)
        #expect(throws: EditorSessionError.downloadingBeforeEdit) { try edit(session) }
        #expect(cloud.started == 1 && !session.isDirty && session.folder == nil)
        cloud.finish()
        try edit(session)
        #expect(session.isDirty && session.folder != nil && cloud.started == 1)
    }

    @Test func repeatedEditAttemptsWhileDownloadIsInProgressStayBlocked() throws {
        defer { cleanUp() }
        let cloud = FakeCloud(dataless: true)
        let session = try session(cloud)
        #expect(throws: EditorSessionError.downloadingBeforeEdit) { try edit(session) }
        #expect(throws: EditorSessionError.downloadingBeforeEdit) { try edit(session) }
        #expect(cloud.started == 2 && !session.isDirty && session.folder == nil)
        cloud.finish()
        try edit(session)
        #expect(session.isDirty && session.folder != nil)
    }

    @Test func aDownloadThatCantStartIsTheEditsError() throws {
        defer { cleanUp() }
        let cloud = FakeCloud(dataless: true, failsToStart: true)
        let session = try session(cloud)
        #expect(throws: FakeCloud.Unreachable.self) { try edit(session) }
        #expect(!session.isDirty && session.folder == nil)
    }

    @Test func prepareForFirstEditChecksReadinessWithoutCreatingFolder() throws {
        defer { cleanUp() }
        let cloud = FakeCloud(dataless: true)
        let session = try session(cloud)
        #expect(throws: EditorSessionError.downloadingBeforeEdit) {
            try session.prepareForFirstEdit()
        }
        #expect(cloud.started == 1 && session.folder == nil)

        cloud.finish()
        try session.prepareForFirstEdit()
        #expect(!session.isDirty && session.folder == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let readOnly = try EditorSession(url: url, sessionsRoot: sessions)
        #expect(throws: EditorSessionError.readOnly(.noWritePermission)) {
            try readOnly.prepareForFirstEdit()
        }
    }
}

final class FakeCloud: CloudDownloads {
    struct Unreachable: Error {}
    private struct State {
        var dataless: Bool
        var started = 0
    }
    private let state: Mutex<State>
    private let failsToStart: Bool

    init(dataless: Bool, failsToStart: Bool = false) {
        state = Mutex(State(dataless: dataless))
        self.failsToStart = failsToStart
    }

    var started: Int { state.withLock { $0.started } }
    func finish() { state.withLock { $0.dataless = false } }

    func isDataless(_ url: URL) -> Bool { state.withLock { $0.dataless } }

    func startDownload(_ url: URL) throws {
        if failsToStart { throw Unreachable() }
        state.withLock { $0.started += 1 }
    }
}
