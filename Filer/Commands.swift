import AppKit
import WorkspaceKit

/// Action selectors for app-level and placeholder commands. Declared once so
/// `#selector` has something to point at; the responders implement the methods
/// without conforming (they're found through the responder chain).
@objc protocol FilerActions {
    @objc optional func newMainWindow(_ sender: Any?)
    @objc optional func newBrowserTab(_ sender: Any?)
    @objc optional func newEditorTab(_ sender: Any?)
    @objc optional func newEditorView(_ sender: Any?)
    @objc optional func browserView(_ sender: Any?)
    @objc optional func browserSwitchPanel(_ sender: Any?)
    @objc optional func editorFindNext(_ sender: Any?)
    @objc optional func showTestSheet(_ sender: Any?)
    @objc optional func probeFile(_ sender: Any?)
    @objc optional func probeFolder(_ sender: Any?)
    @objc optional func resolveSavedBookmarks(_ sender: Any?)
    @objc optional func showSpikeReport(_ sender: Any?)
    @objc optional func exportSpikeReport(_ sender: Any?)
}

extension CommandID {
    static let quit: CommandID = "app.quit"
    static let newWindow: CommandID = "app.newWindow"
    static let newBrowserTab: CommandID = "workspace.newBrowserTab"
    static let newEditorTab: CommandID = "workspace.newEditorTab"
    static let newEditorView: CommandID = "editor.newView"
    static let closeTab: CommandID = "workspace.closeTab"
    static let closeWindow: CommandID = "window.close"
    static let toggleZoom: CommandID = "workspace.toggleZoom"
    static let exitZoom: CommandID = "workspace.exitZoom"
    static let nextTab: CommandID = "workspace.nextTab"
    static let previousTab: CommandID = "workspace.previousTab"
    static let browserView: CommandID = "browser.view"
    static let browserSwitchPanel: CommandID = "browser.switchPanel"
    static let editorFindNext: CommandID = "editor.findNext"
    static let showTestSheet: CommandID = "debug.showTestSheet"
    static let probeFile: CommandID = "debug.probeFile"
    static let probeFolder: CommandID = "debug.probeFolder"
    static let resolveBookmarks: CommandID = "debug.resolveBookmarks"
    static let showSpikeReport: CommandID = "debug.showSpikeReport"
    static let exportSpikeReport: CommandID = "debug.exportSpikeReport"
}

extension ItemKind {
    static let browser: ItemKind = "browser"
    static let editor: ItemKind = "editor"
    static let report: ItemKind = "report"
}

/// The M0 catalog and default bindings (D21). F3 is the context-dependent example:
/// View in a browser, Find Next in an editor.
@MainActor
enum DefaultCommands {
    static func makeRegistry() -> CommandRegistry {
        let registry = CommandRegistry()
        func add(_ id: CommandID, _ title: String, _ action: Selector) {
            registry.register(Command(id, title: title, action: action))
        }
        add(.quit, "Quit Filer", #selector(NSApplication.terminate(_:)))
        add(.newWindow, "New Window", #selector(FilerActions.newMainWindow(_:)))
        add(.newBrowserTab, "New Browser Tab", #selector(FilerActions.newBrowserTab(_:)))
        add(.newEditorTab, "New Editor Tab", #selector(FilerActions.newEditorTab(_:)))
        add(.newEditorView, "New View of This Editor", #selector(FilerActions.newEditorView(_:)))
        add(.closeTab, "Close Tab", #selector(MainFrameViewController.closeTab(_:)))
        add(.closeWindow, "Close Window", #selector(NSWindow.performClose(_:)))
        add(.toggleZoom, "Zoom Item", #selector(MainFrameViewController.toggleZoom(_:)))
        add(.exitZoom, "Exit Zoom", #selector(MainFrameViewController.exitZoom(_:)))
        add(.nextTab, "Show Next Tab", #selector(MainFrameViewController.selectNextTab(_:)))
        add(
            .previousTab, "Show Previous Tab",
            #selector(MainFrameViewController.selectPreviousTab(_:)))
        add(.browserView, "View", #selector(FilerActions.browserView(_:)))
        add(.browserSwitchPanel, "Switch Panel", #selector(FilerActions.browserSwitchPanel(_:)))
        add(.editorFindNext, "Find Next", #selector(FilerActions.editorFindNext(_:)))
        add(.showTestSheet, "Show Test Sheet", #selector(FilerActions.showTestSheet(_:)))
        add(.probeFile, "Probe a Test File…", #selector(FilerActions.probeFile(_:)))
        add(.probeFolder, "Probe a Folder…", #selector(FilerActions.probeFolder(_:)))
        add(
            .resolveBookmarks, "Resolve Saved Bookmarks",
            #selector(FilerActions.resolveSavedBookmarks(_:)))
        add(.showSpikeReport, "Show Spike Report", #selector(FilerActions.showSpikeReport(_:)))
        add(
            .exportSpikeReport, "Export Spike Report…",
            #selector(FilerActions.exportSpikeReport(_:)))

        let browser = BindingScope.item(.browser)
        let fileList = BindingScope.item(.browser, part: "fileList")
        let editor = BindingScope.item(.editor)

        registry.bind(KeyChord("q", .command), to: .quit)
        registry.bind(KeyChord("n", .command), to: .newWindow)
        registry.bind(KeyChord("t", .command), to: .newBrowserTab)
        registry.bind(KeyChord("t", [.command, .option]), to: .newEditorTab)
        registry.bind(KeyChord("w", .command), to: .closeTab)
        registry.bind(KeyChord("w", [.command, .shift]), to: .closeWindow)
        registry.bind(KeyChord("\r", [.command, .shift]), to: .toggleZoom)
        registry.bind(.escape, to: .exitZoom, in: .mainFrame)
        registry.bind(KeyChord("\t", .control), to: .nextTab)
        registry.bind(KeyChord("\t", [.control, .shift]), to: .previousTab)
        registry.bind(.function(3), to: .browserView, in: browser)
        registry.bind(.tab, to: .browserSwitchPanel, in: fileList)
        registry.bind(.function(3), to: .editorFindNext, in: editor)
        return registry
    }
}
