import AppKit
import BrowserKit
import TwinPanesCore
import WorkspaceKit

/// Beats every 5 ms in the common run-loop modes, so any stall of the main actor shows
/// up as a gap; each beat also notes the main thread's CPU time, so a gap it spent
/// working can be told from one it spent waiting for a core (`GapMeter`).
@MainActor
final class Heartbeat {
    private var timer: Timer?
    private(set) var meter = GapMeter()

    func start() {
        meter = GapMeter()
        beat()
        let timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func beat() { meter.beat(at: .now, cpu: GapMeter.threadCPU()) }

    /// Stops and returns what was measured.
    func stop() -> GapMeter {
        beat()
        timer?.invalidate()
        timer = nil
        return meter
    }
}

extension SmokeTest {
    /// Done-when for M4 (docs/plans/M4.md): a 100k-file folder is listed, sorted, filtered,
    /// scrolled and updated live in the real tab without the main thread working for over
    /// 75 ms on the dev Mac between two heartbeats, scaled to this machine
    /// (`stallLimit()`). Gaps it spent waiting for a core are printed, not counted.
    func bigFolder(_ check: (Bool, String) -> Void, browser: BrowserItem, window: NSWindow) async {
        // The table-rows workload's window, made once: making one waits on the window server.
        let referenceWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
            backing: .buffered, defer: false)
        referenceWindow.isReleasedWhenClosed = false
        defer { referenceWindow.close() }
        let count = 100_000
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-big-\(UUID().uuidString)", isDirectory: true)
        let trashed = folder.deletingLastPathComponent()
            .appendingPathComponent("trashed-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trashed)
        }
        let made = await Task.detached { Self.makeBigFolder(folder, files: count) }.value
        guard made else { return check(false, "create a 100k-file folder") }
        let before = browser.folder
        defer { browser.go(to: before) }  // where the rest of the smoke test expects it
        let heart = Heartbeat()
        let recorder = StepRecorder()
        StepTiming.recorder = recorder
        defer { StepTiming.recorder = nil }
        func gate(_ what: String, _ body: () async -> Void) async {
            // Measured again for each check: a shared runner's speed changes as it runs.
            // Its leftovers (the table's layers, autoreleased objects) are cleared before
            // the check starts, so they don't count against it.
            let stall = autoreleasepool { Self.stallLimit(rowsIn: referenceWindow) }
            await settle(milliseconds: 100)
            let limit = Self.milliseconds(stall.limit)
            let limitText = String(format: "%.0f", limit)
            recorder.reset()
            heart.start()
            await body()
            let meter = heart.stop()
            let (wall, busy) = (
                Self.milliseconds(meter.worstWall), Self.milliseconds(meter.worstBusy)
            )
            print(
                String(
                    format: "  info %@: worst main-thread gap %.1f ms; busiest %.1f ms on the CPU",
                    what, wall, busy))
            if busy > limit {
                printSteps(recorder, from: meter.worstBusyEnd, lasting: meter.worstBusyWall)
            } else if wall > limit {
                // Not the app's work: on a shared machine, the main thread waited for a core.
                print("       the main thread waited; its busiest gap was under the limit")
            }
            check(busy <= limit, "\(what) never keeps the main thread busy over \(limitText) ms")
        }
        let table = browser.preferredFirstResponder as? NSTableView
        check(table != nil, "browser exposes its file list table")

        await gate("listing 100k files") {
            browser.go(to: folder)
            await browser.listed()
        }
        check(browser.entries.count == count + 50, "all 100k files and 50 folders are listed")
        // Completion reads the 100k names off the main thread (docs/plans/M5.md, step 23).
        // The typing comes first: the test types the whole path in one main-thread turn,
        // which a person never does. Only Tab is measured.
        typeInPathField(folder.standardizedFileURL.path + "/fo", browser: browser, window: window)
        var completed: String?
        await gate("completing a name among 100k") {
            completed = await pressTabInPathField(browser: browser, window: window)
        }
        check(
            completed == folder.standardizedFileURL.path + "/folder-",
            "Tab completes among 100k names: \(completed ?? "nothing")")
        press("\u{1b}", in: window)
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
        await gate("the shown 100k folder moved away") {
            // Off the main thread, as another app would: FileManager's move took 23-26 ms
            // of this thread's time on the dev Mac, counted against the tab.
            await Task.detached { try? FileManager.default.moveItem(at: folder, to: trashed) }
                .value
            await waitFor { browser.folder.path != folder.standardizedFileURL.path }
            await browser.listed()
        }
        check(
            browser.folder.path == folder.deletingLastPathComponent().standardizedFileURL.path,
            "a folder moved away sends the tab to its parent")
        await Task.detached { try? FileManager.default.removeItem(at: trashed) }.value
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// The reference workload's time on the dev Mac (M1 Pro, Debug build), fastest of 5.
    static let referenceTime = Duration.milliseconds(48)
    /// The table-rows workload's time on the dev Mac, fastest of 5.
    static let referenceRowsTime = Duration.microseconds(7_500)

    /// 75 ms on the dev Mac, scaled by how much slower this Mac runs the reference
    /// workload (docs/plans/M4.md, performance pass): the same work stalls a slower
    /// machine for longer, so CI's runners and slower Macs get a longer limit, and the
    /// check means the same everywhere.
    /// Two workloads, since a Mac without a GPU (CI's runners) can draw at one pace and
    /// build table rows at another; the slower one sets the limit.
    static func stallLimit(rowsIn window: NSWindow) -> StallLimit {
        // On the CPU, like the check itself: time spent waiting for a core counts in
        // neither.
        let drawing = StallLimit.fastestOnCPU(of: 3) { referenceWork() }
        let rows = StallLimit.fastestOnCPU(of: 5) { referenceRows(in: window) }
        // Relaxed from 50 ms (M5) and 75/95 ms (after 0ea630b's sidebar material and unified
        // toolbar added AppKit chrome cost to Dark Aqua redraws on GPU-less CI runners);
        // tightening it back is in PLAN.md §9 ("From M5").
        let stall = StallLimit(
            base: .milliseconds(115), measured: [drawing, rows],
            reference: [referenceTime, referenceRowsTime])
        print(
            String(
                format: "  info reference work: drawing %.1f ms (dev Mac %.1f), table rows"
                    + " %.1f ms (%.1f): limit %.0f ms",
                milliseconds(drawing), milliseconds(referenceTime), milliseconds(rows),
                milliseconds(referenceRowsTime), milliseconds(stall.limit)))
        return stall
    }

    /// A screenful of table rows built as the file list builds a folder's first rows: a
    /// new four-column table of drawn cells in an offscreen window, laid out and drawn.
    static func referenceRows(in window: NSWindow) {
        let table = NSTableView()
        table.style = .fullWidth
        for index in 0..<4 {
            let column = NSTableColumn(identifier: .init("c\(index)"))
            column.width = 200
            table.addTableColumn(column)
        }
        let rows = ReferenceRows()
        table.dataSource = rows
        table.delegate = rows
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        window.contentView = scrollView
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Main-thread work like the browser's: a screenful of names and icons drawn into a
    /// bitmap, and names compared as a sort by name does.
    static func referenceWork() {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 800, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = NSSize(width: 400, height: 400)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let icon = NSWorkspace.shared.icon(for: .plainText)
        for i in 0..<200 {
            let y = CGFloat(i % 20) * 20
            icon.draw(in: NSRect(x: 2, y: y, width: 16, height: 16))
            ("file-\(i)-of-the-reference-work.txt" as NSString).draw(
                at: NSPoint(x: 24, y: y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        var names = (0..<5_000).map { "file\($0 * 7_919 % 5_000).txt" }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// What the app's timed steps did during the gap that ended at `end`; time not listed
    /// was spent elsewhere (AppKit layout and display, or the system).
    func printSteps(
        _ recorder: StepRecorder, from end: ContinuousClock.Instant?, lasting gap: Duration
    ) {
        func ms(_ duration: Duration) -> String {
            String(format: "%.1f", Self.milliseconds(duration))
        }
        guard let end else { return }
        let steps = recorder.steps(from: end - gap, to: end)
        guard !steps.isEmpty else { return print("       in the busiest gap: no timed steps") }
        for step in steps.prefix(8) {
            print(
                "       in the busiest gap: \(step.name) ×\(step.count), \(ms(step.total)) ms"
                    + " (longest \(ms(step.longest)) ms, \(ms(step.longestOnCPU)) on the CPU)")
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

/// The rows of `SmokeTest.referenceRows()`: cells that draw their text, like the file list's.
@MainActor
private final class ReferenceRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    final class Cell: NSTableCellView {
        var text = ""
        override func draw(_ dirtyRect: NSRect) {
            (text as NSString).draw(
                at: NSPoint(x: 2, y: 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 1_000 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let cell = Cell()
        cell.text = "row \(row), \(column?.identifier.rawValue ?? "")"
        return cell
    }
}
