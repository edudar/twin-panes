import AppKit

extension SmokeTest {
    /// Whether this macOS lets the sandboxed app start its own executable. On macOS 15
    /// the child dies at launch with SIGTRAP before it can report (CI, 2026-11-24): a
    /// second sandbox can't be set up inside the first. macOS 26 and later allow it.
    static var canLaunchItself: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    /// The checks that launch the app again (docs/plans/M5.md, D-f), where macOS lets
    /// them; PLAN.md §9 ("From M5") tracks the gap on macOS 15.
    func relaunchChecks(_ check: (Bool, String) -> Void) async {
        guard Self.canLaunchItself else {
            print("  info relaunch checks skipped: macOS 15 can't start a sandboxed child")
            return
        }
        await selfLaunch(check)
        await restoreRelaunch(check)
        await crashRelaunch(check)
    }

    /// Step 12 of docs/plans/M5.md (D-f): the sandboxed app can start its own executable
    /// as a child, which inherits the sandbox. The relaunch checks build on this.
    func selfLaunch(_ check: (Bool, String) -> Void) async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoke-child-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return check(false, "create a folder for the child's report: \(error)")
        }
        let (report, outcome) = await launchChild("ping", in: folder)
        print("  info launching itself: \(outcome)")
        check(report?.isSandboxed == true, "the sandboxed app can launch itself, sandboxed")
    }

    /// Runs the app's executable with `--smoke-child <step> <folder>` and waits up to
    /// 20 s for its report. Returns the report, if one came, and what happened, for the
    /// log. A child still running after reporting gets a brief grace window to exit on
    /// its own before termination; a timed-out child is terminated immediately.
    func launchChild(_ step: String, in folder: URL) async -> (SmokeChildReport?, String) {
        await runChild(step, in: folder) { process, didReport in
            if didReport {
                let deadline = ContinuousClock.now + .seconds(2)
                while process.isRunning && ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            terminateAndWait(process)
        }
    }

    /// Runs a child that keeps running after its report, then kills it with SIGKILL, as
    /// a crash would, and waits for it to go.
    func crashChild(_ step: String, in folder: URL) async -> (SmokeChildReport?, String) {
        await runChild(step, in: folder) { process, _ in
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func terminateAndWait(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now + .milliseconds(500)
        while process.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func runChild(
        _ step: String, in folder: URL, finally end: (Process, Bool) -> Void
    ) async -> (SmokeChildReport?, String) {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [SmokeChild.flag, step, folder.path]
        do { try process.run() } catch { return (nil, "can't start: \(error)") }
        childTracker.process = process
        var didReport = false
        defer {
            end(process, didReport)
            childTracker.process = nil
        }
        let file = folder.appendingPathComponent("\(step).json")
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: file) {
                didReport = true
                guard let report = try? JSONDecoder().decode(SmokeChildReport.self, from: data)
                else { return (nil, "its report doesn't decode") }
                return (
                    report, "report from pid \(report.processID), sandboxed: \(report.isSandboxed)"
                )
            }
            if !process.isRunning {
                let how = process.terminationReason == .uncaughtSignal ? "signal" : "status"
                return (nil, "no report; it ended with \(how) \(process.terminationStatus)")
            }
            await settle()
        }
        return (nil, "no report within 20 s")
    }
}

extension SmokeTest {
    /// Step 13 of docs/plans/M5.md (D-f, 1): a window comes back after a relaunch with
    /// its panels, tabs, folders, history, sort order, hidden files and editor view.
    func restoreRelaunch(_ check: (Bool, String) -> Void) async {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("smoke-restore-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: folder) }
        do {
            for path in ["a/inner", "b"] {
                try fm.createDirectory(
                    at: folder.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try Data([1]).write(to: folder.appendingPathComponent(".hidden"))
            try Data((0..<4096).map { UInt8($0 % 256) })
                .write(to: folder.appendingPathComponent("data.bin"))
        } catch {
            return check(false, "create the restore relaunch's folder: \(error)")
        }
        let (saved, saveOutcome) = await launchChild("restore-save", in: folder)
        guard saved != nil else {
            return check(false, "the first launch saves its window (\(saveOutcome))")
        }
        let (loaded, loadOutcome) = await launchChild("restore-load", in: folder)
        guard let shown = loaded?.shown else {
            return check(false, "the second launch restores the window (\(loadOutcome))")
        }
        print("  info restored window: \(shown)")
        check(
            shown.leftTabs == ["a"] && shown.rightTabs == ["b", "data.bin"]
                && shown.activePanel == "rightPanel",
            "a relaunch brings back both panels' tabs and the active panel")
        check(
            shown.leftFolder == folder.appendingPathComponent("a").path
                && shown.leftSelection == "inner"
                && shown.leftCanGoBack && shown.leftCanGoForward,
            "and the browser's folder, selection and history")
        check(
            shown.leftSort == "size down" && shown.leftShowsHidden,
            "and its sort order and hidden files")
        check(
            shown.editorFile == "data.bin" && shown.editorSelection == [100, 120]
                && shown.editorBytesPerRow == "fixed(8)" && shown.editorIsDirty == false
                && shown.editorTopRow == 5,
            "and the editor, through its bookmark, with its view, scroll row and no edits")
        check(
            shown.dividerFraction.map { $0 > 0.1 && $0 < 0.45 } == true
                && shown.sidebarShown == false && shown.sidebarWidth != nil,
            "and the panel divider and sidebar state")
    }
}

extension SmokeTest {
    /// Step 14 of docs/plans/M5.md (D-f, 2): edits survive the app being killed, and come
    /// back in the restored tab on their file, dirty.
    func crashRelaunch(_ check: (Bool, String) -> Void) async {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("smoke-crash-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 256).write(to: folder.appendingPathComponent("data.bin"))
        } catch {
            return check(false, "create the crash relaunch's folder: \(error)")
        }
        let (edited, editOutcome) = await crashChild("crash-edit", in: folder)
        guard edited != nil else {
            return check(false, "the first launch edits before it's killed (\(editOutcome))")
        }
        let (loaded, loadOutcome) = await launchChild("crash-recover", in: folder)
        guard let recovered = loaded?.recovered else {
            return check(false, "the launch after the crash recovers (\(loadOutcome))")
        }
        print("  info after the crash: \(recovered)")
        check(
            recovered.recoveredSessions == 1 && recovered.unclaimedSessions == 0
                && recovered.editorTabs == 1,
            "after a crash, the restored editor tab takes its file's recovered session")
        check(
            recovered.isDirty == true && recovered.editedByte == 0x7E,
            "and shows the edit typed before the crash, unsaved")
    }
}
