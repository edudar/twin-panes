import AppKit
import EditorKit
import Synchronization
import TwinPanesCore
import WorkspaceKit

/// M3a overwrite editing in the running app, typed with real key events through the
/// window and the main menu (docs/plans/M3a.md).
extension SmokeTest {
    /// Sends `text` as key-downs through `NSApp`, so typing reaches the first responder
    /// and ⌘-keys reach the main menu, as they do for the user.
    func type(_ text: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        for character in text {
            let characters = String(character)
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
            else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// Chooses an Edit menu item the way AppKit does for a key window: the first object
    /// in the first responder's chain that implements the action validates and performs
    /// it. (The smoke-test app isn't frontmost, so its window never becomes key and
    /// the menu's own key-equivalent path has no target.) Checks the key equivalent too.
    func menu(_ title: String, in window: NSWindow) -> Bool {
        guard let item = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: title),
            item.keyEquivalent.lowercased() == "z", let action = item.action
        else { return false }
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: action) {
            responder = current.nextResponder
        }
        guard let target = responder,
            (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
        else { return false }
        return target.tryToPerform(action, with: item)
    }

    /// The sample repeats 00…FF, so every byte's value is its offset modulo 256.
    func editing(_ check: (Bool, String) -> Void, hex: HexEditorItem, window: NSWindow) async {
        func bytes(_ range: Range<UInt64>) -> [UInt8] {
            (try? hex.read(range)).map(Array.init) ?? []
        }
        window.makeFirstResponder(hex.hexView)
        hex.hexView.go(to: 0x10)
        type("AB", in: window)
        check(
            bytes(0x10..<0x11) == [0xAB],
            "typing hex digits overwrites a byte: \(bytes(0x10..<0x11))")
        check(hex.hexView.selection.cursor == 0x11, "the cursor moves on after two digits")
        type("\t", in: window)
        type("Hi", in: window)
        check(bytes(0x11..<0x13) == Array("Hi".utf8), "typing in the text column writes characters")
        check(hex.isDirty, "edits make the tab dirty")
        let status = app.controller(containing: hex.id).map { self.status(of: $0) } ?? ""
        check(status.contains("Modified"), "the status line says Modified: \(status)")
        check(hex.modifiedRanges(in: 0..<0x100) == [0x10..<0x13], "the changed bytes are marked")
        hex.hexView.display()

        let match = try? Searcher(source: hex.snapshot).next(
            SearchPattern.hex("AB"), from: 0, direction: .forward)
        check(match?.range == 0x10..<0x11, "search sees the edit")

        check(menu("Undo", in: window), "Edit › Undo (⌘Z) reaches the editor")
        check(bytes(0x11..<0x13) == [0x11, 0x12], "Undo reverts the text-column typing")
        check(menu("Undo", in: window), "Undo again")
        check(bytes(0x10..<0x11) == [0x10] && !hex.isDirty, "Undo again reverts the hex typing")
        check(menu("Redo", in: window), "Edit › Redo (⇧⌘Z) reaches the editor")
        check(bytes(0x10..<0x11) == [0xAB], "Redo brings the hex typing back")

        check(!hex.canSave, "the editor can't save yet")
        check(
            app.closeCoordinator.dirtySessions(closing: [hex]).count == 1,
            "closing the edited tab asks first")
        hex.discardChanges()
        check(!hex.isDirty && bytes(0x10..<0x11) == [0x10], "Discard drops the edits")
        type("\t", in: window)  // back to the hex column
    }

    /// Edits near the end of a 4 GiB file, and while a Find All scans all of it.
    func editingLargeFile(_ check: (Bool, String) -> Void, item: HexEditorItem) async {
        guard let window = item.viewController.view.window else {
            return check(false, "the 4 GiB tab has a window")
        }
        window.makeFirstResponder(item.hexView)
        let last = item.length - 1
        item.hexView.go(to: last)
        item.hexView.display()
        for _ in 0..<50 where item.cachedBytes(last..<item.length) == nil {
            await settle(milliseconds: 20)
        }
        type("7F", in: window)
        check((try? item.read(last..<item.length)) == Data([0x7F]), "edit at the end of 4 GiB")

        let searcher = Searcher(source: item.snapshot)
        let progress = SearchProgress()
        let search = Task {
            defer { progress.finish() }
            return try await Searcher.run { token in
                try searcher.all(try SearchPattern.hex("7F"), cancellation: token)
            }
        }
        await settle(milliseconds: 50)
        item.hexView.go(to: 1 << 30)
        item.hexView.display()
        for _ in 0..<50 where item.cachedBytes((1 << 30)..<((1 << 30) + 1)) == nil {
            await settle(milliseconds: 20)
        }
        let clock = ContinuousClock()
        let typing = clock.measure { type("7F", in: window) }
        let overlapped = !progress.isFinished
        let result = try? await search.value
        print(
            "  info typing during a 4 GiB Find All took \(typing)"
                + (overlapped ? "" : " (the search had already finished)"))
        check(typing < .milliseconds(100), "an edit doesn't wait for a running search (\(typing))")
        check(
            result?.ranges == [last..<item.length],
            "the search reports the file as it was when it started")
        item.discardChanges()
    }
}

/// Whether a background search has returned, shared with its task.
private final class SearchProgress: Sendable {
    private let finished = Mutex(false)
    func finish() { finished.withLock { $0 = true } }
    var isFinished: Bool { finished.withLock { $0 } }
}
