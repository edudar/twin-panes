import AppKit
import Foundation
import Synchronization
import Testing
import WorkspaceKit

@testable import EditorKit
@testable import HexViewKit
@testable import TwinPanesCore

@MainActor
private final class DatalessStatusSpy: WorkspaceHost {
    var messages: [String] = []
    func showStatus(_ message: String) { messages.append(message) }
}

private final class FakeHexCloudDownloads: CloudDownloads {
    private let state = Mutex((dataless: true, started: 0))
    var started: Int { state.withLock { $0.started } }
    func finish() { state.withLock { $0.dataless = false } }
    func isDataless(_ url: URL) -> Bool { state.withLock { $0.dataless } }
    func startDownload(_ url: URL) throws { state.withLock { $0.started += 1 } }
}

@MainActor
@Suite(.serialized) struct HexEditorDatalessTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HexEditorDatalessTests-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    var url: URL { root.appendingPathComponent("file.bin") }
    var sessions: URL { root.appendingPathComponent("Sessions", isDirectory: true) }

    init() throws {
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data(repeating: 0x12, count: 16).write(to: url)
    }

    @Test func firstEditOfDatalessFileDownloadsRefusesEditAndEditsOnceHere() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = FakeHexCloudDownloads()
        let session = try EditorSession(url: url, sessionsRoot: sessions)
        session.cloudDownloads = cloud
        let item = HexEditorItem(session: session)
        let host = DatalessStatusSpy()
        item.host = host
        _ = item.controller.view
        _ = try item.read(0..<16)

        item.hexView.insertText("A")
        #expect(cloud.started == 1 && !item.isDirty && !item.canUndo && item.session.folder == nil)
        #expect(host.messages.last?.contains("downloading from iCloud") == true)
        #expect(!item.controller.applyingTypingEdit && item.lastTyping == nil)
        #expect(item.hexView.pendingNibble == nil && item.hexView.selection.cursor == 0)
        #expect(try item.read(0..<1) == Data([0x12]))

        cloud.finish()
        item.hexView.insertText("AB")
        #expect(try item.read(0..<1) == Data([0xAB]))
        #expect(item.isDirty && item.canUndo && item.session.folder != nil)
        #expect(item.hexView.pendingNibble == nil && item.hexView.selection.cursor == 1)
    }
}
