import AppKit
import EditorKit
import TwinPanesCore
import WorkspaceKit

/// The crash relaunch's two launches (docs/plans/M5.md, D-f, 2).
extension SmokeChild {
    static let editedOffset: UInt64 = 0x10

    /// Types a byte into an editor with real key events and saves the window's state.
    /// Each journal record is written at once, so it survives the SIGKILL that follows.
    func editAndWait(app: AppDelegate) async throws {
        let controller = app.openMainWindow()
        guard let window = controller.window,
            let editor = app.openFile(folder.appendingPathComponent("data.bin"), in: controller)
        else { throw SmokeChildError.missing("an editor on data.bin") }
        window.makeFirstResponder(editor.hexView)
        editor.hexView.go(to: Self.editedOffset)
        for character in "7e" {
            let text = String(character)
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)
            else { throw SmokeChildError.missing("a key event for \(text)") }
            NSApp.sendEvent(event)
        }
        guard editor.isDirty else { throw SmokeChildError.missing("the typed edit") }
        try controller.frameController.windowState.encoded().write(to: stateFile)
    }

    /// Restarts as the app does after a crash: recovery holds the crashed sessions, the
    /// window is restored, and its editor tab claims its file's session.
    func recover(app: AppDelegate) async throws -> RecoveredEdits {
        let found = app.crashedSessions(in: sessionsRoot)
        let recovery = LaunchRecovery(found, registry: app.sessions)
        let state = try WindowState(decoding: Data(contentsOf: stateFile))
        app.openMainWindow(restoring: state)
        let unclaimed = recovery.takeUnclaimed { app.editorItem(showing: $0) != nil }
        app.showRecovered(unclaimed)
        let editors = app.workspace.allItems.compactMap { $0 as? HexEditorItem }
        let offset = Self.editedOffset
        return RecoveredEdits(
            recoveredSessions: found.count, unclaimedSessions: unclaimed.count,
            editorTabs: editors.count, isDirty: editors.first?.isDirty,
            editedByte: try editors.first?.read(offset..<(offset + 1)).first)
    }
}
