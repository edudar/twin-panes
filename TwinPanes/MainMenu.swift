import AppKit
import WorkspaceKit

/// Builds the main menu from the command catalog. Catalog items get their key
/// equivalents from `MenuBindingUpdater`; Edit menu items are the standard AppKit ones.
@MainActor
enum MainMenu {
    static func build(updater: MenuBindingUpdater) -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            for item in items { menu.addItem(item) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func command(_ id: CommandID) -> NSMenuItem { updater.menuItem(for: id) }
        func standard(
            _ title: String, _ action: Selector, _ key: String,
            _ mask: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            return item
        }

        _ = submenu(
            "Twin Panes",
            [
                standard(
                    "About Twin Panes", #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    ""),
                .separator(),
                standard("Hide Twin Panes", #selector(NSApplication.hide(_:)), "h"),
                standard(
                    "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                    [.command, .option]),
                standard("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
                .separator(),
                command(.quit),
            ])
        _ = submenu(
            "File",
            [
                command(.newWindow), command(.newBrowserTab), command(.newEditorTab),
                command(.newEditorView), .separator(), command(.closeTab), command(.closeWindow),
            ])
        _ = submenu(
            "Edit",
            [
                standard("Undo", Selector(("undo:")), "z"),
                standard("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                standard("Cut", #selector(NSText.cut(_:)), "x"),
                standard("Copy", #selector(NSText.copy(_:)), "c"),
                standard("Paste", #selector(NSText.paste(_:)), "v"),
                standard("Select All", #selector(NSText.selectAll(_:)), "a"),
            ])
        _ = submenu(
            "View",
            [
                command(.toggleZoom), command(.exitZoom), .separator(),
                command(.nextTab), command(.previousTab), .separator(),
                command(.browserView), command(.browserSwitchPanel), command(.editorFindNext),
            ])
        let window = submenu(
            "Window",
            [
                standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                standard("Zoom", #selector(NSWindow.performZoom(_:)), ""),
                .separator(),
                standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
            ])
        _ = submenu(
            "Debug",
            [
                command(.probeFile), command(.probeFolder), command(.resolveBookmarks),
                .separator(), command(.showSpikeReport), command(.exportSpikeReport),
                .separator(), command(.showTestSheet),
            ])
        NSApp.windowsMenu = window
        updater.attach(to: main)
        return main
    }
}
