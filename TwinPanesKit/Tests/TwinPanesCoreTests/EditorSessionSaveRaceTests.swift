import Foundation
import Testing

@testable import TwinPanesCore

@MainActor
@Suite struct EditorSessionSaveRaceTests {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("EditorSessionSaveRaceTests-\(UUID().uuidString)")
    let url: URL

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("file.bin")
        try Data((0..<64).map { UInt8($0) }).write(to: url)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    func type(_ session: EditorSession, _ byte: UInt8, at offset: UInt64) throws {
        try session.overwrite(
            Data([byte]), at: offset, selectionBefore: offset..<(offset + 1),
            selectionAfter: offset..<(offset + 1))
    }

    @Test func reloadAndRevertAreBlockedWhileSaving() async throws {
        defer { cleanUp() }
        let fs = GatedFileSystem(holding: true)
        let session = try EditorSession(
            url: url, saver: Saver(fileSystem: fs),
            sessionsRoot: folder.appendingPathComponent("Sessions"))
        try type(session, 0xAA, at: 0)
        let saving = Task { try await session.save() }
        await fs.entered.wait()
        #expect(throws: EditorSessionError.saveInProgress) { try session.reloadDiscardingEdits() }
        session.revert()
        #expect(session.isDirty && session.canUndo)
        #expect(try session.snapshot.read(0..<1) == Data([0xAA]))
        fs.release()
        try await saving.value
        #expect(!session.isDirty)
    }

    @Test func queuedSaveBehindSaveAsToReadOnlyTargetFails() async throws {
        defer { cleanUp() }
        let fs = GatedFileSystem(holding: true)
        fs.makeMovedReadOnly.withLock { $0 = true }
        let session = try EditorSession(
            url: url, saver: Saver(fileSystem: fs),
            sessionsRoot: folder.appendingPathComponent("Sessions"))
        try type(session, 0xAA, at: 0)
        let target = folder.appendingPathComponent("readonly.bin")
        let saveAs = Task { try await session.saveAs(to: target) }
        await fs.entered.wait()
        try type(session, 0xBB, at: 1)
        let queuedSave = Task { try await session.save() }
        for _ in 0..<100 where session.savesPending < 2 { await Task.yield() }
        fs.release()
        try await saveAs.value
        await #expect(throws: EditorSessionError.readOnly(.noWritePermission)) {
            try await queuedSave.value
        }
        #expect(session.access == .readOnly(.noWritePermission))
        #expect(try Data(contentsOf: target)[0..<2] == Data([0xAA, 1]))
    }
}
