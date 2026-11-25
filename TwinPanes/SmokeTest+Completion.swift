import AppKit
import BrowserKit
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
        browser.go(to: folder)
        await browser.listed()
    }
}
