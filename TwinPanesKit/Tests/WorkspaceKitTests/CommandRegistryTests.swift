import AppKit
import Testing

@testable import WorkspaceKit

@MainActor
@Suite struct CommandRegistryTests {
    let registry = CommandRegistry()
    let browser = BindingScope.item("browser")
    let fileList = BindingScope.item("browser", part: "fileList")
    let editor = BindingScope.item("editor")

    init() {
        registry.register(
            Command(
                "browser.view", title: "View", action: #selector(NSResponder.cancelOperation(_:))))
        registry.register(
            Command(
                "editor.findNext", title: "Find Next",
                action: #selector(NSResponder.cancelOperation(_:))))
        registry.register(
            Command(
                "browser.switchPanel", title: "Switch Panel",
                action: #selector(NSResponder.cancelOperation(_:))))
        registry.register(
            Command("app.help", title: "Help", action: #selector(NSResponder.cancelOperation(_:))))
        registry.bind(.function(3), to: "browser.view", in: browser)
        registry.bind(.function(3), to: "editor.findNext", in: editor)
        registry.bind(.tab, to: "browser.switchPanel", in: fileList)
        registry.bind(.function(1), to: "app.help")
    }

    @Test func sameKeyResolvesByFocus() {
        let inBrowser = registry.candidates(
            for: .function(3), chain: [fileList, browser, .slot(.leftPanel), .mainFrame])
        let inEditor = registry.candidates(
            for: .function(3), chain: [editor, .slot(.leftPanel), .mainFrame])
        #expect(inBrowser.map(\.id) == ["browser.view"])
        #expect(inEditor.map(\.id) == ["editor.findNext"])
    }

    @Test func tabOnlyInFileList() {
        #expect(
            registry.candidates(for: .tab, chain: [fileList, browser]).map(\.id) == [
                "browser.switchPanel"
            ])
        // A search field inside the browser item: not the file list, so Tab falls through.
        #expect(registry.candidates(for: .tab, chain: [browser]).isEmpty)
        #expect(registry.candidates(for: .tab, chain: [editor]).isEmpty)
    }

    @Test func appScopeAlwaysConsulted() {
        #expect(registry.candidates(for: .function(1), chain: [editor]).map(\.id) == ["app.help"])
    }

    @Test func menuBindingRespectsShadowing() {
        #expect(registry.binding(for: "browser.view", chain: [browser]) == .function(3))
        #expect(registry.binding(for: "browser.view", chain: [editor]) == nil)
        // An app binding shadowed by a more specific scope isn't shown.
        registry.bind(.function(3), to: "app.help")
        #expect(registry.binding(for: "app.help", chain: [editor]) == .function(1))
    }

    @Test func keyChordParsesEvents() throws {
        func event(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)
        }
        let f3 = String(Character(UnicodeScalar(UInt32(NSF3FunctionKey))!))
        #expect(KeyChord(event: try #require(event(f3, [.function]))) == .function(3))
        #expect(
            KeyChord(event: try #require(event("W", [.command, .shift])))
                == KeyChord("w", [.command, .shift]))
        #expect(
            KeyChord(event: try #require(event("{", [.command, .shift])))
                == KeyChord("{", [.command]))
        #expect(
            KeyChord(event: try #require(event("\u{19}", [.shift]))) == KeyChord("\t", [.shift]))
        #expect(
            KeyChord(event: try #require(event("\r", [.command, .shift])))
                == KeyChord("\r", [.command, .shift]))
        #expect(KeyChord.function(3).description == "F3")
        #expect(KeyChord("\r", [.command, .shift]).description == "⇧⌘↩")
    }
}
