import AppKit
import Testing

@testable import WorkspaceKit

/// A window's state goes through AppKit's restorable-state coder (docs/plans/M5.md, D-c).
@MainActor
@Suite struct WindowRestorationTests {
    let layout = MainFrameLayout(filler: .testBrowsers)

    func restorable(_ title: String) -> TestItem {
        let item = TestItem(title)
        item.restorableState = ItemState(kind: "test", version: 1, payload: Data(title.utf8))
        return item
    }

    var restorer: ItemRestorer {
        var restorer = ItemRestorer()
        restorer.register("test", newestVersion: 1) { state in
            TestItem(String(decoding: state.payload, as: UTF8.self))
        }
        return restorer
    }

    /// Archives what `write` puts in a coder and reads it back, as AppKit does.
    func archived(_ write: (NSCoder) throws -> Void) throws -> NSCoder {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        try write(archiver)
        archiver.finishEncoding()
        return try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
    }

    func controller() -> MainWindowController {
        MainWindowController(
            layout: layout, workspace: WorkspaceRegistry(),
            dispatcher: CommandDispatcher(registry: CommandRegistry()),
            closeCoordinator: CloseCoordinator(openItems: { [] }) { _ in .discard })
    }

    @Test func stateRoundTripsThroughAKeyedArchiver() throws {
        layout.insert(restorable("a"))
        var state = layout.savedState
        state.dividerFraction = 0.3
        let coder = try archived { try state.encode(into: $0) }
        #expect(try WindowState(restorableStateFrom: coder) == state)
    }

    @Test func aCoderWithoutStateIsMissingIt() throws {
        let coder = try archived { $0.encode(1, forKey: "other") }
        #expect(throws: WindowStateError.missing) { try WindowState(restorableStateFrom: coder) }
    }

    @Test func theWindowWritesItsLayoutWhenAppKitAsks() throws {
        layout.insert(restorable("a"))
        layout.insert(restorable("b"), in: .rightPanel)
        let controller = controller()
        let window = try #require(controller.window)
        let coder = try archived { controller.window(window, willEncodeRestorableState: $0) }
        let state = try WindowState(restorableStateFrom: coder)
        #expect(state.left.items.count == 1 && state.right.items.count == 1)
        #expect(state.activePanel == .rightPanel)
    }

    @Test func restoringPutsBackTheTabsAndKeepsTheDivider() throws {
        let saved = MainFrameLayout(filler: .testBrowsers)
        saved.insert(restorable("a"))
        var state = saved.savedState
        state.dividerFraction = 0.3
        let controller = controller()
        controller.frameController.restore(state, using: restorer)
        #expect(layout.items(in: .leftPanel).map(\.title) == ["a"])
        #expect(controller.frameController.windowState.dividerFraction == 0.3)
    }

    @Test func stateSavedBeforeTheDividerWasSavedStillDecodes() throws {
        let state = layout.savedState
        let data = try state.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("dividerFraction") == false)
        #expect(try WindowState(decoding: data).dividerFraction == nil)
    }
}
