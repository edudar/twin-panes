import AppKit
import BrowserKit
import TwinPanesCore
import WorkspaceKit

/// The main actor's longest gap between beats while running: a timer every 5 ms in the
/// common run-loop modes, so any stall shows up as a gap.
@MainActor
final class Heartbeat {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private(set) var worst = Duration.zero
    /// When the worst gap ended.
    private(set) var worstEnd = ContinuousClock.now

    func start() {
        last = .now
        worst = .zero
        worstEnd = last
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func beat() {
        let now = ContinuousClock.now
        if now - last > worst { (worst, worstEnd) = (now - last, now) }
        last = now
    }

    /// Stops and returns the worst gap in milliseconds.
    func stop() -> Double {
        beat()
        timer?.invalidate()
        timer = nil
        let (seconds, attoseconds) = worst.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}

extension SmokeTest {
    /// Done-when for M4 (docs/plans/M4.md): a 100k-file folder is listed, sorted, filtered,
    /// scrolled and updated live in the real tab with no main-thread gap over 50 ms.
    func bigFolder(_ check: (Bool, String) -> Void, browser: BrowserItem, window: NSWindow) async {
        let count = 100_000
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-big-\(UUID().uuidString)", isDirectory: true)
        let made = await Task.detached { Self.makeBigFolder(folder, files: count) }.value
        guard made else { return check(false, "create a 100k-file folder") }
        let before = browser.folder
        defer { browser.go(to: before) }  // where the rest of the smoke test expects it
        let limit = 50.0
        let heart = Heartbeat()
        let recorder = StepRecorder()
        StepTiming.recorder = recorder
        defer { StepTiming.recorder = nil }
        func gate(_ what: String, _ body: () async -> Void) async {
            recorder.reset()
            heart.start()
            await body()
            let worst = heart.stop()
            print("  info \(what): worst main-thread gap \(String(format: "%.1f", worst)) ms")
            if worst > limit { printSteps(recorder, during: heart) }
            check(worst <= limit, "\(what) never stalls the main thread over 50 ms")
        }
        let table = browser.preferredFirstResponder as? NSTableView

        await gate("listing 100k files") {
            browser.go(to: folder)
            await browser.listed()
        }
        check(browser.entries.count == count + 50, "all 100k files and 50 folders are listed")
        for column in ["size", "modified", "kind", "name"] {
            for ascending in [false, true] {
                await gate("sorting 100k by \(column), \(ascending ? "up" : "down")") {
                    table?.sortDescriptors = [NSSortDescriptor(key: column, ascending: ascending)]
                    await browser.listed()
                }
            }
        }
        check(
            browser.entries.prefix(51).map(\.name).last == "f000000.txt", "sorted back by name")
        await gate("showing 100 hidden files among 100k") {
            browser.showHidden(true)
            await browser.listed()
        }
        check(browser.entries.count == count + 150, "hidden files show without listing again")
        browser.showHidden(false)
        await browser.listed()
        await gate("scrolling through 100k rows") {
            guard let table else { return }
            for step in 0...100 {
                table.scrollRowToVisible(
                    min(table.numberOfRows - 1, step * table.numberOfRows / 100))
                table.display()
                await settle(milliseconds: 1)
            }
        }
        // Rows draw their cells into one layer each (docs/plans/M4.md, performance pass,
        // step 7): the cells must still be drawn, not skipped.
        let drawn =
            recorder.steps(from: .now - .seconds(600), to: .now)
            .first { $0.name == "cell draw" }?.count ?? 0
        check(drawn >= 100, "scrolling draws the rows' cells (\(drawn) drawn)")
        // Icons are drawn per appearance (performance pass, step 3): switching gives the
        // rows on screen new ones, and the text is laid out again, without a stall.
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            await gate("switching 100k rows to \(appearance.rawValue)") {
                window.appearance = NSAppearance(named: appearance)
                await waitFor { browser.shownIconsAreCurrent }
            }
            check(browser.shownIconsAreCurrent, "rows show \(appearance.rawValue) icons")
        }
        window.appearance = nil
        await gate("100 outside changes in a 100k folder") {
            await Task.detached { Self.changeOutside(folder) }.value
            // 25 deleted, one more removed, 50 created (renames keep the count). The
            // wait itself mustn't walk 100k rows: a count, then the names once, after.
            await waitFor { browser.entries.count == count + 50 - 26 + 50 }
        }
        check(
            browser.entries.contains { $0.name == "renamed-0" }
                && !browser.entries.contains { $0.name == "f000000.txt" }
                && !browser.entries.contains { $0.name == "f000050.swift" },
            "outside creates, renames and deletes show up without a reload")
        // Deleting in Finder moves the folder to the Trash: one rename, not 100k unlinks
        // (those are a known stall, PLAN.md §9).
        let trashed = folder.deletingLastPathComponent()
            .appendingPathComponent("trashed-\(UUID().uuidString)", isDirectory: true)
        await gate("the shown 100k folder moved away") {
            try? FileManager.default.moveItem(at: folder, to: trashed)
            await waitFor { browser.folder.path != folder.standardizedFileURL.path }
            await browser.listed()
        }
        check(
            browser.folder.path == folder.deletingLastPathComponent().standardizedFileURL.path,
            "a folder moved away sends the tab to its parent")
        await Task.detached { try? FileManager.default.removeItem(at: trashed) }.value
    }

    /// What the app's timed steps did during the heartbeat's worst gap; time not listed
    /// was spent elsewhere (AppKit layout and display, or the system).
    func printSteps(_ recorder: StepRecorder, during heart: Heartbeat) {
        func ms(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return String(format: "%.1f", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
        }
        let steps = recorder.steps(from: heart.worstEnd - heart.worst, to: heart.worstEnd)
        guard !steps.isEmpty else { return print("       in the worst gap: no timed steps") }
        for step in steps.prefix(8) {
            print(
                "       in the worst gap: \(step.name) ×\(step.count), \(ms(step.total)) ms"
                    + " (longest \(ms(step.longest)) ms)")
        }
    }

    /// Waits up to 10 s for `condition`, letting the run loop turn.
    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { await settle(milliseconds: 25) }
    }

    /// 100k empty files of a few types, 100 hidden ones and 50 folders.
    nonisolated static func makeBigFolder(_ folder: URL, files: Int) -> Bool {
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return false }
        let extensions = ["txt", "png", "swift", "json", "bin", "md", "jpg", ""]
        for i in 0..<files {
            let ext = extensions[i % extensions.count]
            let name = String(format: "f%06d", i) + (ext.isEmpty ? "" : ".\(ext)")
            // open(2), not FileManager.createFile, which writes each file atomically
            // through a temporary one: ten times slower for 100k files.
            let fd = open(folder.appendingPathComponent(name).path, O_CREAT | O_WRONLY, 0o644)
            guard fd >= 0 else { return false }
            close(fd)
        }
        for i in 0..<100 {
            fm.createFile(atPath: folder.appendingPathComponent(".hidden-\(i)").path, contents: nil)
        }
        for i in 0..<50 {
            try? fm.createDirectory(
                at: folder.appendingPathComponent("folder-\(i)"), withIntermediateDirectories: false
            )
        }
        return true
    }

    /// 50 new files, 25 renames and 25 deletions, from outside the app.
    nonisolated static func changeOutside(_ folder: URL) {
        let fm = FileManager.default
        for i in 0..<25 {
            let name = String(format: "f%06d.txt", i * 8)
            try? fm.moveItem(
                at: folder.appendingPathComponent(name),
                to: folder.appendingPathComponent("renamed-\(i)"))
            try? fm.removeItem(
                at: folder.appendingPathComponent(String(format: "f%06d.bin", 4 + i * 8)))
        }
        try? fm.removeItem(at: folder.appendingPathComponent("f000050.swift"))
        for i in 0..<50 {
            fm.createFile(atPath: folder.appendingPathComponent("new-\(i)").path, contents: nil)
        }
    }
}
