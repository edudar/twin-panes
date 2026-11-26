import AppKit
import Testing

@testable import BrowserKit

/// The confirm sheets (docs/plans/M6.md, D-f, step 14).
@MainActor
@Suite struct OperationSheetsTests {
    let folder = URL(fileURLWithPath: "/Users/someone/Code", isDirectory: true)
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func destinationsResolveLikeThePathField() {
        #expect(DestinationPath.resolve("/tmp", from: folder, home: home)?.path == "/tmp")
        #expect(
            DestinationPath.resolve("~/Docs", from: folder, home: home)?.path
                == "/Users/someone/Docs")
        #expect(DestinationPath.resolve("~", from: folder, home: home)?.path == "/Users/someone")
        #expect(
            DestinationPath.resolve("../Other", from: folder, home: home)?.path
                == "/Users/someone/Other")
        #expect(DestinationPath.resolve("  ", from: folder, home: home) == nil)
    }

    @Test func renameSelectsTheNameWithoutItsExtension() {
        let window = window()
        defer { window.close() }
        for (name, expectedLength) in [
            ("report.final.pdf", 12),
            (".profile", 8),
            (".gitignore", 10),
        ] {
            let sheet = TextSheet(
                message: "Rename", text: name, selecting: .nameWithoutExtension,
                confirm: "Rename")
            sheet.begin(on: window) { _ in }
            let editor = sheet.field.currentEditor()
            #expect(editor?.selectedRange == NSRange(location: 0, length: expectedLength))
            window.endSheet(sheet.alert.window)
        }
    }

    @Test func confirmingHandsBackTheTextAndCancellingNothing() async {
        let window = window()
        defer { window.close() }
        let sheet = TextSheet(
            message: "New Folder", text: "untitled folder", selecting: .all, confirm: "Create")
        let typed: String? = await withCheckedContinuation { continuation in
            sheet.begin(on: window) { continuation.resume(returning: $0) }
            sheet.field.stringValue = "Photos"
            sheet.alert.buttons[0].performClick(nil)
        }
        #expect(typed == "Photos")
        let other = TextSheet(message: "New Folder", text: "x", selecting: .all, confirm: "Create")
        let cancelled: String? = await withCheckedContinuation { continuation in
            other.begin(on: window) { continuation.resume(returning: $0) }
            other.alert.buttons[1].performClick(nil)
        }
        #expect(cancelled == nil)
    }

    @Test func aRefusalKeepsTheSheetOpenWithItsReason() {
        let window = window()
        defer { window.close() }
        let sheet = TextSheet(
            message: "Copy to:", text: "/nowhere", selecting: .all, confirm: "Copy")
        sheet.begin(on: window) { _ in }
        sheet.refuse("There's no folder at /nowhere.")
        #expect(window.attachedSheet === sheet.alert.window)
        #expect(sheet.alert.informativeText == "There's no folder at /nowhere.")
        NSApp.endSheet(sheet.alert.window)
    }

    @Test func deletingNeedsCommandDAndEscapeCancels() {
        let alert = DeleteConfirmation.makeAlert(for: [folder, home])
        #expect(alert.messageText == "Delete 2 items permanently?")
        #expect(alert.informativeText == "This can't be undone.")
        #expect(alert.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(
            alert.buttons[0].keyEquivalent == "d"
                && alert.buttons[0].keyEquivalentModifierMask == .command)
    }
}
