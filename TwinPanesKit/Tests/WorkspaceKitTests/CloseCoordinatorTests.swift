import Testing

@testable import WorkspaceKit

/// The close workflow across two main windows (PLAN.md §4, §4.9). This is also the M0
/// two-window guard: nothing here may assume a single layout.
@MainActor
@Suite struct CloseCoordinatorTests {
    let workspace = WorkspaceRegistry()
    let windowA = MainFrameLayout()
    let windowB = MainFrameLayout()

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

    /// An item that can't save yet (the hex editor before M3b) is never saved: Save from
    /// its prompt cancels, Discard throws the changes away.
    @Test func itemsThatCannotSaveAreOnlyDiscarded() async {
        let session = TestSession()
        session.isDirty = true
        let item = TestItem("unsavable", session: session)
        item.canSave = false
        windowA.insert(item)
        #expect(await coordinator(answer: .save, log: Log()).confirmClose([item]) == false)
        #expect(session.saves == 0 && session.isDirty)
        #expect(await coordinator(answer: .discard, log: Log()).confirmClose([item]))
        #expect(session.discards == 1 && !session.isDirty)
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

    @Test func reentrantConfirmCloseIsRejected() async {
        let session = TestSession()
        session.isDirty = true
        let item = TestItem("one", session: session)
        windowA.insert(item)
        var resumePrompt: CheckedContinuation<CloseDecision, Never>?
        let close = CloseCoordinator(openItems: { [workspace] in workspace.allItems }) { _ in
            await withCheckedContinuation { continuation in
                resumePrompt = continuation
            }
        }
        let first = Task { await close.confirmClose([item]) }
        while resumePrompt == nil { await Task.yield() }
        // A second close while the first prompt is up must fail immediately.
        #expect(await close.confirmClose([item]) == false)
        resumePrompt?.resume(returning: .discard)
        #expect(await first.value)
    }

    @Test func skipsSessionCleanedWhileEarlierPromptWasUp() async {
        let first = TestSession(), second = TestSession()
        first.isDirty = true
        second.isDirty = true
        let items = [TestItem("first", session: first), TestItem("second", session: second)]
        for item in items { windowA.insert(item) }
        let log = Log()
        let close = CloseCoordinator(openItems: { [workspace] in workspace.allItems }) { session in
            log.titles.append(session.representative.title)
            // Simulate the second session being saved while the first prompt was open.
            second.isDirty = false
            return .discard
        }
        #expect(await close.confirmClose(items))
        #expect(log.titles == ["first"])
    }

    @Test func discardThenCancelLeavesEarlierTabDirty() async {
        let first = TestSession(), second = TestSession()
        first.isDirty = true
        second.isDirty = true
        let items = [TestItem("first", session: first), TestItem("second", session: second)]
        for item in items { windowA.insert(item) }
        let close = CloseCoordinator(openItems: { [workspace] in workspace.allItems }) {
            $0.representative.title == "first" ? .discard : .cancel
        }
        #expect(await close.confirmClose(items) == false)
        #expect(first.discards == 0 && first.isDirty && second.isDirty)
    }

    @Test func waitsForFinishSavingEvenWhenClean() async {
        let session = TestSession()
        session.isSaving = true
        let item = TestItem("saving", session: session)
        windowA.insert(item)
        let log = Log()
        session.onFinishSaving = {
            await Task.yield()
            log.titles.append("finished")
            session.isDirty = true
        }
        #expect(await coordinator(answer: .discard, log: log).confirmClose([item]))
        #expect(session.finishSavingCalls == 1 && session.discards == 1)
        #expect(log.titles == ["finished", "saving"])
    }

    @Test func failedSaveInvokesOnSaveError() async {
        let first = TestSession(), second = TestSession()
        first.isDirty = true
        second.isDirty = true
        second.failSave = true
        let items = [TestItem("first", session: first), TestItem("second", session: second)]
        for item in items { windowA.insert(item) }
        var reported: [String] = []
        let close = CloseCoordinator(
            openItems: { [workspace] in workspace.allItems },
            prompt: { $0.representative.title == "first" ? .discard : .save },
            onSaveError: { session, _ in reported.append(session.representative.title) })
        #expect(await close.confirmClose(items) == false)
        #expect(reported == ["second"] && first.discards == 0 && first.isDirty && second.isDirty)
    }
}

@MainActor
final class Log {
    var titles: [String] = []
}
