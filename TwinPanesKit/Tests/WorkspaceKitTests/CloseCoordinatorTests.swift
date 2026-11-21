import Testing

@testable import WorkspaceKit

/// The close workflow across two main windows (PLAN.md §4, §4.9). This is also the M0
/// two-window guard: nothing here may assume a single layout.
@MainActor
@Suite struct CloseCoordinatorTests {
    let workspace = WorkspaceRegistry()
    let windowA = MainFrameLayout()
    let windowB = MainFrameLayout()
    var prompts: [String] = []

    init() {
        workspace.register(windowA)
        workspace.register(windowB)
    }

    func coordinator(answer: CloseDecision, log: Log) -> CloseCoordinator {
        CloseCoordinator(openItems: { [workspace] in workspace.allItems }) { session in
            log.titles.append(session.representative.title)
            return answer
        }
    }

    @Test func promptsOnlyWhenLastViewCloses() async {
        let session = TestSession()
        session.isDirty = true
        let viewA = TestItem("file.bin (A)", session: session)
        let viewB = TestItem("file.bin (B)", session: session)
        windowA.insert(viewA)
        windowB.insert(viewB)
        let log = Log()
        let close = coordinator(answer: .discard, log: log)

        // Closing one view while another window still shows the session: no prompt.
        #expect(await close.confirmClose([viewA]))
        #expect(log.titles.isEmpty)
        windowA.remove(viewA.id)

        // Closing the last view prompts once.
        #expect(await close.confirmClose([viewB]))
        #expect(log.titles == ["file.bin (B)"])
        #expect(session.discards == 1)
    }

    @Test func oneSheetPerSessionAtQuit() async {
        let shared = TestSession()
        shared.isDirty = true
        let other = TestSession()
        other.isDirty = true
        let clean = TestSession()
        let items = [
            TestItem("shared 1", session: shared), TestItem("shared 2", session: shared),
            TestItem("other", session: other), TestItem("clean", session: clean),
        ]
        windowA.insert(items[0])
        windowA.insert(items[2])
        windowB.insert(items[1])
        windowB.insert(items[3])
        let log = Log()
        let close = coordinator(answer: .save, log: log)

        #expect(await close.confirmClose(workspace.allItems))
        #expect(log.titles.count == 2)
        #expect(shared.saves == 1)
        #expect(other.saves == 1)
    }

    @Test func cancelStopsEverything() async {
        let first = TestSession(), second = TestSession()
        first.isDirty = true
        second.isDirty = true
        let items = [TestItem("first", session: first), TestItem("second", session: second)]
        for item in items { windowA.insert(item) }
        let log = Log()
        let close = coordinator(answer: .cancel, log: log)
        #expect(await close.confirmClose(items) == false)
        #expect(log.titles == ["first"])
        #expect(first.isDirty && second.isDirty)
    }

    @Test func failedSaveAborts() async {
        let session = TestSession()
        session.isDirty = true
        session.failSave = true
        let item = TestItem("broken", session: session)
        windowA.insert(item)
        let close = coordinator(answer: .save, log: Log())
        #expect(await close.confirmClose([item]) == false)
        #expect(session.isDirty)
    }

    @Test func itemsWithoutSessionAreTheirOwnSession() async {
        let a = TestItem("a"), b = TestItem("b")
        a.ownDirty = true
        windowA.insert(a)
        windowB.insert(b)
        let log = Log()
        let close = coordinator(answer: .discard, log: log)
        #expect(await close.confirmClose([a, b]))
        #expect(log.titles == ["a"])
    }

    @Test func layoutsAreIndependent() {
        let a = TestItem("a"), b = TestItem("b")
        windowA.insert(a)
        windowB.insert(b)
        windowA.toggleZoom()
        #expect(windowB.zoomedItemID == nil)
        #expect(workspace.layout(containing: b.id) === windowB)
        #expect(workspace.allItems.count == 2)
    }
}

@MainActor
final class Log {
    var titles: [String] = []
}
