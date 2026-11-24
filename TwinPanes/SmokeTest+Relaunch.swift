import AppKit

extension SmokeTest {
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
    /// log. A child still running then is stopped.
    func launchChild(_ step: String, in folder: URL) async -> (SmokeChildReport?, String) {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [SmokeChild.flag, step, folder.path]
        do { try process.run() } catch { return (nil, "can't start: \(error)") }
        defer { if process.isRunning { process.terminate() } }
        let file = folder.appendingPathComponent("\(step).json")
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: file) {
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
