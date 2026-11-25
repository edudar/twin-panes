import AppKit
import BrowserKit
import EditorKit
import WorkspaceKit

extension SmokeTest {
    /// Opens the path field with ⇧⌘G and types `text` with real key presses.
    func typeInPathField(_ text: String, browser: BrowserItem, window: NSWindow) {
        window.makeFirstResponder(browser.preferredFirstResponder)
        _ = dispatch(KeyChord("g", [.command, .shift]), in: window)
        press(text, in: window)
    }

    /// Presses Tab in the path field and returns its text once completion changed it, or
    /// nil if it didn't within 5 s.
    func pressTabInPathField(browser: BrowserItem, window: NSWindow) async -> String? {
        guard
            let field = Self.view(in: browser.viewController.view, id: "browserPath")
                as? NSTextField, let typed = field.currentEditor()?.string
        else { return nil }
        press("\t", in: window)
        for _ in 0..<200 {
            if let text = field.currentEditor()?.string, text != typed { return text }
            await settle(milliseconds: 25)
        }
        return nil
    }

    /// The second Tab opens the list of matches (D49): Down highlights the first, which
    /// puts its whole path in the field, and Return takes it without leaving the field.
    func pickFromCompletionList(
        _ check: (Bool, String) -> Void, browser: BrowserItem, window: NSWindow,
        expecting picked: String
    ) async {
        let field = Self.view(in: browser.viewController.view, id: "browserPath") as? NSTextField
        let folder = browser.folder
        press("\t", in: window)
        await settle(milliseconds: 100)
        pressDownArrow(in: window)
        await settle(milliseconds: 100)
        check(
            field?.currentEditor()?.string == picked,
            "second Tab lists the matches and Down picks the first: "
                + (field?.currentEditor()?.string ?? "field closed"))
        press("\r", in: window)
        await settle(milliseconds: 100)
        check(
            field?.currentEditor()?.string == picked && browser.folder == folder,
            "Return takes the pick and stays in the path field")
        let caret = NSRange(location: (picked as NSString).length, length: 0)
        let selected = (field?.currentEditor() as? NSTextView)?.selectedRange()
        check(
            selected == caret,
            "and leaves the caret after it: \(selected.map(NSStringFromRange) ?? "field closed")")
        press("\u{1b}", in: window)
        await settle(milliseconds: 50)
    }

    /// A file's path in the path field (§4.7): ⌘↩ opens it in a hex editor tab and Return
    /// in its default app (recorded here, so the smoke test launches no other app), each
    /// from the file's folder.
    func openFromPathField(
        _ check: (Bool, String) -> Void, in controller: MainWindowController,
        browser: BrowserItem, window: NSWindow, folder: URL
    ) async {
        let file = folder.standardizedFileURL.appendingPathComponent("data.bin")
        browser.go(to: folder.appendingPathComponent("sub"))
        await browser.listed()
        typeInPathField(file.path, browser: browser, window: window)
        check(dispatch(KeyChord("\r", .command), in: window), "⌘↩ dispatched in path field")
        await browser.listed()
        let editors = app.workspace.allItems.compactMap { $0 as? HexEditorItem }
        check(
            editors.contains { $0.url.lastPathComponent == "data.bin" }
                && browser.folder.path == folder.standardizedFileURL.path,
            "⌘↩ opens a typed file in a hex editor tab, from its folder")
        for editor in editors {
            editor.willClose()
            controller.layout.remove(editor.id)
        }
        controller.layout.select(browser.id)

        var inDefaultApp: [URL] = []
        let launch = browser.openInDefaultApp
        browser.openInDefaultApp = { inDefaultApp.append($0) }
        defer { browser.openInDefaultApp = launch }
        typeInPathField(file.path, browser: browser, window: window)
        press("\r", in: window)
        await browser.listed()
        check(
            inDefaultApp.map(\.path) == [file.path]
                && window.firstResponder === browser.preferredFirstResponder,
            "Return opens a typed file in its default app and leaves the field")
    }

    func pressDownArrow(in window: NSWindow) {
        let key = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: 125)
        else { return }
        window.sendEvent(event)
    }

    /// Sends `text` as key presses to `window` itself, as AppKit hands a key window its
    /// keys: through `MainWindow`'s command dispatcher, then to the first responder.
    /// `NSApp.sendEvent` would hand them to whichever window AppKit thinks is key, which
    /// in the smoke test's inactive app isn't always this one.
    func press(_ text: String, in window: NSWindow) {
        for character in text {
            let key = String(character)
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)
            else { continue }
            window.sendEvent(event)
        }
    }

    /// Step 23 of docs/plans/M5.md (D-e): Tab in the path field completes a folder with
    /// its slash, and Return goes there, with real key events.
    func pathCompletion(
        _ check: (Bool, String) -> Void, browser: BrowserItem, window: NSWindow, folder: URL
    ) async {
        let path = folder.standardizedFileURL.path
        let fm = FileManager.default
        let extraFolders = ["folder-one", "folder-two"].map { folder.appendingPathComponent($0) }
        for url in extraFolders {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { for url in extraFolders { try? fm.removeItem(at: url) } }

        typeInPathField(path + "/su", browser: browser, window: window)
        let completed = await pressTabInPathField(browser: browser, window: window)
        check(
            completed == path + "/sub/",
            "Tab completes a folder in the path field: \(completed ?? "nothing")")
        press("\r", in: window)
        await browser.listed()
        check(
            browser.folder.lastPathComponent == "sub"
                && window.firstResponder === browser.preferredFirstResponder,
            "and Return goes there")

        typeInPathField(path + "/fo", browser: browser, window: window)
        let prefix = await pressTabInPathField(browser: browser, window: window)
        check(
            prefix == path + "/folder-",
            "Tab completes ambiguous prefix to shared part: \(prefix ?? "nothing")")
        await pickFromCompletionList(
            check, browser: browser, window: window, expecting: path + "/folder-one/")

        // Typing while the list shows narrows it: with only folder-two left, Down picks it.
        typeInPathField(path + "/fo", browser: browser, window: window)
        _ = await pressTabInPathField(browser: browser, window: window)
        press("\t", in: window)
        await settle(milliseconds: 100)
        press("t", in: window)
        await settle(milliseconds: 100)
        pressDownArrow(in: window)
        await settle(milliseconds: 100)
        let narrowed = Self.view(in: browser.viewController.view, id: "browserPath")
            .flatMap { ($0 as? NSTextField)?.currentEditor()?.string }
        check(
            narrowed == path + "/folder-two/",
            "typing while the list shows narrows it: \(narrowed ?? "field closed")")
        press("\u{1b}\u{1b}", in: window)
        await settle(milliseconds: 50)

        typeInPathField("~", browser: browser, window: window)
        let tilde = await pressTabInPathField(browser: browser, window: window)
        check(
            tilde?.hasPrefix("~/") == true,
            "Tab expands ~ in the path field: \(tilde ?? "nothing")")
        press("\u{1b}", in: window)

        browser.go(to: folder)
        await browser.listed()
    }
}
