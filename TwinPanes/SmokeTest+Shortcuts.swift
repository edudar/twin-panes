import AppKit
import BrowserKit
import WorkspaceKit

extension SmokeTest {
    /// The browser's file commands answer to ⌃⌘ and their letter, View also to Finder's
    /// ⌘Y, and the menus show those keys (docs/reviews/Shortcuts.md). The file list has
    /// focus.
    func fileCommandShortcuts(_ check: (Bool, String) -> Void, in window: NSWindow) {
        let chain = FocusChain.scopes(in: window)
        let controlCommand: KeyChord.Modifiers = [.control, .command]
        let keys: [(KeyChord, CommandID, String)] = [
            (KeyChord("c", controlCommand), .browserCopyToOtherPanel, "⌃⌘C"),
            (KeyChord("m", controlCommand), .browserMoveToOtherPanel, "⌃⌘M"),
            (KeyChord("v", controlCommand), .browserView, "⌃⌘V"),
            (KeyChord("e", controlCommand), .browserEdit, "⌃⌘E"),
            (KeyChord("r", controlCommand), .browserRename, "⌃⌘R"),
            (KeyChord("y", .command), .browserView, "⌘Y"),
        ]
        for (chord, command, label) in keys {
            check(
                app.registry.candidates(for: chord, chain: chain).first?.id == command,
                "\(label) in a browser runs \(command)")
        }
        let retired = [KeyChord("c", [.shift, .command]), KeyChord("m", [.shift, .command])]
        check(
            (retired + [KeyChord("r", .command)]).allSatisfy {
                app.registry.candidates(for: $0, chain: chain).isEmpty
            },
            "⇧⌘C, ⇧⌘M and ⌘R are free for Finder's meanings")

        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        let menuControlCommand: NSEvent.ModifierFlags = [.control, .command]
        func shows(_ action: Selector, _ key: String, _ mask: NSEvent.ModifierFlags) -> Bool {
            let item = items.first { $0.action == action }
            return item?.keyEquivalent == key && item?.keyEquivalentModifierMask == mask
        }
        check(
            shows(
                #selector(FileCommandActions.browserCopyToOtherPanel(_:)), "c", menuControlCommand)
                && shows(#selector(FileCommandActions.browserRename(_:)), "r", menuControlCommand),
            "the File menu shows ⌃⌘C on Copy… and ⌃⌘R on Rename…")
        check(
            shows(#selector(BrowserActions.browserView(_:)), "y", .command)
                && shows(#selector(BrowserActions.browserEdit(_:)), "e", menuControlCommand),
            "the View menu shows ⌘Y on View and ⌃⌘E on Edit")
    }

    /// The Go menu takes Finder's keys and opens its places in the active panel.
    /// Applications stands in for the rest, which need grants the smoke test doesn't have.
    func goMenu(
        _ check: (Bool, String) -> Void, browser: BrowserItem, in window: NSWindow
    )
        async
    {
        let chain = FocusChain.scopes(in: window)
        let keys: [(KeyChord, CommandID, String)] = [
            (KeyChord("h", [.command, .shift]), .goHome, "⇧⌘H"),
            (KeyChord("d", [.command, .shift]), .goDesktop, "⇧⌘D"),
            (KeyChord("o", [.command, .shift]), .goDocuments, "⇧⌘O"),
            (KeyChord("l", [.command, .option]), .goDownloads, "⌥⌘L"),
            (KeyChord("a", [.command, .shift]), .goApplications, "⇧⌘A"),
            (KeyChord("u", [.command, .shift]), .goUtilities, "⇧⌘U"),
        ]
        check(
            keys.allSatisfy { app.registry.candidates(for: $0.0, chain: chain).first?.id == $0.1 },
            "Finder's Go keys run the Go menu's places")
        let titles = NSApp.mainMenu?.item(withTitle: "Go")?.submenu?.items.map(\.title) ?? []
        check(
            titles == ["Home", "Desktop", "Documents", "Downloads", "Applications", "Utilities"],
            "the Go menu lists Finder's places: \(titles)")
        let folder = browser.folder
        check(dispatch(KeyChord("a", [.command, .shift]), in: window), "⇧⌘A dispatched")
        await browser.listed()
        check(
            browser.folder.path == "/Applications",
            "⇧⌘A shows Applications in the active panel: \(browser.folder.path)")
        browser.go(to: folder)
        await browser.listed()
    }
}
